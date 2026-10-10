import Foundation
import WhisprBroCore

/// `whispr-bench repairs` — `SelfRepair` alone, outside the pipeline: over a
/// set of rows (timed, with per-rule fire counts), against a reference run
/// (the byte-parity check, docs/self-repair.md), or on one text.
///
/// The dictionary terms are the app's own (`config.toml` through
/// `DictionaryEngine`, as `PipelineController` builds them) unless
/// `--no-dict`. Rows can be his dictations, so the run file is written 0600
/// and never inside a checkout, and the terminal gets ids and numbers only.
extension WhisprBench {
    static func runRepairs(_ rest: [String]) {
        var inPath: String?, outPath: String?, comparePath: String?, text: String?
        var field = "output", variant: String?
        var rulesSpec = "all", dropGuards = ""
        var useDictionary = true, naturalLanguage = true, nonWords = true, quiet = false
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--in" where i + 1 < rest.count: inPath = rest[i + 1]; i += 2
            case "--out" where i + 1 < rest.count: outPath = rest[i + 1]; i += 2
            case "--compare" where i + 1 < rest.count: comparePath = rest[i + 1]; i += 2
            case "--field" where i + 1 < rest.count: field = rest[i + 1]; i += 2
            case "--variant" where i + 1 < rest.count: variant = rest[i + 1]; i += 2
            case "--rules" where i + 1 < rest.count: rulesSpec = rest[i + 1]; i += 2
            case "--drop-guards" where i + 1 < rest.count: dropGuards = rest[i + 1]; i += 2
            case "--text" where i + 1 < rest.count: text = rest[i + 1]; i += 2
            case "--no-dict": useDictionary = false; i += 1
            case "--no-nl": naturalLanguage = false; i += 1
            case "--no-nonwords": nonWords = false; i += 1
            case "--quiet": quiet = true; i += 1
            default:
                print("repairs: unknown or incomplete flag '\(rest[i])'"); exit(64)
            }
        }
        guard let rules = RepairRun.parseRules(rulesSpec) else {
            print("repairs: --rules is all | none | level:fillers | level:standard | a list of "
                  + SelfRepair.Rule.allCases.map(\.rawValue).joined(separator: ",")); exit(64)
        }
        guard let dropped = RepairRun.parseGuards(dropGuards) else {
            print("repairs: --drop-guards takes " + SelfRepair.Guard.allCases.map(\.rawValue).joined(separator: ","))
            exit(64)
        }
        let terms = useDictionary ? DictionaryEngine(rules: ConfigStore.load().dictionaryRules).lowercasedTargets : []
        // A level spec also decides R3a's non-words (off at `fillers`).
        nonWords = nonWords && RepairRun.nonWords(forRules: rulesSpec)
        let repair = SelfRepair(rules: rules, protecting: terms,
                                guards: Set(SelfRepair.Guard.allCases).subtracting(dropped),
                                naturalLanguage: naturalLanguage, nonWords: nonWords)

        if let text {
            // One text, at his own terminal: the output and what each fire took.
            let result = repair.apply(text)
            let tokens = text.split(whereSeparator: { $0.isWhitespace })
            print(result.text)
            for fire in result.fires {
                let words = fire.deleted.compactMap { $0 < tokens.count ? String(tokens[$0]) : nil }
                print("  \(fire.rule.rawValue): delete [\(words.joined(separator: " "))] (\(fire.note))")
            }
            return
        }
        guard let inPath else {
            print("""
            usage: whispr-bench repairs --in rows.jsonl|set.json [--out run.jsonl] [--compare reference.jsonl]
                     [--field output] [--variant NAME] [--rules all|level:fillers|R1,R3,…] [--drop-guards T1,…]
                     [--no-dict] [--no-nl] [--no-nonwords] [--quiet]
                   whispr-bench repairs --text "<one dictation>"
            """)
            exit(64)
        }
        if let outPath, EvalFile.refusesPrivatePath(outPath) {
            print("--out \(outPath) is inside a source checkout; a repairs run stores every row's text "
                  + "— write it under $WHISPR_EVAL_HOME (default ~/OS/dev/whispr-bro-eval/)")
            exit(64)
        }
        let rows: [RepairRun.Row]
        do {
            rows = try RepairRun.loadRows(try Data(contentsOf: URL(fileURLWithPath: inPath)))
        } catch {
            print("repairs: \(inPath): \(error)"); exit(64)
        }

        // The language and tagging models load once per process; warmed up
        // here, the load is not billed to the first row (the app does the
        // same at launch, for its first dictation).
        if naturalLanguage { SelfRepair.prewarm() }
        let records = RepairRun.run(rows, with: repair)
        if let outPath {
            do {
                try EvalFile.write(try RepairRun.encode(records), to: outPath)
            } catch {
                print("repairs: \(error)"); exit(1)
            }
        }

        let changed = zip(rows, records).filter { !$0.1.fires.isEmpty }.count
        print("repairs: \(rows.count) rows, \(changed) changed, rules \(rules.map(\.rawValue).sorted().joined(separator: ","))"
              + (dropped.isEmpty ? "" : ", guards off \(dropped.map(\.rawValue).sorted().joined(separator: ","))")
              + (nonWords ? "" : ", no R3a non-words")
              + ", \(terms.count) dictionary term(s)" + (naturalLanguage ? "" : ", no NaturalLanguage"))
        let counts = RepairRun.fireCounts(records)
        print("  fires: " + (counts.isEmpty ? "none" : counts.map { "\($0.rule) \($0.count)" }.joined(separator: " · ")))
        printRepairLatency(rows, records)
        if let outPath { print("  → \(outPath) (0600)") }

        guard let comparePath else { return }
        let reference: [RepairRun.Record]
        do {
            reference = try RepairRun.loadRecords(try Data(contentsOf: URL(fileURLWithPath: comparePath)),
                                                  field: field, variant: variant)
        } catch {
            print("repairs: \(comparePath): \(error)"); exit(64)
        }
        let comparison = RepairRun.compare(records, to: reference)
        print("\nparity vs \(URL(fileURLWithPath: comparePath).lastPathComponent):")
        print("  output identical \(comparison.identicalOutputs)/\(comparison.compared) · "
              + "fires identical \(comparison.identicalFires)/\(comparison.compared)"
              + (comparison.missing.isEmpty ? "" : " · \(comparison.missing.count) row(s) missing from the reference")
              + (comparison.extra.isEmpty ? "" : " · \(comparison.extra.count) reference row(s) not run"))
        let names = SelfRepair.Rule.allCases.map(\.rawValue)
            + Set(comparison.ours.keys).union(comparison.reference.keys).subtracting(SelfRepair.Rule.allCases.map(\.rawValue)).sorted()
        for name in names where comparison.ours[name] != nil || comparison.reference[name] != nil {
            let a = comparison.ours[name] ?? 0, b = comparison.reference[name] ?? 0
            print("  \(name.padding(toLength: 4, withPad: " ", startingAt: 0)) ours \(a)  reference \(b)" + (a == b ? "" : "  ≠"))
        }
        if !comparison.differing.isEmpty {
            let shown = comparison.differing.prefix(quiet ? 10 : 50)
            print("  differing ids: " + shown.joined(separator: " ")
                  + (comparison.differing.count > shown.count ? " … (+\(comparison.differing.count - shown.count))" : ""))
        }
        print(comparison.isIdentical ? "PARITY: identical" : "PARITY: DIFFERS")
        if !comparison.isIdentical { exit(1) }
    }

    /// p50 / p90 / max of the per-row apply time, overall and by length in
    /// words (the eval's buckets: ≤ 60, 61–150, > 150).
    private static func printRepairLatency(_ rows: [RepairRun.Row], _ records: [RepairRun.Record]) {
        func line(_ name: String, _ ms: [Double]) -> String? {
            guard !ms.isEmpty else { return nil }
            let sorted = ms.sorted()
            func rank(_ q: Double) -> Double {
                sorted[min(max(Int((q * Double(sorted.count)).rounded(.up)), 1), sorted.count) - 1]
            }
            return String(format: "  %@ n=%d  p50 %.3f ms · p90 %.3f ms · max %.3f ms",
                          name as NSString, ms.count, rank(0.5), rank(0.9), sorted[sorted.count - 1])
        }
        var buckets: [(String, [Double])] = [("≤60 words  ", []), ("61–150     ", []), (">150 words ", [])]
        var all: [Double] = []
        for (row, record) in zip(rows, records) {
            guard let ms = record.ms else { continue }
            all.append(ms)
            let words = row.input.split(whereSeparator: { $0.isWhitespace }).count
            buckets[words <= 60 ? 0 : words <= 150 ? 1 : 2].1.append(ms)
        }
        if let overall = line("all        ", all) { print(overall) }
        for (name, ms) in buckets { if let l = line(name, ms) { print(l) } }
    }
}
