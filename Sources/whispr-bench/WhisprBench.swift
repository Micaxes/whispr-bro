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
        case "cleanup" where args.filter({ $0 != "--no-self-repair" }).count >= 2:
            // The one flag may sit anywhere; the rest are positional.
            let positional = args.filter { $0 != "--no-self-repair" }
            await runCleanup(
                transcript: positional[1],
                // "" is how you ask for a register without replacing the prompt.
                promptFile: positional.count >= 3 && !positional[2].isEmpty ? positional[2] : nil,
                register: positional.count >= 4 ? AppCategory(rawValue: positional[3]) : nil,
                selfRepair: !args.contains("--no-self-repair"))
        case "format":
            await FormatBench.run(Array(args.dropFirst()))
        case "repairs":
            runRepairs(Array(args.dropFirst()))
        case "eval":
            await runEval(Array(args.dropFirst()))
        case "score" where args.count >= 2:
            runScore(Array(args.dropFirst()))
        case "lint":
            runLint(Array(args.dropFirst()))
        case "leaderboard" where args.count >= 2:
            runLeaderboard(Array(args.dropFirst()))
        case "rate" where args.count >= 2:
            runRate(Array(args.dropFirst()))
        case "gold" where args.count >= 2:
            runGold(Array(args.dropFirst()))
        case "calibrate":
            runCalibrate(Array(args.dropFirst()))
        case "history-export":
            await runHistoryExport(Array(args.dropFirst()))
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
              whispr-bench cleanup "<text>" [prompt-file] [register] [--no-self-repair]
                                          # Auto-Clean: filler strip → LLM self-correction (standard).
                                          #   prompt-file swaps the system prompt (A/B a variant);
                                          #   register picks the per-app style (notes, mail, ide, …);
                                          #   --no-self-repair: the strip alone, no self-repair rules
              whispr-bench format [fixtures.json …] [-v] [--no-structure] [--no-self-repair]
                                                      # STRUCTURE benchmark: does a dictation that should
                                                      #   become a list / quotation / paragraph come out that
                                                      #   way? Exact match against hand-written golds, per-tag
                                                      #   summary. Default: docs/eval/formatting.json
              whispr-bench repairs --in rows.jsonl|set.json [--out run.jsonl] [--compare reference.jsonl]
                  [--rules all|level:fillers|level:standard|R1,R3,…] [--drop-guards T1,…] [--no-dict] [--no-nl]
                  [--no-nonwords]
                                                      # the self-repair rules alone (docs/self-repair.md): per-rule
                                                      #   fires and per-row latency; --compare checks byte parity
                                                      #   with a reference run, row for row (exit 1 on a difference);
                                                      #   --out is 0600 and refused in a checkout.
                                                      #   repairs --text "<text>" shows one dictation's fires
              whispr-bench eval [fixtures.json …] [--formatter rules|llama|foundation|shipped|all[,…]]
                                                      # dictation quality benchmark (dev/plans/whispr-bro-eval-benchmark.md):
                                                      #   F formatting / Fi fillers / M meaning / C composite per fixture,
                                                      #   verdict ladder, run status PASS | WARN | FAIL | INVALID
                                                      #   (exit 0 | 0 (3 with --strict-latency) | 2 | 1); the micro
                                                      #   WER / punct F1 / case continuity line stays. Default: seeds.
                                                      #   shipped = score the fixtures' observed column (history export)
                                                      #   foundation = the iOS Apple Foundation Models stage on THIS Mac
                                                      #   (needs macOS 26 + Apple Intelligence)
                  [--model \(LlmCatalog.all.map(\.key).joined(separator: "|"))]
                  [--system-prompt FILE]              #   llama prompt variant (PromptBuilder systemPrompt)
                  [--level fixture|fillers|standard]  #   default fixture; override for A/B on the same golds
                  [--no-self-repair]                  #   the pre-pass without the self-repair rules, as the app
                                                      #   runs with [cleanup] self_repair = false; recorded in the
                                                      #   run, its run_key and its leaderboard row
                  [--tag T[,T…]] [--only gated|flagged|unrated|all] [--confirmed-only]
                  [--budget-ms 700] [--timeout-ms 3000] [--strict-latency]
                  [--json runs/<id>.json] [--report runs/<id>.md] [--append leaderboard.jsonl]
                  [--ratings ratings.jsonl]           #   live calibration banner (§7.4): the rated count,
                                                      #   zero_edit_rate per column and `calibrated` on the
                                                      #   leaderboard row (true only when a calibration.json
                                                      #   marked valid covers this exact fixtures sha256);
                                                      #   defaults to $WHISPR_EVAL_HOME/ratings.jsonl
                  [--git-sha SHA[-dirty]] [--dirty] [--label TEXT] [--quiet]
                                                      #   --append refuses a path inside a source checkout unless
                                                      #   the fixtures are the seeds; --json / --report refuse one
                                                      #   when a fixture carries a history row or a shipped output
                                                      #   (the run file stores every row's text); nothing is
                                                      #   written anywhere but the paths given
              whispr-bench eval --value-flags         # the flags that take a value (scripts/bench-eval.sh reads it)
              whispr-bench score runs/<id>.json [--fixtures f.json] [--json out.json] [--report out.md]
                                                      # re-score a stored run's outputs under the current
                                                      #   scoring_version (no model); fixtures must hash the same
              whispr-bench lint [fixtures.json …] [--repo-guard] [--floors] [--format]
                                                      # structural checks + the gold-scores-100-against-itself
                                                      #   invariant (exit 1 on errors; warnings never block);
                                                      #   no path = the seeds with the set-level floors;
                                                      #   --repo-guard refuses history: sources and observed fields.
                                                      #   The checkout's format-bench files (\(FormatFixture.repoPaths.joined(separator: ", ")))
                                                      #   get the format bench's own rules instead of the invariant,
                                                      #   under the same repo guard; --format lints any path that way
              whispr-bench leaderboard file.jsonl [--diff RUN_KEY_A RUN_KEY_B] [--top N] [--ratings ratings.jsonl]
                                                      # print the rows (--top N = N best by C), or a Δ between
                                                      #   two run keys (refused across fixtures / scoring versions);
                                                      #   --ratings (or $WHISPR_EVAL_HOME) prints the calibration
                                                      #   banner above the table, read from the calibration.json
                                                      #   beside it and only when it hashed THESE rows' fixture set
              whispr-bench rate runs/<id>.json --out ratings.jsonl
                  [--fixtures personal.json]          # the human rating loop (§7.1): raw-stdin triage, 5 s a row
                  [--only gated|flagged|unrated|all]  #   queue order is flagged first, then unrated, then the rest
                  [--column NAME] [--rerate]          #   one formatter; --rerate re-asks an output already rated
                  [--pairwise runs/<other>.json]      #   blind A/B against a second run (calibration check 5)
                  [--session ID]                      #   replays a pairwise layout (default: the start time)
                                                      #   keys: 1 ship · 2 fix · 3 wrong (then a..m tag chips, enter
                                                      #   records) · k/K mark a dropped span must_keep (w2/w5) ·
                                                      #   e edit the gold in $EDITOR · = also fine · s skip ·
                                                      #   y confirm the draft annotations · q quit · ? help.
                                                      #   Piped stdin = SCRIPTED mode: one key or answer per line,
                                                      #   `e` reads the new gold from the next line, EOF ends the
                                                      #   session cleanly. --out is 0600 and refused in a checkout
              whispr-bench gold fixtures.json --ratings ratings.jsonl [--runs runs/<id>.json[,…]]
                  [--write] [--skip-failing]          # ratings → golds and annotations (§7.3): SHIP becomes the
                                                      #   gold, a second one an alternate, an edit wins over both,
                                                      #   y confirms, a tagged WRONG drafts must_keep, a
                                                      #   cue-adjacent deletion drafts a repair. Dry run prints the
                                                      #   per-fixture before/after; --write puts it back 0600 and
                                                      #   never overwrites a confirmed gold or annotation.
                                                      #   --runs resolves the outputs a rating pins by digest.
                                                      #   A row THIS pass derived that fails lint refuses the
                                                      #   write; --skip-failing writes the rows that lint clean
                                                      #   and lists the ones it held back with their errors. An
                                                      #   error the file already carried writes through as a
                                                      #   warning — the pass never touched that row
              whispr-bench calibrate --fixtures f.json --runs runs/<id>.json[,…] --ratings ratings.jsonl
                                     --out calibration.md
                                                      # §7.4's six checks: his own re-rate κ (the ceiling),
                                                      #   weighted κ of the metric's verdict vs his, gate
                                                      #   precision/recall, AUROC, Kendall τ_b / Spearman ρ, and a
                                                      #   logistic weight suggestion (printed, never applied).
                                                      #   VALID only when checks 2–5 pass on ≥ 100 rated rows and
                                                      #   ≥ 40 pairs; writes calibration.md + calibration.json
              whispr-bench history-export [--db PATH] [--since YYYY-MM-DD] [--min-words N] --out personal.json
                                                      # one gold-free v2 fixture per history row, from a COPY of
                                                      #   the DB (default \(Paths.home.appendingPathComponent("history.sqlite").path));
                                                      #   a re-run merges by id and never overwrites a gold or an
                                                      #   annotation; --out is written 0600 and refused inside a
                                                      #   source checkout (the private set lives in $WHISPR_EVAL_HOME)
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
    /// `promptFile` swaps the system prompt (A/B a prompt variant without
    /// authoring fixtures — `eval --system-prompt` lints its golds first, which
    /// a structure experiment cannot pass until the gates learn about
    /// structure). `register` picks the per-app style directive.
    static func runCleanup(transcript: String, promptFile: String? = nil,
                           register: AppCategory? = nil, selfRepair: Bool = true) async {
        let spec = LlmCatalog.default
        guard spec.isInstalled else {
            print("default model not installed; run scripts/fetch-llm-models.sh"); exit(1)
        }
        var system = PromptBuilder.systemPrompt(for: .english)
        if let promptFile {
            guard let text = try? String(contentsOfFile: promptFile, encoding: .utf8) else {
                print("error: cannot read prompt file \(promptFile)"); exit(1)
            }
            system = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let engine = LlamaCppEngine(
            modelPath: spec.fileURL,
            promptBuilder: PromptBuilder(family: spec.family, systemPrompt: system))
        let formatter = TextFormatter(engine: engine)
        do { try await formatter.load() } catch {
            print("error: \(error.localizedDescription)"); exit(1)
        }
        // The app's pre-pass at level standard: self-repair rules, then the
        // filler strip (no personal dictionary here); the strip alone with
        // --no-self-repair, as with [cleanup] self_repair = false. Printed
        // stage by stage below; the cleaned text comes from the app's own
        // text path.
        let dictionary = DictionaryEngine(rules: [])
        let stripper = FillerStripper()
        let category = register ?? .unknown
        let repaired = selfRepair
            ? SelfRepair.forDictation(level: .standard, verbatimRegister: false,
                                      language: .english, protecting: [])?.repair(transcript) ?? transcript
            : transcript
        let stripped = DictationPipeline.prePass(
            transcript, dictionary: dictionary, stripper: stripper,
            level: .standard, verbatimRegister: false, language: .english, selfRepair: selfRepair)
        let structure = SpokenStructure.extract(from: stripped, policy: SpokenStructure.policy(for: category))
        // Non-verbatim register directive + the self-correction clause (standard).
        let directive = StyleRules().directive(for: category) + "\n\n" + PromptBuilder.correctionClause
        // Exactly what DictationPipeline produces (`finish`): the pre-pass, the
        // spoken layout lifted out, the formatter given the app's input and
        // its length ceiling — counted before the rules, so a long dictation
        // they shorten still skips the model as in the app — the layout put
        // back, the finishing pass. What this prints is what lands at the cursor.
        var given: DictationPipeline.FormatterInput?
        let (out, seconds) = await DictationPipeline.finish(
            transcript, dictionary: dictionary, stripper: stripper, level: .standard,
            register: category, language: .english, selfRepair: selfRepair,
            formatInput: { input in
                given = input
                return await formatter.format(
                    input.text, rawMode: false, styleDirective: directive, resolveCorrections: true,
                    ceilingWords: input.ceilingWords)
            })
        print("input:    \(transcript)")
        if repaired != transcript { print("repaired: \(repaired)") }
        print("stripped: \(stripped)")
        if !structure.isEmpty {
            print("structure: \(structure.marks.map { "\($0.kind)@\($0.wordIndex)" }.joined(separator: " "))")
        }
        if let given, given.ceilingWords != DictationPipeline.wordCount(given.text) {
            print("ceiling:  \(given.ceilingWords) words counted (\(DictationPipeline.wordCount(given.text)) after the rules)")
        }
        print(String(format: "cleaned:  %@   (%.0fms)", out as NSString, seconds * 1000))
        await engine.unload()
    }

    /// Dictation quality benchmark (docs/llm-measurement-gate.md: no
    /// quality claims without a measured basis; plan §6). Scores each
    /// formatter column against the fixtures' golds on the three quality
    /// axes (`QualityScore`: F formatting, Fi filler removal, M meaning),
    /// the verdict ladder and the composite, plus today's continuity line
    /// (word WER, punctuation F1, case accuracy) and a raw-vs-gold baseline
    /// so each stage's lift stays visible. Text-only: fixtures enter at the
    /// post-ASR, post-dictionary stage (`HistoryRecord.rawText`) and mirror
    /// the pipeline order strip → format, under each fixture's own register
    /// and level exactly as `PipelineController` would run it (a verbatim
    /// register skips the strip and the correction clause). Fixtures run
    /// sorted by (register, level) so the llama prefix re-primes once per
    /// group; the first row of each group is excluded from the percentiles.
    static func runEval(_ rest: [String]) async {
        // scripts/bench-eval.sh asks the binary which flags take a value.
        if rest == ["--value-flags"] {
            print(EvalOptions.valueFlags.joined(separator: " "))
            exit(0)
        }
        let options: EvalOptions
        switch EvalOptions.parse(rest) {
        case .success(let o): options = o
        case .failure(let e): print("eval: \(e)"); exit(64)
        }
        let loaded: (cases: [EvalCase], name: String, path: String)
        switch loadFixtures(options.fixturePaths) {
        case .success(let l): loaded = l
        case .failure(let e): print(e); exit(64)
        }
        // A broken annotation scores nothing meaningful — refuse, and point
        // at `lint` for the full list.
        let lint = EvalLint.lint(loaded.cases)
        if EvalLint.hasErrors(lint) {
            print("fixtures fail lint (\(lint.filter { $0.severity == .error }.count) error(s)); run `whispr-bench lint`:")
            printIssues(lint.filter { $0.severity == .error })
            exit(64)
        }
        // Belt and braces (§3.3): a personal leaderboard never lands in a
        // checkout, and neither does a run file or report of a personal
        // set (they store every row's text). Checked before any model
        // loads so the refusal is instant.
        if let appendPath = options.appendPath,
           Leaderboard.refusesAppend(path: appendPath, fixtureSetIsSeeds: options.fixturePaths.isEmpty) {
            print("--append \(appendPath) is inside a source checkout; only the seeds may be appended there "
                  + "(personal rows go to $WHISPR_EVAL_HOME, default ~/OS/dev/whispr-bro-eval/)")
            exit(64)
        }
        for (flag, path) in [("--json", options.jsonPath), ("--report", options.reportPath)] {
            if let path, Leaderboard.refusesRunOutput(path: path, cases: loaded.cases) {
                print("\(flag) \(path) is inside a source checkout and the fixtures carry history rows or shipped "
                      + "outputs; a run file stores every row's text — write it under $WHISPR_EVAL_HOME "
                      + "(default ~/OS/dev/whispr-bro-eval/runs/)")
                exit(64)
            }
        }

        let cases = EvalPlan.select(loaded.cases, tags: options.tags, only: options.only,
                                    confirmedOnly: options.confirmedOnly)
        guard !cases.isEmpty else {
            print("no fixtures selected from \(loaded.name) (\(loaded.cases.count) loaded; --tag / --only / --confirmed-only left none)")
            exit(64)
        }
        let plan = EvalPlan(cases: cases, levelOverride: options.levelOverride)
        if !options.selfRepair {
            print("self-repair rules: OFF (--no-self-repair) — the pre-pass is the filler strip alone\n")
        }
        let hasObserved = cases.contains { $0.observed != nil }
        let columns = options.columns(hasObserved: hasObserved)
        let fixturesName = options.fixturesName(base: loaded.name)
        let fixturesSha: String
        do { fixturesSha = try EvalCase.fixtureSetHash(cases) } catch { print("could not hash the fixtures: \(error)"); exit(64) }

        // The banner is live, not a constant: how many of these fixtures he
        // has rated, and whether a calibration record covers this exact set
        // (§7.4). Read before any model loads so the note prints first.
        let calibration = liveCalibration(ratingsPath: options.ratingsPath, cases: cases,
                                          fixturesSha256: fixturesSha, quiet: options.quiet)

        // One prompt language per run (the engine holds one PromptBuilder,
        // the FM formatter one language); the seeds are English, Italian is
        // a follow-up.
        let languages = Set(cases.map(\.language))
        let language = cases.first?.language ?? .english
        if languages.count > 1 {
            print("note: fixtures mix languages \(languages.map(\.code).sorted().joined(separator: ", ")); model prompts use \(language.code)\n")
        }
        var systemPrompt: String? = nil
        if let path = options.systemPromptPath {
            guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("could not read --system-prompt \(path)"); exit(64)
            }
            systemPrompt = text
        }

        // The llama column mirrors the app's bring-up: the catalog model (or
        // `--model`), the language's system prompt (or `--system-prompt`),
        // the hang timeout from `--timeout-ms` so a 100-word fixture is
        // measured instead of invalidated (the row still records whether it
        // would have timed out on-device). Skipped gracefully when the
        // model isn't installed so the other columns still run.
        var llamaFormatter: TextFormatter?
        var llamaEngine: LlamaCppEngine?
        var llamaSpec: LlmModelSpec?
        var llamaPromptBuilder: PromptBuilder?
        if columns.contains("llama") {
            let spec: LlmModelSpec
            if let key = options.modelKey {
                guard let s = LlmCatalog.spec(key: key) else {
                    print("unknown --model '\(key)'. choices: \(LlmCatalog.all.map(\.key).joined(separator: ", "))"); exit(64)
                }
                spec = s
            } else {
                spec = LlmCatalog.default
            }
            if spec.isInstalled {
                let builder = PromptBuilder(family: spec.family,
                                            systemPrompt: systemPrompt ?? PromptBuilder.systemPrompt(for: language))
                let engine = LlamaCppEngine(modelPath: spec.fileURL, promptBuilder: builder)
                var config = TextFormatter.Config()
                config.hangTimeout = .milliseconds(options.timeoutMs)
                let formatter = TextFormatter(engine: engine, config: config)
                do {
                    try await formatter.load()
                    llamaFormatter = formatter
                    llamaEngine = engine
                    llamaSpec = spec
                    llamaPromptBuilder = builder
                } catch {
                    print("llama load failed (\(error.localizedDescription)) — column skipped\n")
                }
            } else {
                print("llama column skipped: \(spec.key) not installed (scripts/fetch-llm-models.sh)\n")
            }
        }
        // The foundation column measures the ACTUAL iOS phase-i4 stage
        // (FoundationModelsFormatter over the Apple system model) on this
        // Mac — same framework, same wrapper, so scores transfer; only
        // absolute latency differs from a phone. Runtime-gated: needs
        // macOS 26 with Apple Intelligence enabled and model assets ready —
        // skipped with the exact reason otherwise (measure, never assume).
        // `formatDetailed` so a per-row fallback is visible: `isSupported`
        // at bring-up does NOT prove the daemon stays healthy for every
        // request. A rejected (`.implausible`) row keeps the REJECTED text
        // so the report can grade what the model did, not only that the
        // gate refused it.
        var fmFormat: ((String, String, Bool, Int) async -> (text: String, source: FormatterSource, rejected: String?))?
        var fmPrompt: ((String) -> String)?
        #if canImport(FoundationModels)
        if columns.contains("foundation") {
            if #available(macOS 26.0, *) {
                if FoundationModelsFormatter.isSupported {
                    var config = FoundationModelsFormatter.Config()
                    config.hangTimeout = .milliseconds(options.timeoutMs)
                    let fm = FoundationModelsFormatter(language: language, config: config)
                    // Kicks off the system-model load; the remainder is
                    // absorbed by the first request (a re-prime row, so it
                    // stays out of the percentiles as on-device).
                    await fm.prewarm()
                    print("foundation: available — prewarmed\n")
                    fmFormat = { stripped, directive, resolve, ceiling in
                        await fm.formatDetailed(stripped, styleDirective: directive, resolveCorrections: resolve,
                                                ceilingWords: ceiling)
                    }
                    fmPrompt = { directive in fm.promptText(styleDirective: directive) }
                } else {
                    print("foundation column skipped: \(FoundationModelsFormatter.availabilityDescription)\n")
                }
            } else {
                print("foundation column skipped: needs macOS 26\n")
            }
        }
        #else
        if columns.contains("foundation") {
            print("foundation column skipped: FoundationModels not in this SDK\n")
        }
        #endif
        if columns.contains("shipped"), !hasObserved {
            print("shipped column skipped: no fixture carries an observed output (history-export writes it)\n")
        }

        // The stripper per language, as PipelineController builds it from
        // config (no personal dictionary, no extra fillers in the bench).
        let noDictionary = DictionaryEngine(rules: [])
        var strippers: [DictationLanguage: FillerStripper] = [:]
        for lang in languages {
            strippers[lang] = FillerStripper(core: FillerStripper.coreFillers(for: lang))
        }
        let labelWidth = max(6, (columns.map(\.count).max() ?? 5) + 1)
        func label(_ name: String) -> String { (name + ":").padding(toLength: labelWidth + 1, withPad: " ", startingAt: 0) }
        let indent = String(repeating: " ", count: labelWidth + 3)

        var observations: [String: [EvalRun.Observation]] = [:]
        var llamaPrompts: [String] = []
        var fmPrompts: [String] = []
        var baseScores: [TranscriptScore] = []
        for item in plan.items {
            let c = item.fixture
            // The app's Auto-Clean pre-pass at the item's level: self-repair,
            // then the filler strip — nothing at all on a verbatim item, the
            // strip alone with --no-self-repair.
            let stripped = DictationPipeline.prePass(
                c.raw, dictionary: noDictionary, stripper: strippers[c.language]!,
                level: item.level, verbatimRegister: false, language: c.language,
                selfRepair: options.selfRepair)
            // The pre-pass without the rules: the formatter's input before
            // they existed, and what the app's 150-word ceiling counts
            // (`DictationPipeline.FormatterInput.ceilingWords`).
            let stripOnly = item.stripFillers ? strippers[c.language]!.strip(c.raw) : c.raw
            let ceilingWords = max(DictationPipeline.wordCount(stripped), DictationPipeline.wordCount(stripOnly))
            let directive = EvalPlan.directive(for: item)
            if !options.quiet {
                print("[\(c.id)]" + (c.note.map { "  (\($0))" } ?? "")
                      + (item.level != .standard || c.register != .unknown ? "  [\(c.register.rawValue)/\(item.level.rawValue)]" : ""))
                print("  \(label("raw"))\(c.raw)")
                if c.isGoldFree {
                    print("  \(label("gold"))(unrated — gates and Fi only)")
                } else {
                    print("  \(label("gold"))\(c.gold)")
                }
            }
            if !c.isGoldFree {
                let base = TranscriptScore.score(hypothesis: c.raw, gold: c.gold)
                baseScores.append(base)
                if !options.quiet { print("  \(label("base"))\(describe(base))") }
            }
            func record(_ name: String, out: String, source: FormatterSource?, ms: Int?, rejected: String? = nil) {
                let score = QualityScore.score(c, out: out, level: options.levelOverride)
                let modelScore = rejected.map { QualityScore.score(c, out: $0, level: options.levelOverride) }
                let observation = EvalRun.Observation(fixture: c, stripped: stripped, out: out, source: source,
                                                      ms: ms, reprime: item.reprime, rejected: rejected,
                                                      score: score, modelScore: modelScore)
                observations[name, default: []].append(observation)
                guard !options.quiet else { return }
                var line = "  \(label(name))"
                if let continuity = score.continuity { line += describe(continuity) + "  " }
                if let ms { line += String(format: "(%.0fms)", Double(ms)) }
                if let source { line += annotate(source) }
                line += "  → " + out.replacingOccurrences(of: "\n", with: " ⏎ ")
                print(line)
                if let rejected {
                    // The gate's evidence: WHAT the model produced that was
                    // refused (answer, commentary, runaway).
                    print(indent + "rejected model output → " + rejected.replacingOccurrences(of: "\n", with: " ⏎ "))
                }
                // The row's own numbers, ONE observation per column so the
                // row struct is the terminal's source of truth too.
                let row = EvalRun.Column.make(formatter: name, level: plan.levelName, config: EvalRun.Config(),
                                              runKey: "", observations: [observation]).rows[0]
                print(indent + EvalReport.rowSummary(row))
            }
            for name in columns {
                switch name {
                case "rules":
                    record(name, out: TextFormatter.ruleBasedCleanup(stripped), source: nil, ms: nil)
                case "llama":
                    guard let formatter = llamaFormatter, let builder = llamaPromptBuilder else { continue }
                    llamaPrompts.append(builder.prefix(styleDirective: directive))
                    let (result, seconds) = await measured {
                        await formatter.formatDetailed(stripped, rawMode: false, styleDirective: directive,
                                                       resolveCorrections: item.resolveCorrections,
                                                       language: c.language, ceilingWords: ceilingWords)
                    }
                    // Same rail as the foundation column: a gate-refused row
                    // keeps the REJECTED text beside the fallback it scored.
                    record(name, out: result.text, source: result.source, ms: Int((seconds * 1000).rounded()),
                           rejected: result.rejected)
                case "foundation":
                    guard let fmFormat, let fmPrompt else { continue }
                    fmPrompts.append(fmPrompt(directive))
                    let (result, seconds) = await measured {
                        await fmFormat(stripped, directive, item.resolveCorrections, ceilingWords)
                    }
                    record(name, out: result.text, source: result.source, ms: Int((seconds * 1000).rounded()),
                           rejected: result.rejected)
                case "shipped":
                    // The production stage ran the model iff the stripped
                    // text cleared the fast path as production decides it
                    // (word limit and the correction-cue bypass);
                    // `observed_ms` is model time only then. History does not
                    // say which binary recorded a row, and binaries before the
                    // self-repair rules handed the formatter the filler strip
                    // alone — so the source stands only where both pre-passes
                    // agree on it.
                    guard let observed = c.observed else { continue }
                    record(name, out: observed,
                           source: EvalPlan.shippedSource(candidates: [stripOnly, stripped], item: item),
                           ms: c.observedMs)
                default:
                    continue
                }
            }
            if !options.quiet { print("") }
        }

        // Columns, in `--formatter` order (D2), each with its identity.
        let gitSha = options.gitSha ?? gitHeadSha() ?? "unknown"
        let config = EvalRun.Config(timeoutMs: options.timeoutMs, budgetMs: options.budgetMs, label: options.label,
                                    selfRepair: options.selfRepair)
        var built: [EvalRun.Column] = []
        for name in columns {
            guard let rows = observations[name], !rows.isEmpty else { continue }
            var modelKey: String? = nil, modelSha: String? = nil, promptSha: String? = nil
            switch name {
            case "rules":
                modelSha = "rules"
            case "llama":
                modelKey = llamaSpec?.key
                modelSha = llamaSpec.flatMap(llamaModelSha256)
                if modelSha == nil { print("note: scripts/models-llm.sha256 not found from the working directory; llama model_sha256 is unknown") }
                promptSha = EvalRun.promptHash(llamaPrompts)
            case "foundation":
                modelKey = "foundation"
                modelSha = foundationModelIdentity()
                promptSha = EvalRun.promptHash(fmPrompts)
            case "shipped":
                // The observed outputs ARE part of the fixture set, so its
                // hash already identifies what the binary produced.
                modelKey = "shipped"
                modelSha = "shipped@" + String(fixturesSha.prefix(12))
            default:
                continue
            }
            let runKey = EvalRun.runKey(gitSha: gitSha, formatter: name, modelSha256: modelSha, promptSha256: promptSha,
                                        fixturesSha256: fixturesSha, level: plan.levelName,
                                        selfRepair: options.selfRepair)
            built.append(EvalRun.Column.make(formatter: name, modelKey: modelKey, modelSha256: modelSha,
                                             promptSha256: promptSha, level: plan.levelName, config: config,
                                             runKey: runKey, observations: rows))
        }
        // A run with nothing measured must not read as a pass (a CI box
        // without the GGUF asked for `--formatter llama`).
        guard !built.isEmpty else {
            print("no column ran (asked for \(columns.joined(separator: ", "))); nothing to score")
            await llamaEngine?.unload()
            exit(64)
        }
        let date = isoNow()
        let run = EvalRun(runId: runId(date: date, gitSha: gitSha, name: fixturesName), date: date, gitSha: gitSha,
                          dirty: options.dirty, machine: machine(),
                          fixtures: EvalRun.Fixtures(path: loaded.path, name: fixturesName, sha256: fixturesSha, cases: cases),
                          columns: built)

        // Today's continuity block (micro-averaged), then the fallback
        // accounting — the honesty rail: a model row that partly measured
        // the RULES path must never read as model evidence.
        let rated = cases.filter { !$0.isGoldFree }.count
        print("aggregate (n=\(cases.count), \(rated) gold-scored, micro-averaged)")
        if !baseScores.isEmpty { printAggregate("baseline", baseScores, latencies: nil) }
        for column in built {
            let rows = observations[column.formatter] ?? []
            let continuity = rows.compactMap(\.score.continuity)
            let latencies = rows.filter(\.isModelPath).compactMap { $0.ms.map { Double($0) / 1000 } }
            if !continuity.isEmpty {
                printAggregate(column.formatter, continuity, latencies: latencies.isEmpty ? nil : latencies)
            }
        }
        for column in built {
            for line in EvalReport.fallbackLines(column) { print(line) }
        }
        print("")

        // The §6.3 summary, with Δ against the leaderboard's previous
        // comparable row when there is one to compare with.
        var previous: [String: EvalRun.LeaderboardRow] = [:]
        if let appendPath = options.appendPath {
            switch loadLeaderboard(appendPath) {
            case .success(let rows): previous = previousRows(run, in: rows)
            case .failure(let e): print(e); await llamaEngine?.unload(); exit(64)
            }
        }
        print(EvalReport.summary(run, deltas: deltas(run, previous: previous), calibration: calibration))
        print("run \(run.runId) · " + built.map { "\($0.formatter) run_key \($0.runKey)" }.joined(separator: " · "))
        let written = emit(run, cases: cases, jsonPath: options.jsonPath, reportPath: options.reportPath,
                           appendPath: options.appendPath, previous: previous, calibration: calibration)

        // Free GPU buffers before exit or ggml-metal asserts at teardown.
        await llamaEngine?.unload()
        if !written { exit(1) }
        exit(run.status.exitCode(strictLatency: options.strictLatency))
    }

    /// `whispr-bench score runs/<id>.json`: re-grades a stored run's outputs
    /// under the current `scoring_version` with no model — the fixtures
    /// come from the run's own `fixtures.path` (or `--fixtures`), narrowed
    /// to the ids the run measured, and must hash to the run's set.
    static func runScore(_ rest: [String]) {
        var runPath: String?
        var fixturesPath: String?
        var jsonPath: String?
        var reportPath: String?
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--fixtures" where i + 1 < rest.count: fixturesPath = rest[i + 1]; i += 2
            case "--json" where i + 1 < rest.count: jsonPath = rest[i + 1]; i += 2
            case "--report" where i + 1 < rest.count: reportPath = rest[i + 1]; i += 2
            default:
                if rest[i].hasPrefix("--") { print("score: unknown flag '\(rest[i])'"); exit(64) }
                runPath = rest[i]; i += 1
            }
        }
        guard let runPath else { print("score: needs runs/<id>.json"); exit(64) }
        let run: EvalRun
        do {
            run = try EvalRun.load(try Data(contentsOf: URL(fileURLWithPath: runPath)))
        } catch {
            print("could not load the run from \(runPath): \(error)"); exit(64)
        }
        let paths = fixturesPath.map { [$0] } ?? (run.fixtures.path == "seeds" ? [] : run.fixtures.path.split(separator: ",").map(String.init))
        let all: [EvalCase]
        switch loadFixtures(paths) {
        case .success(let l): all = l.cases
        case .failure(let e): print(e); exit(64)
        }
        let ids = Set(run.columns.flatMap { $0.rows.map(\.id) })
        let cases = all.filter { ids.contains($0.id) }
        // The same refusal `eval` applies: a re-scored personal run stores
        // the same text.
        for (flag, path) in [("--json", jsonPath), ("--report", reportPath)] {
            if let path, Leaderboard.refusesRunOutput(path: path, cases: cases) {
                print("\(flag) \(path) is inside a source checkout and the fixtures carry history rows or shipped "
                      + "outputs; write it under $WHISPR_EVAL_HOME (default ~/OS/dev/whispr-bro-eval/runs/)")
                exit(64)
            }
        }
        let rescored: EvalRun
        do {
            rescored = try run.rescored(with: cases)
        } catch {
            print("score: \(error)"); exit(64)
        }
        print("re-scored \(run.runId): scoring_version \(run.scoringVersion) → \(rescored.scoringVersion), "
              + "\(rescored.columns.count) column(s), \(cases.count) fixture(s)\n")
        print(EvalReport.summary(rescored))
        print("run_key " + rescored.columns.map { "\($0.formatter) \($0.runKey)" }.joined(separator: " · "))
        let written = emit(rescored, cases: cases, jsonPath: jsonPath, reportPath: reportPath, appendPath: nil, previous: [:])
        if !written { exit(1) }
        exit(rescored.status.exitCode(strictLatency: false))
    }

    /// `whispr-bench lint [fixtures.json …] [--repo-guard] [--floors] [--format]`:
    /// §3.1's row rules on every file (the seeds when none is given, with
    /// the set-level floors on) — structural errors and the §9 invariant
    /// → exit 1, warnings (a kept filler, a draft gold, an alternate gold
    /// the invariant flags) printed → exit 0. `--repo-guard` is CI's check
    /// that no history row or shipped output sits in the tree.
    ///
    /// A path that is one of the checkout's format-bench files
    /// (`FormatFixture.repoPaths` — declared there, never sniffed from the
    /// rows) gets `FormatLint` instead: its golds are layout, which the
    /// invariant's scorer gates by design, so the rules are the format
    /// bench's own, and the repo guard is the same one. `--format` lints
    /// every given path that way, for a file not yet declared.
    static func runLint(_ rest: [String]) {
        var paths: [String] = []
        var repoGuard = false
        var floors = false
        var format = false
        for arg in rest {
            switch arg {
            case "--repo-guard": repoGuard = true
            case "--floors": floors = true
            case "--format": format = true
            default:
                if arg.hasPrefix("--") { print("lint: unknown flag '\(arg)'"); exit(64) }
                paths.append(arg)
            }
        }
        if format, paths.isEmpty { print("lint: --format needs a fixtures path"); exit(64) }
        /// One file (or the seeds) and the lint it gets, loaded before any
        /// line prints so a file that does not decode fails on its own.
        enum Target {
            case cases(name: String, [EvalCase], floors: Bool)
            case format(name: String, [FormatFixture])
        }
        var targets: [Target] = []
        if paths.isEmpty {
            targets = [.cases(name: "seeds", EvalCase.seeds, floors: true)]
        }
        for path in paths {
            if format || FormatFixture.isRepoPath(path) {
                switch loadFormatFixtures(path) {
                case .success(let fixtures): targets.append(.format(name: path, fixtures))
                case .failure(let e): print(e); exit(64)
                }
            } else {
                switch loadFixtures([path]) {
                case .success(let l): targets.append(.cases(name: path, l.cases, floors: floors))
                case .failure(let e): print(e); exit(64)
                }
            }
        }
        var errors = 0, warnings = 0
        for target in targets {
            let name: String, count: Int, issues: [EvalLint.Issue], labels: [String]
            switch target {
            case .cases(let n, let cases, let floors):
                name = n; count = cases.count
                issues = EvalLint.lint(cases, floors: floors, repoGuard: repoGuard)
                labels = (floors ? ["set-level floors"] : []) + (repoGuard ? ["repo guard"] : [])
            case .format(let n, let fixtures):
                name = n; count = fixtures.count
                issues = FormatLint.lint(fixtures, repoGuard: repoGuard)
                labels = ["format bench"] + (repoGuard ? ["repo guard"] : [])
            }
            let e = issues.filter { $0.severity == .error }.count
            let w = issues.count - e
            errors += e; warnings += w
            print("\(name): \(count) fixture(s), \(e) error(s), \(w) warning(s)"
                  + labels.map { " [\($0)]" }.joined())
            printIssues(issues)
        }
        print(errors == 0 ? "\nlint: clean" + (warnings > 0 ? " (\(warnings) warning(s))" : "") : "\nlint: \(errors) error(s)")
        exit(errors == 0 ? 0 : 1)
    }

    /// `whispr-bench leaderboard file.jsonl [--diff A B] [--top N]`.
    static func runLeaderboard(_ rest: [String]) {
        var path: String?
        var diff: (String, String)?
        var top: Int?
        var ratingsPath: String?
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--diff" where i + 2 < rest.count: diff = (rest[i + 1], rest[i + 2]); i += 3
            case "--ratings" where i + 1 < rest.count: ratingsPath = rest[i + 1]; i += 2
            case "--top" where i + 1 < rest.count:
                guard let n = Int(rest[i + 1]), n > 0 else { print("--top needs a positive integer"); exit(64) }
                top = n; i += 2
            default:
                if rest[i].hasPrefix("--") { print("leaderboard: unknown or incomplete flag '\(rest[i])'"); exit(64) }
                path = rest[i]; i += 1
            }
        }
        guard let path else { print("leaderboard: needs a .jsonl path"); exit(64) }
        let rows: [EvalRun.LeaderboardRow]
        switch loadLeaderboard(path) {
        case .success(let r): rows = r
        case .failure(let e): print(e); exit(64)
        }
        guard !rows.isEmpty else { print("\(path): no rows"); exit(0) }
        if let (a, b) = diff {
            do {
                let delta = try Leaderboard.diff(try Leaderboard.row(runKey: a, in: rows),
                                                 try Leaderboard.row(runKey: b, in: rows))
                print(Leaderboard.render(delta))
            } catch {
                print("leaderboard: \(error)"); exit(1)
            }
            return
        }
        // The banner speaks for THESE rows only. A leaderboard file holds
        // rows, not fixtures, and a rating carries no fixture-set identity
        // to filter the log by — so the ratings log cannot put a number on
        // it (his personal rows would be counted against a seeds table).
        // Only a calibration.json hashed against the row's own set may:
        // its `n` is that set's rated rows, counted by `calibrate` itself.
        // Without a ratings path or an eval home there is nothing to read,
        // and the pre-existing `leaderboard file.jsonl` prints the table
        // alone, as it always did.
        if ratingsPath != nil || EvalFile.evalHome() != nil {
            let sha = rows.last?.fixtures.sha256 ?? ""
            let live = Calibration.Live(record: calibrationRecord(besides: ratingsPath), fixturesSha256: sha)
            print(Leaderboard.banner(rows, calibration: live))
        }
        print(Leaderboard.table(rows, top: top))
    }

    /// A loud per-row provenance marker: any row that is not pure model
    /// output is labeled where it happened, not only in the aggregate.
    private static func annotate(_ source: FormatterSource) -> String {
        switch source {
        case .model: return ""
        case .fallback(.fastPath): return "  [fast-path]"
        case .fallback(let reason): return "  [FELL BACK: \(reason.rawValue)]"
        }
    }

    private static func describe(_ s: TranscriptScore) -> String {
        String(format: "wer %.2f | punctF1 %.2f | case %.2f", s.wer, s.punctF1, s.caseAccuracy)
    }

    private static func printAggregate(_ name: String, _ scores: [TranscriptScore], latencies: [Double]?) {
        let a = TranscriptScore.aggregate(scores)
        let label = name.padding(toLength: 10, withPad: " ", startingAt: 0)
        var line = String(format: "  %@ wer %.3f | punct P %.2f R %.2f F1 %.3f | case %.3f",
                          label as NSString, a.wer, a.punctPrecision, a.punctRecall, a.punctF1,
                          a.caseAccuracy)
        if let latencies, !latencies.isEmpty {
            let avg = latencies.reduce(0, +) / Double(latencies.count)
            line += String(format: " | avg %.0fms worst %.0fms", avg * 1000, (latencies.max() ?? 0) * 1000)
        }
        print(line)
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

    /// `whispr-bench history-export [--db PATH] [--since YYYY-MM-DD]
    /// [--min-words N] --out personal.json` (plan §3.3). The live DB is
    /// never opened: `HistoryStore.init` migrates and chmods, and the app
    /// may be holding it — the file (with its -wal / -shm when present) is
    /// copied into a private 0700 temp dir, the copy is read through the
    /// store, and the temp dir is removed on every exit path. One gold-free
    /// v2 fixture per row (`HistoryExport.fixture`); an existing `--out` is
    /// merged by id so a re-run never undoes a rating. The output is
    /// owner-only (0600), written beside the target and swapped in, and
    /// refused inside a source checkout — nothing personal lands in the
    /// tree. `--out` has no default: the bench never writes into the
    /// private eval folder unless a path under it is passed (D3).
    static func runHistoryExport(_ rest: [String]) async {
        var dbPath: String?
        var since: Date?
        var sinceText: String?
        var minWords = 1
        var outPath: String?
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--db" where i + 1 < rest.count:
                dbPath = rest[i + 1]; i += 2
            case "--since" where i + 1 < rest.count:
                guard let d = HistoryExport.date(rest[i + 1]) else {
                    print("--since needs YYYY-MM-DD, not '\(rest[i + 1])'"); exit(64)
                }
                since = d; sinceText = rest[i + 1]; i += 2
            case "--min-words" where i + 1 < rest.count:
                guard let n = Int(rest[i + 1]), n >= 1 else { print("--min-words needs a positive integer"); exit(64) }
                minWords = n; i += 2
            case "--out" where i + 1 < rest.count:
                outPath = rest[i + 1]; i += 2
            default:
                print("history-export: unknown or incomplete flag '\(rest[i])'"); exit(64)
            }
        }
        guard let outPath else {
            print("history-export: --out is required (the private set is $WHISPR_EVAL_HOME/personal.json, "
                  + "default ~/OS/dev/whispr-bro-eval/; nothing is written anywhere but the path given)")
            exit(64)
        }
        if Leaderboard.isInsideRepoTree(outPath) {
            print("--out \(outPath) is inside a source checkout; a history export never lands in a checkout")
            exit(64)
        }
        let db = URL(fileURLWithPath: dbPath ?? Paths.home.appendingPathComponent("history.sqlite").path)
        guard FileManager.default.fileExists(atPath: db.path) else { print("no history at \(db.path)"); exit(1) }

        // Snapshot: `exit` skips `defer`, so every failure past this point
        // goes through `fail`, which removes the copy first.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-bench-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            print("could not create a temp dir: \(error.localizedDescription)"); exit(1)
        }
        func fail(_ message: String) -> Never {
            try? FileManager.default.removeItem(at: tmpDir)
            print(message)
            exit(1)
        }
        let copy = tmpDir.appendingPathComponent("history.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let source = db.path + suffix
            guard FileManager.default.fileExists(atPath: source) else { continue }
            do {
                try FileManager.default.copyItem(atPath: source, toPath: copy.path + suffix)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path + suffix)
            } catch {
                fail("could not copy \(source): \(error.localizedDescription)")
            }
        }
        // The store is scoped so its handle is closed before the temp dir
        // goes away.
        let records: [HistoryRecord]
        do {
            let store = try HistoryStore(path: copy)
            records = await store.recent(limit: HistoryStore.maxRows)
        } catch {
            fail("could not open the history copy: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: tmpDir)

        let fresh = HistoryExport.export(records, since: since, minWords: minWords)
        var existing: [EvalCase] = []
        if FileManager.default.fileExists(atPath: outPath) {
            do {
                existing = try JSONDecoder().decode([EvalCase].self, from: try Data(contentsOf: URL(fileURLWithPath: outPath)))
            } catch {
                print("could not read the existing \(outPath) (\(error.localizedDescription)); leaving it untouched")
                exit(1)
            }
        }
        let merge = HistoryExport.merge(existing: existing, fresh: fresh)

        // Created 0600 from the first byte (no 0644 window), then swapped
        // over the target atomically so a failed write never costs him a
        // rated file.
        let out = URL(fileURLWithPath: outPath)
        let staging = URL(fileURLWithPath: outPath + ".tmp-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            let data = try HistoryExport.encode(merge.cases)
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: staging.path, contents: data,
                                                 attributes: [.posixPermissions: 0o600]) else {
                print("could not write \(staging.path)"); exit(1)
            }
            if FileManager.default.fileExists(atPath: out.path) {
                _ = try FileManager.default.replaceItemAt(out, withItemAt: staging, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.moveItem(at: staging, to: out)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            print("could not write \(outPath): \(error.localizedDescription)"); exit(1)
        }

        var filters: [String] = []
        if let sinceText { filters.append("since \(sinceText)") }
        if minWords > 1 { filters.append("≥ \(minWords) words") }
        print("history-export: \(records.count) row(s) in \(db.path) → \(fresh.count) fixture(s)"
              + (filters.isEmpty ? "" : " (" + filters.joined(separator: ", ") + ")"))
        var registers: [String: Int] = [:]
        for c in fresh { registers[c.register.rawValue, default: 0] += 1 }
        if !registers.isEmpty {
            print("  registers: " + registers.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: " · "))
        }
        let rated = merge.cases.filter { !$0.isGoldFree }.count
        let drafts = merge.cases.filter { !$0.isGoldFree && $0.isDraft }.count
        print("  merged: \(merge.refreshed) refreshed (observed / observed_ms / note only), \(merge.added) added, "
              + "\(merge.retained) retained · \(rated) rated (\(drafts) draft) · \(merge.cases.count) total")
        print("  → \(outPath) (0600)")
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
            // Only a CLEANLY absent optional set (every file missing, or no
            // manifest AND no install root) is benign. `!isInstalled` would be
            // too loose: deleting one file makes a non-partialOK group read as
            // "not installed", which must not mask a hash mismatch next to it.
            let absentOptional = g.optional && g.isCleanlyAbsent
            let mark = g.isVerified ? "✅" : (absentOptional ? "➖" : (g.isInstalled ? "⚠️" : "❌"))
            print("\(mark) \(g.displayName): \(g.summary)")
            // A .missing file in a partial-OK group just means that preset isn't
            // installed — not a fault to list. Same for an optional set that
            // isn't installed at all (multilingual Parakeet v3).
            for f in g.files where f.state != .ok && !((g.partialOK || absentOptional) && f.state == .missing) {
                print("     \(f.state.rawValue): \(f.relativePath)")
            }
            if !g.isVerified && !absentOptional { allOk = false }
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
