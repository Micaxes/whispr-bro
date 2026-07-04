import Foundation
import WhisprBroCore

/// Day-1 CLI spike and permanent bench harness (spec §10, §11.1): validates
/// the ASR latency numbers and the pipeline stages on THIS machine, before
/// and independently of the menu-bar app.
///
///   whispr-bench file <audio-file> [runs]   transcribe a fixture, timed runs
///   whispr-bench mic <seconds>              record from the mic, transcribe
///
/// Models must already be installed by scripts/fetch-models.sh. This tool
/// never downloads anything (DownloadUtils.enforceOffline is set in the
/// engine); a missing model prints the fix and exits non-zero.
@main
struct WhisprBench {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "file" where args.count >= 2:
            let runs = args.count >= 3 ? max(1, Int(args[2]) ?? 3) : 3
            await runFile(URL(fileURLWithPath: args[1]), runs: runs)
        case "mic" where args.count >= 2:
            await runMic(seconds: max(1, Double(args[1]) ?? 3))
        case "vad" where args.count >= 2:
            await runVad(URL(fileURLWithPath: args[1]))
        default:
            print("""
            usage:
              whispr-bench file <audio-file> [runs]   # timed transcription of a fixture (default 3 runs)
              whispr-bench mic <seconds>              # record from mic, then transcribe
              whispr-bench vad <audio-file>           # load Silero VAD, trim silence, report

            models dir: \(Paths.modelsDir.path)
            install models once with: scripts/fetch-models.sh
            """)
            exit(64)
        }
    }

    static func runVad(_ url: URL) async {
        let samples: [Float]
        do {
            samples = try AudioFileLoader.loadSamples16k(url)
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
        let vad = VadGate(modelFile: Paths.vadModelFile)
        do {
            let (_, loadSeconds) = try await measured { try await vad.load() }
            print(String(format: "vad load: %.2fs", loadSeconds))
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
        let inputSeconds = Double(samples.count) / AudioEngine.targetSampleRate
        let (trimmed, trimSeconds) = await measured { await vad.trim(samples) }
        let outputSeconds = Double(trimmed.count) / AudioEngine.targetSampleRate
        print(String(format: "input: %.2fs (%d samples)", inputSeconds, samples.count))
        print(String(format: "trimmed: %.2fs (%d samples) — removed %.2fs of silence in %.1fms",
                     outputSeconds, trimmed.count, inputSeconds - outputSeconds, trimSeconds * 1000))
    }

    static func loadEngine() async -> AsrEngine {
        let engine = ParakeetEngine(modelsDir: Paths.modelsDir)
        do {
            let (_, loadSeconds) = try await measured { try await engine.load() }
            print(String(format: "model load + warm-up: %.2fs (excluded from timings)", loadSeconds))
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
        return engine
    }

    static func runFile(_ url: URL, runs: Int) async {
        var samples: [Float]
        do {
            samples = try AudioFileLoader.loadSamples16k(url)
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
        print(String(format: "audio: %.2fs @16kHz mono (%d samples)", Double(samples.count) / AudioEngine.targetSampleRate, samples.count))

        let engine = await loadEngine()
        // Pad short fixtures up to the engine's floor (with margin).
        let minimum = engine.minimumSamples * 2
        if samples.count < minimum {
            samples.append(contentsOf: [Float](repeating: 0, count: minimum - samples.count))
        }
        var wallTimes: [Double] = []
        var modelTimes: [Double] = []
        for run in 1...runs {
            do {
                let (result, seconds) = try await measured { try await engine.transcribe(samples) }
                wallTimes.append(seconds)
                if let modelSeconds = result.modelProcessingSeconds {
                    modelTimes.append(modelSeconds)
                }
                print(String(format: "run %d: %.1fms wall  \"%@\"", run, seconds * 1000, result.text))
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        let average = wallTimes.reduce(0, +) / Double(wallTimes.count)
        let best = wallTimes.min() ?? 0
        print(String(format: "asr wall avg: %.1fms | best: %.1fms | runs: %d", average * 1000, best * 1000, wallTimes.count))
        if !modelTimes.isEmpty {
            let modelAverage = modelTimes.reduce(0, +) / Double(modelTimes.count)
            print(String(format: "asr model-reported avg: %.1fms (FluidAudio processingTime — excludes actor hop)", modelAverage * 1000))
        }
    }

    static func runMic(seconds: Double) async {
        guard await Permissions.requestMicrophone() else {
            print("error: microphone permission denied (grant it to your terminal in System Settings)")
            exit(1)
        }
        let engine = await loadEngine()

        let audio = AudioEngine()
        do {
            try audio.start()
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
        print(String(format: "recording %.1fs — speak now…", seconds))
        audio.beginUtterance()
        try? await Task.sleep(for: .seconds(seconds))
        let samples = audio.endUtterance()
        audio.stop()
        print(String(format: "captured %.2fs", Double(samples.count) / AudioEngine.targetSampleRate))

        do {
            let (result, asrSeconds) = try await measured { try await engine.transcribe(samples) }
            print(String(format: "asr: %.1fms", asrSeconds * 1000))
            print("text: \"\(result.text)\"")
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }
}
