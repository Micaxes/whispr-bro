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
        case "llm" where args.count >= 2:
            await runLlm(key: args[1])
        case "e2e" where args.count >= 2:
            await runE2E(URL(fileURLWithPath: args[1]), key: args.count >= 3 ? args[2] : LlmCatalog.default.key)
        case "style" where args.count >= 2:
            await runStyle(transcript: args[1])
        default:
            print("""
            usage:
              whispr-bench file <audio-file> [runs]   # timed transcription of a fixture (default 3 runs)
              whispr-bench mic <seconds>              # record from mic, then transcribe
              whispr-bench vad <audio-file>           # load Silero VAD, trim silence, report
              whispr-bench llm <key>                  # measurement gate: time a model's formatting pass
                                                      #   key: \(LlmCatalog.all.map(\.key).joined(separator: " | "))
              whispr-bench e2e <audio-file> [key]     # full ASR -> LLM format on a fixture, with stage timings
              whispr-bench style "<text>"             # format one sentence under every per-app style (default model)

            models dir: \(Paths.modelsDir.path)
            install models once with: scripts/fetch-models.sh
            """)
            exit(64)
        }
    }

    /// Realistic raw-dictation transcripts (no punctuation, fillers, false
    /// starts) for the LLM measurement gate.
    static let llmTranscripts = [
        "hey can you um send me the the updated design doc before standup tomorrow morning thanks",
        "so the quarterly report shows revenue grew twelve percent but we need to double check the churn numbers before presenting them to the board on thursday",
        "let's move the meeting to three pm and uh remind me to book the flight to berlin i think it's cheaper if we fly out on a tuesday",
        "the function takes a user id and returns a promise that resolves to the user object or null if not found make sure to handle the error case",
    ]

    static func runLlm(key: String) async {
        guard let spec = LlmCatalog.spec(key: key) else {
            print("unknown model '\(key)'. choices: \(LlmCatalog.all.map(\.key).joined(separator: ", "))")
            exit(64)
        }
        guard spec.isInstalled else {
            print("not installed: \(spec.fileURL.path)\ninstall with: scripts/fetch-llm-models.sh \(key)")
            exit(1)
        }
        print("== \(spec.displayName) [\(spec.family.rawValue)] ==")
        let engine = LlamaCppEngine(
            modelPath: spec.fileURL,
            promptBuilder: PromptBuilder(family: spec.family)
        )
        do {
            let (_, loadSeconds) = try await measured { try await engine.load() }
            print(String(format: "model load + prefix prime: %.2fs (excluded)\n", loadSeconds))
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }

        var latencies: [Double] = []
        for (i, transcript) in llmTranscripts.enumerated() {
            do {
                let cap = 256
                let (text, seconds) = try await measured { try await engine.format(transcript, maxTokens: cap, timeout: .seconds(10)) }
                latencies.append(seconds)
                let outChars = text.count
                print("[\(i + 1)] \(String(format: "%.0fms", seconds * 1000)) (\(outChars) chars)")
                print("    raw: \(transcript)")
                print("    out: \(text.replacingOccurrences(of: "\n", with: " ⏎ "))\n")
            } catch {
                print("[\(i + 1)] error: \(error.localizedDescription)")
            }
        }
        if !latencies.isEmpty {
            let avg = latencies.reduce(0, +) / Double(latencies.count)
            let best = latencies.min() ?? 0
            let worst = latencies.max() ?? 0
            print(String(format: "format latency: avg %.0fms | best %.0fms | worst %.0fms | n=%d",
                         avg * 1000, best * 1000, worst * 1000, latencies.count))
        }
        // Free GPU buffers before exit or ggml-metal asserts at teardown.
        await engine.unload()
    }

    static func runStyle(transcript: String) async {
        let spec = LlmCatalog.default
        guard spec.isInstalled else {
            print("default model not installed; run scripts/fetch-llm-models.sh")
            exit(1)
        }
        let engine = LlamaCppEngine(modelPath: spec.fileURL, promptBuilder: PromptBuilder(family: spec.family))
        let formatter = TextFormatter(engine: engine)
        do { try await formatter.load() } catch {
            print("error: \(error.localizedDescription)"); exit(1)
        }
        let rules = StyleRules()
        print("transcript: \(transcript)\n")
        for category in [AppCategory.messaging, .mail, .ide, .terminal, .notes, .unknown] {
            let directive = rules.directive(for: category)
            let (out, seconds) = await measured {
                await formatter.format(transcript, rawMode: false, styleDirective: directive)
            }
            print(String(format: "%-10@ (%.0fms): %@", category.rawValue as NSString, seconds * 1000, out as NSString))
        }
        await engine.unload()
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

    static func runE2E(_ url: URL, key: String) async {
        guard let spec = LlmCatalog.spec(key: key), spec.isInstalled else {
            print("model '\(key)' not installed; run scripts/fetch-llm-models.sh \(key)")
            exit(1)
        }
        let samples: [Float]
        do { samples = try AudioFileLoader.loadSamples16k(url) } catch {
            print("error: \(error.localizedDescription)"); exit(1)
        }
        let asr = ParakeetEngine(modelsDir: Paths.modelsDir)
        let engine = LlamaCppEngine(modelPath: spec.fileURL, promptBuilder: PromptBuilder(family: spec.family))
        let formatter = TextFormatter(engine: engine)
        do {
            try await asr.load()
            try await formatter.load()
        } catch {
            print("error: \(error.localizedDescription)"); exit(1)
        }

        let (asrResult, asrSeconds) = await measured { () -> AsrResult? in try? await asr.transcribe(samples) }
        let rawText = asrResult?.text ?? ""
        let (formatted, formatSeconds) = await measured { await formatter.format(rawText, rawMode: false) }

        print("ASR  (\(String(format: "%.0fms", asrSeconds * 1000))): \(rawText)")
        print("EDIT (\(String(format: "%.0fms", formatSeconds * 1000))): \(formatted)")
        print(String(format: "asr+format: %.0fms (+ ~50ms insert ≈ %.0fms end-to-end; Wispr target 700ms p99)",
                     (asrSeconds + formatSeconds) * 1000, (asrSeconds + formatSeconds) * 1000 + 50))
        await engine.unload()
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
