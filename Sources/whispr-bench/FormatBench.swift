import Foundation
import WhisprBroCore

/// `whispr-bench format` — the STRUCTURE benchmark: does a dictation that
/// should become a list, a quotation or a paragraph actually come out that way?
///
/// Separate from `whispr-bench eval` on purpose. Eval grades word-level
/// fidelity against `ContentGuard`, whose L1 rule refuses added lines and
/// markdown outright — so a correct bulleted list cannot even be expressed as
/// an eval gold (its lint rejects one: "gated multi-line, markdown"). That gate
/// is right for what it guards; it simply cannot score layout. This runs the
/// real shipping path instead and compares the finished text exactly.
///
/// Exact match is the right metric here, unlike in eval: a formatting gold is
/// one specific string, and "nearly the right line breaks" is not a pass.
///
/// What it does NOT model: the personal dictionary. `DictationPipeline` passes
/// its targets to the structure layer so a term like "npm" keeps its casing;
/// this harness has no config, so it sees only the built-in floor
/// (`SpokenStructure.lowercaseByNature`).
enum FormatBench {

    /// The row type lives in Core (`FormatFixture`) so `FormatLint` and its
    /// tests decode exactly what this bench runs.
    typealias Fixture = FormatFixture

    struct Result {
        let fixture: Fixture
        let output: String
        var passed: Bool { output == fixture.gold }
    }

