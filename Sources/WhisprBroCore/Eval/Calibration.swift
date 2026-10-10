import Foundation

/// `whispr-bench calibrate` (plan §7.4): the six checks that decide
/// whether the composite may be called a validated metric, and the
/// `calibration.json` the report writes beside itself so `eval` and the
/// leaderboard can read the answer instead of assuming it.
///
/// The design rule under all of it: **the metric is never claimed above
/// the evidence.** Checks 2–5 must PASS on ≥ 100 rated rows and ≥ 40
/// pairs; anything less is `PENDING`, whatever the numbers say. Raw
/// agreement is printed and never used (it overstates κ by 30–40 pp). The
/// logistic fit is printed as a suggestion and never applied — a weight
/// change is his decision, bumps `scoring_version`, and re-grades stored
/// runs through `score`. Check 1 is his own test-retest consistency: the
/// ceiling the metric may never be claimed above.
public enum Calibration {
    public enum Thresholds {
        /// Check 2 — metric verdict vs his, quadratic-weighted κ.
        public static let weightedKappa = 0.6
        /// Check 3 — ANSWERED / INVENTED / NEGATED recall.
        public static let gateRecall = 0.9
        /// Check 3 — over-edit precision (a false over-edit costs him trust).
        public static let overEditPrecision = 0.7
        /// Check 4 — AUROC of M ranking WRONG below the rest.
        public static let meaningAuroc = 0.9
        /// Check 4 — AUROC of C for SHIP vs the rest.
        public static let compositeAuroc = 0.85
        /// Check 5 — Kendall τ_b over the pairwise picks.
        public static let kendallTau = 0.5
        /// Check 5 — Spearman ρ of C against his 3-level rating.
        public static let spearmanRho = 0.7
        /// VALID needs this many rated rows …
        public static let minRatedRows = 100
        /// … and this many pairwise picks.
        public static let minPairs = 40
        /// Check 1 counts a re-rate only this far apart (§7.4: a memory of
        /// the row is not a second opinion).
        public static let reRateDays = 7
    }

    /// The chip he presses for each gate (§7.1's fixed list, `negated`
    /// included since check 3 gates VALID on its recall). A gate nobody
    /// has tagged yet still reports `n/a` rather than a number computed
    /// against labels that do not exist — and an `n/a` here holds the
    /// whole check at PENDING, because §7.4 names all three recalls. The
    /// over-edit precision beside them is the same row of the same table,
    /// so an unmeasurable one holds the check exactly as a recall does.
    public static let gateChips: [(verdict: EvalVerdict, chips: [String])] = [
        (.answered, ["answered"]),
        (.invented, ["invented"]),
        (.negated, ["negated"]),
    ]
    public static let overEditChips = ["dropped-fact", "dropped-hedge"]

    /// §7.4 check 2's mapping: what the metric's verdict predicts he will
    /// press.
    public static func expected(_ verdict: EvalVerdict) -> Rating.Verdict {
        switch verdict {
        case .pass: return .ship
        case .punct, .missed: return .fix
        case .answered, .invented, .negated, .overEditFact, .overEditHedge, .reworded, .unrated: return .wrong
        }
    }

    /// One rating joined to the row the metric scored for the same output.
    public struct Joined: Sendable, Equatable {
        public let rating: Rating
        public let row: EvalRun.Row
        public let formatter: String

        public var verdict: Rating.Verdict? { rating.verdict }
        public var metric: EvalVerdict { EvalVerdict(rawValue: row.verdict) ?? .unrated }
    }

    public enum Status: String, Sendable, Equatable {
        case pass = "PASS"
        case fail = "FAIL"
        /// Not enough evidence to compute the statistic at all.
        case pending = "n/a"
    }

    public struct Check: Sendable, Equatable {
        public let number: Int
        public let name: String
        public let statistic: String
        public let value: Double?
        public let target: String
        public let status: Status
        public let detail: [String]

        /// Only a PASS counts toward VALID; `n/a` never does.
        public var passes: Bool { status == .pass }
    }

