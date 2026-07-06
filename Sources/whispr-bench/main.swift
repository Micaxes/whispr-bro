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
        case "latency" where args.count >= 2:
            await runLatency(URL(fileURLWithPath: args[1]),
                             runs: args.count >= 3 ? max(2, Int(args[2]) ?? 20) : 20,
                             budgetMs: args.count >= 4 ? (Double(args[3]) ?? 700) : 700)
        case "style" where args.count >= 2:
            await runStyle(transcript: args[1])
        case "dict" where args.count >= 2:
            await runDict(transcript: args[1])
        case "cleanup" where args.count >= 2:
            await runCleanup(transcript: args[1])
        case "history":
            await runHistory()
        case "verify":
            runVerify()
        default:
            print("""
            usage:
              whispr-bench file <audio-file> [runs]   # timed transcription of a fixture (default 3 runs)
              whispr-bench mic <seconds>              # record from mic, then transcribe
              whispr-bench vad <audio-file>           # load Silero VAD, trim silence, report
              whispr-bench llm <key>                  # measurement gate: time a model's formatting pass
                                                      #   key: \(LlmCatalog.all.map(\.key).joined(separator: " | "))
              whispr-bench e2e <audio-file> [key]     # full ASR -> LLM format on a fixture, with stage timings
              whispr-bench latency <audio-file> [runs] [budgetMs]
                                                      # regression gate: N full-pipeline runs, p50/p99 vs budget
                                                      #   (default 20 runs, 700ms p99 budget) — exits non-zero if over
              whispr-bench style "<text>"             # format one sentence under every per-app style (default model)
              whispr-bench dict "<text>"              # full dictionary→LLM→dictionary flow (uses config.toml)
              whispr-bench cleanup "<text>"           # Auto-Clean: filler strip → LLM self-correction (standard)
              whispr-bench history                    # FTS5 acceptance: 1k rows, search latency
              whispr-bench verify                     # ModelManager: on-disk sha256 verify of every model set

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

    /// Full Auto-Clean flow (task-014): deterministic filler strip → LLM format
    /// with the self-correction clause (level=standard). Prints each stage so
    /// filler removal and self-correction resolution can be inspected on-device.
    static func runCleanup(transcript: String) async {
        let spec = LlmCatalog.default
        guard spec.isInstalled else {
            print("default model not installed; run scripts/fetch-llm-models.sh"); exit(1)
        }
        let engine = LlamaCppEngine(modelPath: spec.fileURL, promptBuilder: PromptBuilder(family: spec.family))
        let formatter = TextFormatter(engine: engine)
        do { try await formatter.load() } catch {
            print("error: \(error.localizedDescription)"); exit(1)
        }
        let stripped = FillerStripper().strip(transcript)
        // Non-verbatim register directive + the self-correction clause (standard).
        let directive = StyleRules().directive(for: .unknown) + "\n\n" + PromptBuilder.correctionClause
        let (out, seconds) = await measured {
            await formatter.format(stripped, rawMode: false, styleDirective: directive, resolveCorrections: true)
        }
        print("input:    \(transcript)")
        print("stripped: \(stripped)")
        print(String(format: "cleaned:  %@   (%.0fms)", out as NSString, seconds * 1000))
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

    static func runDict(transcript: String) async {
        let config = ConfigStore.load()
        let dict = DictionaryEngine(rules: config.dictionaryRules)
        print("config.toml: \(ConfigStore.url.path)")
        print("dictionary terms: \(dict.canonicalTargets.joined(separator: ", "))\n")

        let corrected = dict.apply(transcript)
        print("input:      \(transcript)")
        print("after dict: \(corrected)")

        let spec = LlmCatalog.default
        guard spec.isInstalled else { print("\n(LLM not installed — dict-only shown)"); return }
        let engine = LlamaCppEngine(modelPath: spec.fileURL, promptBuilder: PromptBuilder(family: spec.family))
        let formatter = TextFormatter(engine: engine)
        do { try await formatter.load() } catch { print("error: \(error.localizedDescription)"); exit(1) }

        // Mirror the pipeline: spellings allowlist in the style directive.
        let targets = dict.canonicalTargets.prefix(30)
        let style = targets.isEmpty ? "" :
            "Preserve these spellings exactly, do not alter their casing or spacing: " + targets.joined(separator: ", ") + "."
        // Pipeline applies the dictionary ONCE (before); the LLM allowlist +
        // the raw capitalizer-skip preserve terms without a second pass.
        let llm = await formatter.format(corrected, rawMode: false, styleDirective: style,
                                         preserveCasingFor: dict.lowercasedTargets)
        print("after LLM:  \(llm)  (final inserted)")

        let rawFinal = await formatter.format(corrected, rawMode: true, preserveCasingFor: dict.lowercasedTargets)
        print("\nraw mode (LLM off): \(rawFinal)")
        await engine.unload()
    }

    static func runHistory() async {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whispr-bench-history-\(ProcessInfo.processInfo.processIdentifier).sqlite")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let store = try? HistoryStore(path: tmp) else { print("could not open store"); exit(1) }

        let words = ["design", "review", "flight", "berlin", "revenue", "churn", "getUserData",
                     "meeting", "standup", "quarterly", "report", "friday", "board", "thursday"]
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let (_, insertSeconds) = await measured { () -> Void in
            for i in 0..<1000 {
                let text = (0..<8).map { j in words[(i * 7 + j * 13) % words.count] }.joined(separator: " ")
                await store.save(HistoryRecord(
                    createdAt: epoch.addingTimeInterval(Double(i)), appBundleId: "com.apple.mail",
                    appName: "Mail", rawText: text, formattedText: text.capitalized,
                    audioMs: 5, asrMs: 90 + i % 40, formatMs: 300 + i % 100, insertMs: 50, totalMs: 445 + i % 140))
            }
        }
        let n = await store.count()
        print(String(format: "inserted %d rows in %.0fms (%.2fms/row)", n, insertSeconds * 1000, insertSeconds * 1000 / 1000))

        for q in ["berlin flight", "getUserData", "quarterly report thursday"] {
            let (results, seconds) = await measured { await store.search(q, limit: 50) }
            let verdict = seconds * 1000 < 50 ? "✅ <50ms" : "⚠️ >50ms"
            print(String(format: "search \"%@\": %d hits in %.2fms  %@", q, results.count, seconds * 1000, verdict))
        }
        let (_, recentSeconds) = await measured { await store.recent(limit: 50) }
        print(String(format: "recent(50): %.2fms", recentSeconds * 1000))
    }

    static func runVerify() {
        let groups = ModelManager.verifyAll()
        var allOk = true
        for g in groups {
            let mark = g.isVerified ? "✅" : (g.isInstalled ? "⚠️" : "❌")
            print("\(mark) \(g.displayName): \(g.summary)")
            // A .missing file in a partial-OK group just means that preset isn't
            // installed — not a fault to list.
            for f in g.files where f.state != .ok && !(g.partialOK && f.state == .missing) {
                print("     \(f.state.rawValue): \(f.relativePath)")
            }
            if !g.isVerified && g.id != "llm" { allOk = false } // LLMs are optional presets
        }
        if allOk {
            print("\nverify: core models OK")
        } else {
            // Exit non-zero so this can gate a script/CI step (docs/OFFLINE.md
            // presents `whispr-bench verify` as the tamper/corruption check).
            print("\nverify: PROBLEMS (see above)")
            exit(1)
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

    /// Latency regression harness (spec §11.7 acceptance: "LatencyHarness p99
    /// within budget"). Runs the full ASR→format pipeline `runs` times over a
    /// fixture, reports p50/p99 of the end-of-speech→ready latency (asr+format,
    /// plus a fixed ~50ms insert allowance), and exits non-zero if p99 exceeds
    /// the budget so CI fails on a regression after a model swap or a refactor.
    static func runLatency(_ url: URL, runs: Int, budgetMs: Double) async {
        let spec = LlmCatalog.default
        guard spec.isInstalled else {
            print("model '\(spec.key)' not installed; run scripts/fetch-llm-models.sh \(spec.key)")
            exit(1)
        }
        let samples: [Float]
        do { samples = try AudioFileLoader.loadSamples16k(url) } catch {
            print("error: \(error.localizedDescription)"); exit(1)
        }
        let asr = ParakeetEngine(modelsDir: Paths.modelsDir)
        let engine = LlamaCppEngine(modelPath: spec.fileURL, promptBuilder: PromptBuilder(family: spec.family))
        let formatter = TextFormatter(engine: engine)
        do { try await asr.load(); try await formatter.load() } catch {
            print("error: \(error.localizedDescription)"); exit(1)
        }

        // Insertion latency isn't measured here (it needs a live target); use a
        // fixed allowance so the budget reflects true end-to-end perceived time.
        let insertAllowanceMs = 50.0
        print("model: \(spec.key) | runs: \(runs) (1 warm-up discarded) | budget: \(Int(budgetMs))ms p99")
        var totals: [Double] = []
        for run in 1...runs {
            let (asrResult, asrSeconds) = await measured { () -> AsrResult? in try? await asr.transcribe(samples) }
            // A broken/misconfigured ASR would transcribe to "" and format
            // trivially fast — a false PASS. Refuse to grade an empty pipeline.
            let raw = asrResult?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty else {
                await engine.unload()
                print("error: transcription produced no text (ASR failed or the fixture is silent); cannot measure latency")
                exit(1)
            }
            let (_, formatSeconds) = await measured { await formatter.format(raw, rawMode: false) }
            let totalMs = (asrSeconds + formatSeconds) * 1000 + insertAllowanceMs
            if run == 1 {
                print(String(format: "  warm-up: %.0fms (discarded — primes Metal pipelines)", totalMs))
            } else {
                totals.append(totalMs)
            }
        }
        await engine.unload()

        let p50 = percentile(totals, 0.50)
        let p99 = percentile(totals, 0.99)
        let worst = totals.max() ?? 0
        print(String(format: "asr+format+insert  p50: %.0fms | p99: %.0fms | max: %.0fms | n=%d",
                     p50, p99, worst, totals.count))
        if p99 <= budgetMs {
            print(String(format: "LATENCY HARNESS: PASS (p99 %.0fms ≤ %.0fms)", p99, budgetMs))
        } else {
            print(String(format: "LATENCY HARNESS: FAIL (p99 %.0fms > %.0fms budget)", p99, budgetMs))
            exit(1)
        }
    }

    /// Nearest-rank percentile (`q` in 0…1) over an unsorted sample.
    static func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let rank = Int((q * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
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