    static func run(_ args: [String]) async {
        var paths: [String] = []
        var showAll = false
        var structure = true
        var selfRepair = true
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--verbose", "-v": showAll = true
            // The BASELINE: the formatter alone, with no structure layer —
            // what this app did before it had one. Same fixtures, same model,
            // so the before/after is measured rather than remembered.
            case "--no-structure": structure = false
            // The pre-pass without the self-repair rules: the filler strip
            // alone, as the app runs with [cleanup] self_repair = false.
            case "--no-self-repair": selfRepair = false
            default: paths.append(args[i])
            }
            i += 1
        }
        // The checkout's own files, declared once in Core: `lint` routes the
        // same list to `FormatLint`.
        if paths.isEmpty { paths = FormatFixture.repoPaths }

        var fixtures: [Fixture] = []
        for path in paths {
            switch WhisprBench.loadFormatFixtures(path) {
            case .success(let loaded): fixtures += loaded
            case .failure(let error): print("error: \(error)"); exit(1)
            }
        }
        guard !fixtures.isEmpty else { print("no fixtures"); exit(1) }
        // A broken set is refused before the model loads, as `eval` refuses
        // one: the lint is what this report takes for granted of a row.
        let lint = FormatLint.lint(fixtures)
        if EvalLint.hasErrors(lint) {
            print("fixtures fail lint (\(lint.filter { $0.severity == .error }.count) error(s)); run `whispr-bench lint --format`:")
            WhisprBench.printIssues(lint.filter { $0.severity == .error })
            exit(1)
        }

        let spec = LlmCatalog.default
        guard spec.isInstalled else {
            print("default model not installed; run scripts/fetch-llm-models.sh"); exit(1)
        }
        let engine = LlamaCppEngine(modelPath: spec.fileURL, promptBuilder: PromptBuilder(family: spec.family))
        let formatter = TextFormatter(engine: engine)
        do { try await formatter.load() } catch {
            print("error: \(error.localizedDescription)"); exit(1)
        }

        var results: [Result] = []
        for fixture in fixtures {
            let category = fixture.register.flatMap(AppCategory.init(rawValue:)) ?? .unknown
            results.append(Result(
                fixture: fixture,
                output: await format(fixture.raw, category: category, policyName: fixture.policy,
                                     formatter: formatter, structure: structure, selfRepair: selfRepair)))
        }
        await engine.unload()
        report(results, showAll: showAll,
               model: spec.key + (structure ? "" : ", NO structure layer (baseline)")
                   + (selfRepair ? "" : ", NO self-repair rules"))
    }

    /// The shipping path, in `DictationPipeline`'s order: strip fillers, lift
    /// the spoken layout out, format the plain line, put the layout back.
    private static func format(
        _ raw: String, category: AppCategory, policyName: String?,
        formatter: TextFormatter, structure useStructure: Bool = true, selfRepair: Bool = true
    ) async -> String {
        // The app's pre-pass at level standard (self-repair, then the filler
        // strip), as DictationPipeline runs it.
        let dictionary = DictionaryEngine(rules: [])
        let stripper = FillerStripper()
        let stripped = DictationPipeline.prePass(
            raw, dictionary: dictionary, stripper: stripper,
            level: .standard, verbatimRegister: false, language: .english, selfRepair: selfRepair)
        let directive = StyleRules().directive(for: category) + "\n\n" + PromptBuilder.correctionClause
        // The model's length ceiling counts the dictation as the app's does,
        // before the self-repair rules (`DictationPipeline.FormatterInput
        // .ceilingWords`): rules that shorten a long dictation never bring it
        // onto the model here either.
        guard useStructure else {
            return await formatter.format(
                stripped, rawMode: false, styleDirective: directive, resolveCorrections: true,
                ceilingWords: DictationPipeline.ceilingWords(
                    for: stripped, verbatimText: raw, dictionary: dictionary, stripper: stripper, policy: nil))
        }
        let policy = policyName == FormatFixture.inferringPolicy
            ? SpokenStructure.Policy.inferring : SpokenStructure.policy(for: category)
        let structure = SpokenStructure.extract(from: stripped, policy: policy)
        let formatted = await formatter.format(
            structure.text, rawMode: false, styleDirective: directive, resolveCorrections: true,
            ceilingWords: DictationPipeline.ceilingWords(
                for: structure.text, verbatimText: raw, dictionary: dictionary, stripper: stripper, policy: policy))
        let structured = SpokenStructure.apply(
            structure.marks, to: formatted, from: structure.text, policy: policy)
        return policy.finishes
            ? SpokenStructure.terminating(SpokenStructure.capitalizingFirstWord(structured))
            : structured
    }

    // MARK: - Report

    private static func report(_ results: [Result], showAll: Bool, model: String) {
        let passed = results.filter(\.passed).count
        print("whispr-bench format — \(results.count) fixtures, model \(model)\n")

        for result in results where showAll || !result.passed {
            let mark = result.passed ? "PASS" : "FAIL"
            print("[\(mark)] \(result.fixture.id)  (\(result.fixture.tags.joined(separator: ", ")))")
            print("  said: \(result.fixture.raw)")
            if !result.passed {
                print("  want: \(oneLine(result.fixture.gold))")
                print("  got:  \(oneLine(result.output))")
            }
            print("")
        }

        // Per-tag, so a regression names the feature it broke.
        var byTag: [String: (pass: Int, total: Int)] = [:]
        for result in results {
            for tag in result.fixture.tags {
                var counts = byTag[tag] ?? (0, 0)
                counts.total += 1
                if result.passed { counts.pass += 1 }
                byTag[tag] = counts
            }
        }
        // The number that matters for a control is not exact match — the model
        // has its own quirks — but whether the LAYER restructured something it
        // should not have. Checked, not claimed.
        // `mustNotRestructure` is declared BY THE FIXTURE. Asking
        // `SpokenStructure.extract` instead — as an earlier version did — let
        // the layer excuse itself: any control it wrongly restructured was
        // excluded from the check by construction.
        // Every `control` fixture is checked unless it is a declared
        // `known-fail`. An earlier version required an opt-in flag, and the two
        // controls the layer provably restructures simply omitted it — the
        // banner printed ✓ over them. Known-fails are PRINTED, not suppressed.
        let checked = results.filter {
            $0.fixture.mustNotRestructure ?? ($0.fixture.tags.contains("control")
                && !$0.fixture.tags.contains("known-fail")
                && !$0.fixture.tags.contains("unsupported-phrase"))
        }
        let restructured = checked.filter { gainedStructure($0.output) }
        let knownFails = results.filter { $0.fixture.tags.contains("known-fail") }
        if !knownFails.isEmpty {
            print("KNOWN FALSE POSITIVES (\(knownFails.count)) — the layer restructures speech "
                  + "that only MENTIONS a marker:")
            for k in knownFails { print("  \(k.fixture.id): \(oneLine(k.output))") }
            print("")
        }
        if restructured.isEmpty {
            print("controls: none of the \(checked.count) checked acquired structure ✓\n")
        } else {
            print("CONTROLS THAT ACQUIRED STRUCTURE (\(restructured.count)):")
            for r in restructured { print("  \(r.fixture.id): \(oneLine(r.output))") }
            print("")
        }

        print("by tag:")
        for tag in byTag.keys.sorted() {
            let c = byTag[tag]!
            print(String(format: "  %-14s %d/%d", (tag as NSString).utf8String!, c.pass, c.total))
        }
        print("\n\(passed)/\(results.count) exact match")
    }

    /// Layout this layer can add: a line, a bullet, or a quotation mark.
    private static func gainedStructure(_ output: String) -> Bool {
        output.contains("\n") || output.hasPrefix("- ") || output.contains("\"")
    }

    /// Newlines shown as ⏎ so a diff fits one terminal line.
    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ⏎ ")
    }
}