    /// The machine-readable half, written beside `calibration.md` so the
    /// banner and the leaderboard row can read the verdict instead of
    /// guessing it.
    public struct Record: Codable, Sendable, Equatable {
        public var fixturesSha256: String
        public var valid: Bool
        public var n: Int
        public var pairs: Int
        public var kappaWeighted: Double?
        public var date: String

        enum CodingKeys: String, CodingKey {
            case valid, n, pairs, date
            case fixturesSha256 = "fixtures_sha256"
            case kappaWeighted = "kappa_weighted"
        }

        public init(fixturesSha256: String, valid: Bool, n: Int, pairs: Int,
                    kappaWeighted: Double?, date: String) {
            self.fixturesSha256 = fixturesSha256
            self.valid = valid
            self.n = n
            self.pairs = pairs
            self.kappaWeighted = kappaWeighted
            self.date = date
        }

        public func canonicalJSON() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
            return try encoder.encode(self) + Data("\n".utf8)
        }

        public static func load(_ data: Data) throws -> Record {
            try JSONDecoder().decode(Record.self, from: data)
        }

        /// The one question `eval` asks it: may a row scored on THIS
        /// fixture set call itself calibrated?
        public func calibrates(fixturesSha256: String) -> Bool {
            valid && self.fixturesSha256 == fixturesSha256
        }
    }

    public struct Report: Sendable, Equatable {
        public let checks: [Check]
        public let valid: Bool
        /// Rated rows the report could join to a scored row.
        public let n: Int
        public let pairs: Int
        public let kappaWeighted: Double?
        /// Check 1: his own test–retest κ, the ceiling.
        public let ceiling: Double?
        public let zeroEditRates: [String: Double]
        public let logistic: Stats.LogisticFit?
        public let fixturesSha256: String
        public let fixturesName: String
        public let date: String
        /// Ratings with no scored row in the runs passed.
        public let unmatched: Int

        public var record: Record {
            Record(fixturesSha256: fixturesSha256, valid: valid, n: n, pairs: pairs,
                   kappaWeighted: kappaWeighted, date: date)
        }

        /// `CALIBRATION: VALID (n=124 rated)` / `… PENDING (n=12 rated)` —
        /// the banner every report and leaderboard row carries.
        public var banner: String { EvalReport.calibrationBanner(rated: n, valid: valid) }

        public func markdown() -> String {
            var md: [String] = []
            md.append("# whispr-bench calibrate — \(fixturesName)")
            md.append("")
            md.append("- date: \(date) · fixtures sha256 `\(fixturesSha256.prefix(12))`")
            md.append("- rated rows joined: **\(n)** · pairwise picks: **\(pairs)**"
                      + (unmatched > 0 ? " · \(unmatched) rating(s) with no scored row" : ""))
            md.append("- **\(banner)**"
                      + (valid ? "" : " — checks 2–5 must PASS on ≥ \(Thresholds.minRatedRows) rated rows "
                         + "and ≥ \(Thresholds.minPairs) pairs"))
            md.append("- ceiling (his own re-rate κ): \(number(ceiling)) — the metric is never claimed above it")
            md.append("")
            md.append("| # | check | statistic | value | target | status |")
            md.append("|---|---|---|---|---|---|")
            for check in checks {
                md.append("| \(check.number) | \(check.name) | \(check.statistic) | \(number(check.value)) "
                          + "| \(check.target) | \(check.status.rawValue) |")
            }
            md.append("")
            for check in checks where !check.detail.isEmpty {
                md.append("### \(check.number). \(check.name)")
                md.append("")
                md += check.detail.map { "- " + $0 }
                md.append("")
            }
            md.append("## Zero-edit rate")
            md.append("")
            if zeroEditRates.isEmpty {
                md.append("_no ratings yet_")
            } else {
                md.append("| column | zero-edit rate |")
                md.append("|---|---|")
                for key in zeroEditRates.keys.sorted() {
                    md.append("| \(key) | \(String(format: "%.1f%%", zeroEditRates[key]!)) |")
                }
            }
            md.append("")
            md.append("## Suggested weights (printed, never applied)")
            md.append("")
            if let logistic, let weights = logistic.suggestedWeights, weights.count == 3 {
                md.append("Logistic fit SHIP ~ F + Fi + M over \(logistic.n) row(s), "
                          + "\(logistic.iterations) IRLS iteration(s)"
                          + (logistic.separated ? " — **separated / not converged**, read as a direction only" : "")
                          + ".")
                md.append("")
                md.append("| axis | current | suggested |")
                md.append("|---|---|---|")
                for (i, axis) in ["F", "Fi", "M"].enumerated() {
                    md.append("| \(axis) | \(String(format: "%.2f", Calibration.currentWeights[i])) "
                              + "| \(String(format: "%.2f", weights[i])) |")
                }
                md.append("")
                md.append("A weight change is a hand edit: bump `scoring_version` and re-grade stored runs "
                          + "with `whispr-bench score`.")
            } else {
                md.append("_not enough evidence for a fit_")
            }
            md.append("")
            return md.joined(separator: "\n")
        }

        private func number(_ x: Double?) -> String {
            x.map { String(format: "%.3f", $0) } ?? "—"
        }
    }

    /// F / Fi / M as the composite weighs them today (§5) — the row the
    /// suggestion is compared against.
    static let currentWeights = [EvalThresholds.compositeFormatWeight, EvalThresholds.compositeFillerWeight,
                                 EvalThresholds.compositeMeaningWeight]

    // MARK: - The report

    public static func report(fixtures: [EvalCase], runs: [EvalRun], ratings: [Rating],
                              fixturesSha256: String? = nil, fixturesName: String = "fixtures",
                              date: String) -> Report {
        let ids = Set(fixtures.map(\.id))
        let triage = ratings.filter { $0.isTriage && $0.verdict != nil && ids.contains($0.fixtureId) }
        let rows = index(runs)
        var joined: [Joined] = []
        var unmatched = 0
        for rating in triage {
            guard let row = rows.row(fixtureId: rating.fixtureId, outputSha: rating.outputSha) else {
                unmatched += 1
                continue
            }
            joined.append(Joined(rating: rating, row: row.row, formatter: row.formatter))
        }
        let pairRatings = ratings.filter { $0.isPairwise && ids.contains($0.fixtureId) }

        let checks = [
            consistency(triage),
            verdictAgreement(joined),
            gates(joined),
            separation(joined),
            ranking(joined, pairs: pairRatings, rows: rows),
            weights(joined),
        ]
        let pairs = pairRatings.filter { $0.pair?.isTie == false }.count
        let core = checks.filter { (2...5).contains($0.number) }
        let valid = core.allSatisfy(\.passes)
            && joined.count >= Thresholds.minRatedRows
            && pairs >= Thresholds.minPairs
        let sha = fixturesSha256 ?? ((try? EvalCase.fixtureSetHash(fixtures)) ?? "")
        return Report(checks: checks, valid: valid, n: joined.count, pairs: pairs,
                      kappaWeighted: checks.first { $0.number == 2 }?.value,
                      ceiling: checks.first { $0.number == 1 }?.value,
                      zeroEditRates: RatingLog.zeroEditRates(ratings, ids: ids),
                      logistic: fit(joined), fixturesSha256: sha, fixturesName: fixturesName,
                      date: date, unmatched: unmatched)
    }

    // MARK: Check 1 — his own ceiling

    static func consistency(_ ratings: [Rating]) -> Check {
        var byOutput: [Rating.Key: [Rating]] = [:]
        for rating in ratings { byOutput[rating.key, default: []].append(rating) }
        var first: [Int] = [], second: [Int] = []
        for (_, records) in byOutput.sorted(by: { $0.key.fixtureId < $1.key.fixtureId }) {
            let dated = records.compactMap { r -> (Date, Rating)? in r.ratedAtDate.map { ($0, r) } }
                .sorted { $0.0 < $1.0 }
            guard let earliest = dated.first else { continue }
            // The first re-rate at least `reRateDays` later: a rating from
            // the same sitting is a memory, not a second opinion.
            guard let later = dated.first(where: {
                $0.0.timeIntervalSince(earliest.0) >= Double(Thresholds.reRateDays) * 86_400
            }) else { continue }
            first.append(earliest.1.verdict!.level)
            second.append(later.1.verdict!.level)
        }
        let kappa = first.count >= 2 ? Stats.cohensKappa(first, second, categories: 3) : nil
        var detail = ["\(first.count) row(s) rated twice ≥ \(Thresholds.reRateDays) days apart"]
        if let agreement = Stats.agreement(first, second) {
            detail.append(String(format: "raw agreement %.3f (printed, never a target)", agreement))
        }
        if kappa == nil { detail.append("no ceiling yet — re-rate ~20 rows a week later") }
        return Check(number: 1, name: "his own consistency", statistic: "Cohen's κ", value: kappa,
                     target: "the ceiling", status: kappa == nil ? .pending : .pass, detail: detail)
    }

    // MARK: Check 2 — metric verdict vs his

    static func verdictAgreement(_ joined: [Joined]) -> Check {
        let mine = joined.map { expected($0.metric).level }
        let his = joined.map { $0.verdict!.level }
        let kappa = Stats.weightedKappa(mine, his, categories: 3)
        var detail: [String] = []
        if let agreement = Stats.agreement(mine, his) {
            detail.append(String(format: "raw agreement %.3f — printed, never used (it overstates κ by 30–40 pp)",
                                 agreement))
        }
        detail.append("mapping: PASS → ship · PUNCT / MISSED → fix · everything else → wrong")
        // Where the two disagree most, by metric verdict.
        var misses: [String: Int] = [:]
        for row in joined where expected(row.metric) != row.verdict! {
            misses["\(row.metric.rawValue) → \(row.verdict!.rawValue)", default: 0] += 1
        }
        for key in misses.keys.sorted(by: { (misses[$0]!, $1) > (misses[$1]!, $0) }).prefix(5) {
            detail.append("disagreed \(misses[key]!)× on \(key)")
        }
        return Check(number: 2, name: "metric verdict vs his", statistic: "weighted κ", value: kappa,
                     target: "≥ \(Thresholds.weightedKappa)",
                     status: status(kappa, min: Thresholds.weightedKappa), detail: detail)
    }

    // MARK: Check 3 — the gates against his tags

    static func gates(_ joined: [Joined]) -> Check {
        var detail: [String] = []
        var results: [Bool] = []
        var unmeasured: [String] = []
        var overEditUnmeasured = false
        var worst: Double?
        for (verdict, chips) in gateChips {
            let predicted = joined.map { $0.metric == verdict }
            let actual = joined.map { row in row.rating.tags.contains { chips.contains($0) } }
            let rates = Stats.rates(predicted: predicted, actual: actual)
            guard let recall = rates.recall else {
                // §7.4 names all three recalls as conditions of VALID, so
                // an unmeasured one blocks the check rather than dropping
                // out of it — a sub-check that neither passes nor fails
                // would let VALID through on evidence nobody has.
                unmeasured.append(verdict.rawValue)
                detail.append("\(verdict.rawValue): recall n/a — he never tagged "
                              + chips.map { "`\($0)`" }.joined(separator: " / "))
                continue
            }
            results.append(recall >= Thresholds.gateRecall)
            worst = min(worst ?? recall, recall)
            detail.append(String(format: "%@: recall %.3f (%d/%d), precision %@",
                                 verdict.rawValue, recall, rates.truePositives,
                                 rates.truePositives + rates.falseNegatives,
                                 rates.precision.map { String(format: "%.3f", $0) } ?? "n/a"))
        }
        let overEditPredicted = joined.map { $0.metric == .overEditFact || $0.metric == .overEditHedge }
        let overEditActual = joined.map { row in row.rating.tags.contains { overEditChips.contains($0) } }
        let overEdit = Stats.rates(predicted: overEditPredicted, actual: overEditActual)
        if let precision = overEdit.precision {
            results.append(precision >= Thresholds.overEditPrecision)
            detail.append(String(format: "OVER_EDIT: precision %.3f (%d/%d), recall %@",
                                 precision, overEdit.truePositives,
                                 overEdit.truePositives + overEdit.falsePositives,
                                 overEdit.recall.map { String(format: "%.3f", $0) } ?? "n/a"))
        } else {
            // The same rule as the three recalls above: §7.4 names
            // over-edit precision a condition of VALID, so a precision
            // nobody can compute holds the check at PENDING instead of
            // quietly dropping out of the verdict it is named in.
            overEditUnmeasured = true
            detail.append("OVER_EDIT: precision n/a — the metric flagged none")
        }
        if !unmeasured.isEmpty {
            detail.append("PENDING: \(unmeasured.joined(separator: " / ")) recall is a §7.4 gate and no rating "
                          + "carries its tag — unmeasured is never a PASS")
        }
        if overEditUnmeasured {
            detail.append("PENDING: OVER_EDIT precision is a §7.4 gate and the metric flagged no over-edit "
                          + "— unmeasured is never a PASS")
        }
        let value = overEdit.precision ?? worst
        let status: Status = results.contains(false) ? .fail
            : (results.isEmpty || !unmeasured.isEmpty || overEditUnmeasured) ? .pending : .pass
        return Check(number: 3, name: "gates vs his tags", statistic: "precision / recall", value: value,
                     target: "recall ≥ \(Thresholds.gateRecall) · over-edit precision ≥ \(Thresholds.overEditPrecision)",
                     status: status, detail: detail)
    }

    // MARK: Check 4 — separation

    static func separation(_ joined: [Joined]) -> Check {
        // M and C rank a row as BETTER when higher; the labels below are
        // the bad class, so M is negated to keep "≥ 0.9" meaning "clean
        // separation" rather than "inverted".
        let meaningRows = joined.filter { $0.row.m != nil }
        let meaning = Stats.auroc(scores: meaningRows.map { -($0.row.m ?? 0) },
                                  labels: meaningRows.map { $0.verdict == .wrong })
        let compositeRows = joined.filter { $0.row.c != nil }
        let composite = Stats.auroc(scores: compositeRows.map { $0.row.c ?? 0 },
                                    labels: compositeRows.map { $0.verdict == .ship })
        var detail = [
            "M vs WRONG: \(format(meaning)) over \(meaningRows.count) scored row(s) "
                + "(target ≥ \(Thresholds.meaningAuroc))",
            "C vs SHIP: \(format(composite)) over \(compositeRows.count) scored row(s) "
                + "(target ≥ \(Thresholds.compositeAuroc))",
        ]
        if meaning == nil || composite == nil {
            detail.append("AUROC needs both classes present — gold-free rows carry no M or C")
        }
        let statuses = [status(meaning, min: Thresholds.meaningAuroc),
                        status(composite, min: Thresholds.compositeAuroc)]
        let status: Status = statuses.contains(.fail) ? .fail
            : statuses.contains(.pending) ? .pending : .pass
        return Check(number: 4, name: "separation", statistic: "AUROC (M / C)", value: meaning,
                     target: "≥ \(Thresholds.meaningAuroc) / ≥ \(Thresholds.compositeAuroc)",
                     status: status, detail: detail)
    }

    // MARK: Check 5 — ranking

    static func ranking(_ joined: [Joined], pairs: [Rating], rows: RowIndex) -> Check {
        // τ_b over the pairwise picks: x = the composite's own preference
        // (C_a − C_b), y = his. Ties ("=") are excluded (§7.4).
        var x: [Double] = [], y: [Double] = []
        var missing = 0
        for rating in pairs {
            guard let pair = rating.pair, !pair.isTie else { continue }
            guard let a = rows.composite(fixtureId: rating.fixtureId, runKey: pair.aRun),
                  let b = rows.composite(fixtureId: rating.fixtureId, runKey: pair.bRun) else {
                missing += 1
                continue
            }
            x.append(a - b)
            y.append(Double(pair.preference))
        }
        let tau = Stats.kendallTauB(x, y)
        let rho = Stats.spearmanRho(joined.compactMap { $0.row.c },
                                    joined.filter { $0.row.c != nil }.map { Double($0.verdict!.level) })
        var detail = [
            "τ_b over \(x.count) non-tied pick(s): \(format(tau)) (target ≥ \(Thresholds.kendallTau))",
        ]
        // τ_b is undefined the moment one column is constant — including
        // the case where he and the composite agree PERFECTLY, which reads
        // as "not enough picks yet" unless it says otherwise. The share of
        // picks whose side the composite also took is printed beside it,
        // defined wherever there is a pick at all.
        if let agreement = signAgreement(x, y) {
            detail.append(String(format: "sign agreement %.3f — the share of his picks the composite also made",
                                 agreement))
        }
        if tau == nil, !x.isEmpty {
            detail.append("τ_b is undefined here: "
                          + (Set(y).count == 1 ? "every pick landed on the same side of the screen"
                             : Set(x).count == 1 ? "the composite scored both runs the same on every pair"
                             : "one of the two columns is entirely tied"))
        }
        detail.append("ρ of C vs his 3-level rating over \(joined.filter { $0.row.c != nil }.count) row(s): "
                      + "\(format(rho)) (target ≥ \(Thresholds.spearmanRho))")
        if missing > 0 { detail.append("\(missing) pick(s) whose runs were not passed with --runs") }
        let statuses = [status(tau, min: Thresholds.kendallTau), status(rho, min: Thresholds.spearmanRho)]
        let status: Status = statuses.contains(.fail) ? .fail
            : statuses.contains(.pending) ? .pending : .pass
        return Check(number: 5, name: "ranking", statistic: "τ_b / ρ", value: tau,
                     target: "≥ \(Thresholds.kendallTau) / ≥ \(Thresholds.spearmanRho)",
                     status: status, detail: detail)
    }

    /// The share of non-tied picks where the composite preferred the same
    /// run he did — τ_b's direction without its tie correction, so it
    /// survives a constant column. nil with nothing to count.
    static func signAgreement(_ x: [Double], _ y: [Double]) -> Double? {
        let comparable = zip(x, y).filter { $0 != 0 && $1 != 0 }
        guard !comparable.isEmpty else { return nil }
        return Double(comparable.filter { ($0 > 0) == ($1 > 0) }.count) / Double(comparable.count)
    }

    // MARK: Check 6 — the weight suggestion

    static func weights(_ joined: [Joined]) -> Check {
        guard let fit = fit(joined) else {
            return Check(number: 6, name: "weights", statistic: "logistic SHIP ~ F + Fi + M", value: nil,
                         target: "suggestion only", status: .pending,
                         detail: ["not enough evidence for a fit (both classes and all three axes are needed)"])
        }
        var detail = ["fit over \(fit.n) row(s) in \(fit.iterations) IRLS iteration(s)"
                      + (fit.converged ? "" : " — did NOT converge")]
        if fit.separated { detail.append("the data separate perfectly: read the direction, not the magnitude") }
        if let weights = fit.suggestedWeights, weights.count == 3 {
            detail.append(String(format: "suggested F %.2f · Fi %.2f · M %.2f (today %.2f / %.2f / %.2f)",
                                 weights[0], weights[1], weights[2],
                                 currentWeights[0], currentWeights[1], currentWeights[2]))
        }
        detail.append("printed, never applied — a weight change bumps scoring_version and re-grades stored runs")
        return Check(number: 6, name: "weights", statistic: "logistic SHIP ~ F + Fi + M",
                     value: fit.suggestedWeights?.last, target: "suggestion only", status: .pending,
                     detail: detail)
    }

    static func fit(_ joined: [Joined]) -> Stats.LogisticFit? {
        let usable = joined.filter { $0.row.f != nil && $0.row.fi != nil && $0.row.m != nil }
        guard !usable.isEmpty else { return nil }
        return Stats.logisticFit(usable.map { [$0.row.f!, $0.row.fi!, $0.row.m!] },
                                 usable.map { $0.verdict == .ship })
    }

    // MARK: - Joining

    /// Every scored row of every run, reachable by (fixture, output digest)
    /// — the identity a rating record carries — and by (fixture, run key)
    /// for the pairwise comparison.
    public struct RowIndex: Sendable {
        var byOutput: [String: (row: EvalRun.Row, formatter: String)] = [:]
        var byRun: [String: EvalRun.Row] = [:]

        public func row(fixtureId: String, outputSha: String) -> (row: EvalRun.Row, formatter: String)? {
            byOutput[fixtureId + "\n" + outputSha]
        }

        public func composite(fixtureId: String, runKey: String) -> Double? {
            byRun[fixtureId + "\n" + runKey]?.c
        }
    }

    public static func index(_ runs: [EvalRun]) -> RowIndex {
        var index = RowIndex()
        for run in runs {
            for column in run.columns {
                for row in column.rows {
                    index.byOutput[row.id + "\n" + Rating.outputSha(row.out)] = (row, column.formatter)
                    index.byRun[row.id + "\n" + column.runKey] = row
                }
            }
        }
        return index
    }

    // MARK: - What eval and the leaderboard read

    /// The live state of the ratings on disk, as `eval` and
    /// `leaderboard` print it: how many of THIS fixture set's rows he has
    /// rated, whether a `calibration.json` calls the set valid, and the
    /// zero-edit rate per column. Built from the files, never assumed —
    /// the banner was a hard-coded constant until this existed, and a
    /// hard-coded "PENDING (n=0)" is a lie the moment he rates a row.
    public struct Live: Sendable, Equatable {
        /// Rated ROWS of this fixture set — the unit §7.4's "≥ 100 rated
        /// rows" gate is stated in, and the unit `Report.n` counts, so the
        /// one banner line means the same thing everywhere. nil when the
        /// rows on screen cannot be attributed to a fixture set at all
        /// (`leaderboard`, which holds rows and no fixtures): the banner
        /// then reads `n=—` rather than a number borrowed from another set.
        public var rated: Int?
        public var valid: Bool
        public var zeroEditRates: [String: Double]

        /// No ratings file in play: what `eval` prints without `--ratings`.
        public static let none = Live(rated: 0, valid: false, zeroEditRates: [:])

        public init(rated: Int?, valid: Bool, zeroEditRates: [String: Double]) {
            self.rated = rated
            self.valid = valid
            self.zeroEditRates = zeroEditRates
        }

        /// `ratings` is the whole log — it spans every set he has ever
        /// rated — so only `cases`' own rows count, and with no `cases` in
        /// hand NOTHING counts: a rated row of the personal set says
        /// nothing about a leaderboard of the seeds. A record calibrates a
        /// run only when it is valid AND hashed the same fixture set.
        public init(ratings: [Rating], cases: [EvalCase], record: Record?, fixturesSha256: String) {
            let ids: Set<String>? = cases.isEmpty ? nil : Set(cases.map(\.id))
            rated = ids.map { RatingLog.ratedRows(ratings, ids: $0) }
            valid = record?.calibrates(fixturesSha256: fixturesSha256) ?? false
            zeroEditRates = ids.map { RatingLog.zeroEditRates(ratings, ids: $0) } ?? [:]
        }

        /// `leaderboard`'s position: rows, no fixtures. Only a calibration
        /// record hashed against the row's own set may speak for it — its
        /// `n` is that set's rated rows, counted by `calibrate` itself.
        public init(record: Record?, fixturesSha256: String) {
            let own = record.flatMap { $0.fixturesSha256 == fixturesSha256 ? $0 : nil }
            rated = own?.n
            valid = own?.calibrates(fixturesSha256: fixturesSha256) ?? false
            zeroEditRates = [:]
        }

        public var banner: String { EvalReport.calibrationBanner(rated: rated, valid: valid) }

        public func zeroEditRate(_ formatter: String) -> Double? { zeroEditRates[formatter] }
    }

    // MARK: - Helpers

    static func status(_ value: Double?, min: Double) -> Status {
        guard let value else { return .pending }
        return value >= min ? .pass : .fail
    }

    static func format(_ x: Double?) -> String {
        x.map { String(format: "%.3f", $0) } ?? "n/a"
    }
}
