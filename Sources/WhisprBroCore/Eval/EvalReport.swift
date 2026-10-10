import Foundation

/// Renders an `EvalRun` for humans (plan §6.3): the per-row line the
/// terminal appends after today's continuity line, the five-line summary
/// block, and the markdown report — leaderboard rows with their Δ, the
/// verdict histogram per column, gated fixtures first with a word diff,
/// the worst ten by C, latency by length bucket, provenance counts, the
/// calibration banner. Pure functions of the run (plus the fixtures for
/// the raw / gold text and the previous leaderboard rows for the Δ), so
/// every line is pinned by test and the bench only prints.
public enum EvalReport {
    /// The banner every report and leaderboard row carries (§7.4). The
    /// composite decides nothing on its own until `calibrate` says VALID
    /// on this exact fixture set, so the line states the live rated count
    /// and the verdict — never a claim the ratings do not support.
    /// The bare constant is the zero state (`eval` without `--ratings`).
    /// `rated: nil` prints `n=—`: the rows on screen cannot be attributed
    /// to a rated fixture set, and a count from another set would be worse
    /// than no count at all.
    public static let calibrationBanner = calibrationBanner(rated: 0, valid: false)

    public static func calibrationBanner(rated: Int?, valid: Bool) -> String {
        "CALIBRATION: \(valid ? "VALID" : "PENDING") (n=\(rated.map(String.init) ?? "—") rated)"
    }

    // MARK: - Per-row line

    /// `verdict F/Fi/M · D I novel · ms` — appended under each row's
    /// output in the terminal. Gold-free rows show the gates' verdict and
    /// their diagnostics (no F / M / C). `lost N` follows `D` when §4.4's
    /// D differs from the alignment's (a wrong raw word kept in a gold
    /// word's place is lost without a `.del`), so an OVER_EDIT_HEDGE never
    /// prints beside `D 0` with nothing to show for it.
    public static func rowSummary(_ row: EvalRun.Row) -> String {
        var parts = [row.verdict + (row.triggers.isEmpty ? "" : " (" + row.triggers.joined(separator: ", ") + ")")]
        if row.f != nil || row.m != nil {
            parts.append("F \(number(row.f)) Fi \(number(row.fi)) M \(number(row.m)) C \(number(row.c))")
        } else if let fi = row.fi {
            parts.append("Fi \(number(fi))")
        }
        var counts = "D \(row.dels)"
        if let lost = row.lost, lost != row.dels { counts += " lost \(lost)" }
        counts += " I \(row.ins) novel \(row.novel)"
        if row.novelNumerals > 0 { counts += " (numerals \(row.novelNumerals))" }
        if row.droppedContent > 0 { counts += " dropped \(row.droppedContent)" }
        parts.append(counts)
        if let ms = row.ms {
            parts.append("\(ms)ms" + (row.reprime ? " reprime" : "") + (row.wouldTimeout3s ? " >3s" : ""))
        }
        if let modelVerdict = row.modelVerdict { parts.append("model \(modelVerdict)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Summary block

    /// The §6.3 terminal block. `deltas` are per formatter, from the
    /// leaderboard's previous comparable row when `--append` gave one.
    public static func summary(_ run: EvalRun, deltas: [String: Leaderboard.Delta] = [:],
                               calibration: Calibration.Live = .none) -> String {
        let columns = run.columns
        guard !columns.isEmpty else { return "status     no columns ran" }
        var lines: [String] = []

        let status = columns.map { col -> String in
            var s = "\(col.formatter) \(col.gate.status.rawValue)"
            var why: [String] = []
            if col.gate.answered > 0 { why.append("answered \(col.gate.answered)") }
            if col.gate.invented > 0 { why.append("invented \(col.gate.invented)") }
            if col.gate.negated > 0 { why.append("negated \(col.gate.negated)") }
            if col.gate.overEditFact > 0 { why.append("over_edit_fact \(col.gate.overEditFact)") }
            if let pct = col.gate.controlsUnchangedPct, pct < EvalThresholds.failControlsUnchangedPct {
                why.append("controls \(number(pct))%")
            }
            if col.fallbacks.harnessFailures > 0 { why.append("harness fallbacks \(col.fallbacks.harnessFailures)") }
            if col.gate.latencyOverBudget { why.append("latency") }
            if !why.isEmpty { s += "(" + why.joined(separator: ", ") + ")" }
            return s
        }.joined(separator: " | ")
        lines.append(pad("status") + status + "        DRAFT GOLDS: \(run.fixtures.draftN)/\(run.fixtures.n)")

        let composite = columns.map { col -> String in
            var s = "\(col.formatter) \(number(col.scores.c))"
            if let delta = deltas[col.formatter] { s += " (Δ \(Leaderboard.signed(delta.c)))" }
            return s
        }.joined(separator: " | ")
        lines.append(pad("composite") + composite + "        " + calibration.banner)

        let axes = ["F": columns.map { $0.scores.f }, "Fi": columns.map { $0.scores.fi }, "M": columns.map { $0.scores.m }]
        lines.append(pad("axes") + ["F", "Fi", "M"].map { axis in
            "\(axis) " + axes[axis]!.map { number($0, places: 0) }.joined(separator: "/")
        }.joined(separator: " · "))

        for col in columns {
            guard let l = col.latencyMs else { continue }
            var s = "\(col.formatter) p50 \(ms(l.p50)) p90 \(ms(l.p90)) p99 \(ms(l.p99))"
            if let short = l.p99Short { s += " (≤\(EvalThresholds.warnLatencyMaxWords)w \(short))" }
            s += " max \(ms(l.max)) · over \(l.budget)ms \(l.overBudget)/\(l.nLlm)"
            if let mpw = l.msPerWord { s += " · \(number(mpw)) ms/word" }
            if !l.reprimeMs.isEmpty { s += " · reprime " + l.reprimeMs.map(String.init).joined(separator: ",") }
            // An empty sample is no evidence either way — never "ok".
            s += l.nLlm == 0 ? " · n/a (every timed row was a re-prime)" : col.gate.latencyOverBudget ? " · WARN" : " · ok"
            lines.append(pad("latency") + s)
        }

        let tags = Set(columns.flatMap { $0.byTag.keys })
        if !tags.isEmpty {
            let ordered = tags.sorted { a, b in
                let na = columns.compactMap { $0.byTag[a]?.n }.max() ?? 0
                let nb = columns.compactMap { $0.byTag[b]?.n }.max() ?? 0
                return na != nb ? na > nb : a < b
            }
            lines.append(pad("by tag") + ordered.map { tag in
                let n = columns.compactMap { $0.byTag[tag]?.n }.max() ?? 0
                return "\(tag) " + columns.map { number($0.byTag[tag]?.c) }.joined(separator: "/") + " (\(n))"
            }.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Fallback lines

    /// The provenance block printed under the continuity aggregate, one
    /// column at a time (§5). Fast-path and raw-mode fallbacks are the
    /// stage's DESIGN — the model is skipped on short utterances on-device
    /// too; timed-out and rejected rows are real behaviour, counted and
    /// scored as the fallback text the user actually got; only
    /// `unavailable` / `request-failed` mean the harness — not the design
    /// — failed, and those alone make the column INVALID. The status line
    /// and the exit code read the same `Fallbacks.harnessFailures`, so the
    /// two verdicts on the screen can never disagree. The shipped column
    /// records no provenance (`HistoryRecord` has no source column); its
    /// line says how the model path was inferred (`EvalPlan.shippedSource`).
    /// The rules column has no model and prints nothing.
    public static func fallbackLines(_ column: EvalRun.Column,
                                     fastPathWordLimit: Int = TextFormatter.Config().fastPathWordLimit) -> [String] {
        let label = "  " + column.formatter.padding(toLength: 10, withPad: " ", startingAt: 0) + " "
        switch column.formatter {
        case "rules":
            return []
        case "shipped":
            return [label + "fallbacks: n/a (history records no provenance; a row is a model row when production "
                    + "would have run the model — ≥ \(fastPathWordLimit) words, or a correction cue at standard, "
                    + "and not over the \(TextFormatter.Config().llmWordLimit)-word ceiling — else rules)"]
        default:
            break
        }
        let f = column.fallbacks
        let n = column.rows.count
        let total = f.fastPath + f.tooLong + f.rawMode + f.timedOut + f.rejected + f.unavailable + f.requestFailed
        func counts(_ pairs: [(String, Int)]) -> String {
            pairs.filter { $0.1 > 0 }.map { "\($0.0) ×\($0.1)" }.joined(separator: ", ")
        }
        var parts: [String] = []
        if f.fastPath + f.tooLong + f.rawMode > 0 {
            parts.append("by design: " + counts([
                ("fast-path", f.fastPath), ("too-long", f.tooLong), ("raw-mode", f.rawMode)]))
        }
        if f.timedOut + f.rejected > 0 {
            parts.append("scored as the fallback text: " + counts([("timed-out", f.timedOut), ("rejected", f.rejected)]))
        }
        if f.harnessFailures > 0 {
            parts.append("harness: " + counts([("unavailable", f.unavailable), ("request-failed", f.requestFailed)]))
        }
        var lines = [label + "fallbacks: \(total)/\(n)" + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · "))]
        if f.harnessFailures > 0 {
            lines.append(label + "INVALID — \(f.harnessFailures)/\(n) fell back to rules because the harness failed; NOT model evidence")
        }
        return lines
    }

    // MARK: - Markdown report

    /// The `--report` file. `cases` supplies raw / gold for the gated
    /// rows; `previous` is the leaderboard's previous comparable row per
    /// formatter (empty without `--append`).
    public static func markdown(_ run: EvalRun, cases: [EvalCase],
                                previous: [String: EvalRun.LeaderboardRow] = [:],
                                calibration: Calibration.Live = .none) -> String {
        let byId = Dictionary(cases.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var md: [String] = []
        md.append("# whispr-bench eval — \(run.runId)")
        md.append("")
        md.append("- date: \(run.date) · git: `\(run.gitSha)`\(run.dirty ? " (dirty)" : "") · machine: \(run.machine.model) / macOS \(run.machine.os)")
        md.append("- fixtures: **\(run.fixtures.name)** n=\(run.fixtures.n) (rated \(run.fixtures.ratedN), draft \(run.fixtures.draftN), unrated \(run.fixtures.unratedN)) · sha256 `\(run.fixtures.sha256.prefix(12))` · path `\(run.fixtures.path)`")
        md.append("- scoring_version: \(run.scoringVersion) · schema: \(run.schema)")
        md.append("- **\(calibration.banner)**"
                  + (calibration.zeroEditRates.isEmpty ? "" : " · zero-edit "
                     + calibration.zeroEditRates.keys.sorted()
                        .map { String(format: "%@ %.1f%%", $0, calibration.zeroEditRates[$0]!) }
                        .joined(separator: " · ")))
        md.append("")

        md.append("## Leaderboard rows")
        md.append("")
        md.append("| formatter | model | level | C | F | Fi | M | status | p50 | p99 | Δ C | vs |")
        md.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for col in run.columns {
            let row = run.leaderboardRow(col)
            var deltaC = "—", vs = "—"
            if let prev = previous[col.formatter], let delta = try? Leaderboard.diff(prev, row) {
                deltaC = Leaderboard.signed(delta.c)
                vs = "`\(prev.runKey)` \(prev.gitSha)"
            }
            let level = col.level + (col.config.ranSelfRepair ? "" : " (self-repair off)")
            md.append("| \(col.formatter) | \(col.modelKey ?? "—") | \(level) | \(number(col.scores.c)) | \(number(col.scores.f)) | \(number(col.scores.fi)) | \(number(col.scores.m)) | \(col.gate.status.rawValue) | \(ms(col.latencyMs?.p50)) | \(ms(col.latencyMs?.p99)) | \(deltaC) | \(vs) |")
        }
        md.append("")
        md.append("`run_key`: " + run.columns.map { "\($0.formatter) `\($0.runKey)`" }.joined(separator: " · "))
        md.append("")

        md.append("## Verdicts")
        md.append("")
        md.append("| verdict | " + run.columns.map(\.formatter).joined(separator: " | ") + " |")
        md.append("|---|" + String(repeating: "---|", count: run.columns.count))
        for verdict in EvalVerdict.allCases {
            md.append("| \(verdict.rawValue) | " + run.columns.map { String($0.verdicts[verdict.rawValue] ?? 0) }.joined(separator: " | ") + " |")
        }
        md.append("")
        for col in run.columns {
            let g = col.gate
            var s = "- \(col.formatter): controls unchanged \(g.controlsUnchanged)/\(g.controls)"
            if let pct = g.controlsUnchangedPct { s += " (\(number(pct))%)" }
            md.append(s)
        }
        md.append("")

        md.append("## Gated fixtures")
        md.append("")
        var anyGated = false
        for col in run.columns {
            let gated = col.rows.filter { EvalVerdict(rawValue: $0.verdict)?.isGated == true }
                .sorted { (EvalVerdict(rawValue: $0.verdict)?.rank ?? 99) < (EvalVerdict(rawValue: $1.verdict)?.rank ?? 99) }
            for row in gated {
                anyGated = true
                md.append("### \(row.id) — \(col.formatter) **\(row.verdict)** (\(row.triggers.joined(separator: ", ")))")
                md.append("")
                if let c = byId[row.id] {
                    md.append("- raw: \(quote(c.raw))")
                    md.append("- out: \(quote(row.out))")
                    if c.isGoldFree {
                        md.append("- gold: _(unrated)_")
                        md.append("- diff vs raw: \(quote(wordDiff(gold: c.raw, out: row.out)))")
                    } else {
                        md.append("- gold: \(quote(c.acceptableGolds[min(row.goldIndex, c.acceptableGolds.count - 1)]))")
                        md.append("- diff vs gold: \(quote(wordDiff(gold: c.acceptableGolds[min(row.goldIndex, c.acceptableGolds.count - 1)], out: row.out)))")
                    }
                } else {
                    md.append("- out: \(quote(row.out))")
                }
                if let rejected = row.rejected {
                    md.append("- rejected model output (\(row.modelVerdict ?? "?")): \(quote(rejected))")
                }
                md.append("- " + rowSummary(row))
                md.append("")
            }
            // A gate the stage refused: the report reads "stage PASS, model ANSWERED".
            let rejected = col.rows.filter { $0.rejected != nil && EvalVerdict(rawValue: $0.verdict)?.isGated != true }
            for row in rejected {
                anyGated = true
                md.append("### \(row.id) — \(col.formatter) stage \(row.verdict), model **\(row.modelVerdict ?? "?")** (rejected)")
                md.append("")
                if let c = byId[row.id] { md.append("- raw: \(quote(c.raw))") }
                md.append("- out (fallback): \(quote(row.out))")
                md.append("- rejected: \(quote(row.rejected ?? ""))")
                md.append("")
            }
        }
        if !anyGated { md.append("_none_"); md.append("") }

        for col in run.columns {
            let scored = col.rows.filter { $0.c != nil }
            guard !scored.isEmpty else { continue }
            md.append("## Worst 10 by C — \(col.formatter)")
            md.append("")
            md.append("| id | C | verdict | F | Fi | M | D | lost | I | novel | ms |")
            md.append("|---|---|---|---|---|---|---|---|---|---|---|")
            for row in scored.sorted(by: { ($0.c ?? 0, $0.id) < ($1.c ?? 0, $1.id) }).prefix(10) {
                md.append("| \(row.id) | \(number(row.c)) | \(row.verdict) | \(number(row.f)) | \(number(row.fi)) | \(number(row.m)) | \(row.dels) | \(row.lost.map(String.init) ?? "—") | \(row.ins) | \(row.novel) | \(row.ms.map(String.init) ?? "—") |")
            }
            md.append("")
        }

        for col in run.columns {
            guard let l = col.latencyMs else { continue }
            md.append("## Latency — \(col.formatter)")
            md.append("")
            md.append("- n_llm \(l.nLlm) · p50 \(ms(l.p50)) · p90 \(ms(l.p90)) · p99 \(ms(l.p99))\(l.p99Short.map { " (≤\(EvalThresholds.warnLatencyMaxWords)w \($0))" } ?? "") · max \(ms(l.max)) · over \(l.budget)ms: \(l.overBudget)\(l.msPerWord.map { " · \(number($0)) ms/word" } ?? "")")
            md.append("- reprime_ms: " + (l.reprimeMs.isEmpty ? "—" : l.reprimeMs.map(String.init).joined(separator: ", ")))
            md.append("")
            md.append("| words | n | p50 | p99 |")
            md.append("|---|---|---|---|")
            for key in ["<=15", "16-60", "61-150", ">150"] {
                guard let b = l.byLength[key] else { continue }
                md.append("| \(key) | \(b.n) | \(b.p50) | \(b.p99) |")
            }
            md.append("")
        }

        md.append("## Provenance")
        md.append("")
        md.append("| column | model rows | fast-path | too-long | raw-mode | timed-out | rejected | unavailable | request-failed |")
        md.append("|---|---|---|---|---|---|---|---|---|")
        for col in run.columns {
            let f = col.fallbacks
            let model = col.rows.filter { $0.source == "model" }.count
            md.append("| \(col.formatter) | \(model) | \(f.fastPath) | \(f.tooLong) | \(f.rawMode) | \(f.timedOut) | \(f.rejected) | \(f.unavailable) | \(f.requestFailed) |")
        }
        md.append("")

        if run.columns.contains(where: { !$0.byTag.isEmpty }) {
            md.append("## By tag (C)")
            md.append("")
            md.append("| tag | n | " + run.columns.map(\.formatter).joined(separator: " | ") + " |")
            md.append("|---|---|" + String(repeating: "---|", count: run.columns.count))
            let tags = Set(run.columns.flatMap { $0.byTag.keys }).sorted()
            for tag in tags {
                let n = run.columns.compactMap { $0.byTag[tag]?.n }.max() ?? 0
                md.append("| \(tag) | \(n) | " + run.columns.map { number($0.byTag[tag]?.c) }.joined(separator: " | ") + " |")
            }
            md.append("")
        }
        return md.joined(separator: "\n")
    }

    // MARK: - Word diff

    /// Inline word diff of `out` against `gold` on the scorer's own
    /// alignment: `[-gold-]` for a dropped word, `{+out+}` for an added
    /// one, `[-a-]{+b+}` for a substitution; hits print as the output
    /// wrote them (case and marks), so a punctuation-only miss reads as a
    /// clean line with the wrong mark, not as an edit.
    public static func wordDiff(gold: String, out: String) -> String {
        let g = Align.canonicalTokens(gold)
        let o = Align.canonicalTokens(out)
        var parts: [String] = []
        for op in Align.align(g, o).ops {
            switch op {
            case .hit(_, let j): parts.append(surface(o[j]))
            case .sub(let i, let j): parts.append("[-\(surface(g[i]))-]{+\(surface(o[j]))+}")
            case .del(let i): parts.append("[-\(surface(g[i]))-]")
            case .ins(let j): parts.append("{+\(surface(o[j]))+}")
            }
        }
        return parts.joined(separator: " ")
    }

    static func surface(_ token: EvalToken) -> String {
        String(token.leadingMarks) + token.cased + String(token.trailingMarks)
    }

    // MARK: - Helpers

    static func number(_ x: Double?, places: Int = 1) -> String {
        guard let x else { return "—" }
        return String(format: "%.\(places)f", x)
    }

    /// A millisecond figure, or `—` where the sample was empty.
    static func ms(_ x: Int?) -> String {
        x.map(String.init) ?? "—"
    }

    static func pad(_ label: String) -> String {
        label.count >= 11 ? label + " " : label + String(repeating: " ", count: 11 - label.count)
    }

    /// One line, code-quoted, so a markdown table or bullet cannot be
    /// broken by a newline or a pipe in the text.
    static func quote(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ").replacingOccurrences(of: "|", with: "\\|")
        return flat.isEmpty ? "_(empty)_" : "`" + flat.replacingOccurrences(of: "`", with: "'") + "`"
    }
}
