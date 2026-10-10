import Foundation

/// The statistics `whispr-bench calibrate` reports (plan §7.4): agreement
/// (Cohen's κ, quadratic-weighted κ), detection (precision / recall),
/// separation (AUROC by rank statistic), ranking (Kendall τ_b, Spearman ρ)
/// and a small logistic fit by Newton/IRLS.
///
/// Every one of them returns **nil where the statistic is undefined**
/// rather than a number that looks like evidence: κ on labels both sides
/// never varied, AUROC with one class empty, ρ on a constant column, τ_b
/// with everything tied, anything on n = 0. A calibration report that
/// printed 0.0 for "undefined" would read as a failed check instead of no
/// check at all, and the whole point of §7.4 is to refuse to claim the
/// metric is valid before the evidence exists.
public enum Stats {
    // MARK: - Agreement

    /// Raw agreement — printed beside κ, never used as a target: it
    /// overstates agreement by 30–40 pp on his label distribution (§7.4).
    public static func agreement(_ a: [Int], _ b: [Int]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        return Double(zip(a, b).filter { $0 == $1 }.count) / Double(a.count)
    }

    /// Cohen's κ over paired categorical labels in `0..<categories`.
    /// nil when the labels do not vary enough for chance agreement to be
    /// below 1 (two raters who both said SHIP every time agree perfectly
    /// and prove nothing).
    public static func cohensKappa(_ a: [Int], _ b: [Int], categories: Int) -> Double? {
        kappa(a, b, categories: categories, weight: { $0 == $1 ? 1 : 0 })
    }

    /// Quadratic-weighted κ: disagreeing by one level costs less than
    /// disagreeing by two (SHIP↔FIX is not SHIP↔WRONG). §7.4 check 2's
    /// statistic.
    public static func weightedKappa(_ a: [Int], _ b: [Int], categories: Int) -> Double? {
        guard categories > 1 else { return nil }
        let span = Double((categories - 1) * (categories - 1))
        return kappa(a, b, categories: categories) { i, j in
            let d = Double(i - j)
            return 1 - (d * d) / span
        }
    }

    private static func kappa(_ a: [Int], _ b: [Int], categories: Int,
                              weight: (Int, Int) -> Double) -> Double? {
        guard a.count == b.count, !a.isEmpty, categories > 0 else { return nil }
        guard a.allSatisfy({ (0..<categories).contains($0) }),
              b.allSatisfy({ (0..<categories).contains($0) }) else { return nil }
        let n = Double(a.count)
        var observed = Array(repeating: Array(repeating: 0.0, count: categories), count: categories)
        var rows = Array(repeating: 0.0, count: categories)
        var columns = Array(repeating: 0.0, count: categories)
        for (x, y) in zip(a, b) {
            observed[x][y] += 1
            rows[x] += 1
            columns[y] += 1
        }
        var po = 0.0, pe = 0.0
        for i in 0..<categories {
            for j in 0..<categories {
                let w = weight(i, j)
                po += w * observed[i][j] / n
                pe += w * (rows[i] / n) * (columns[j] / n)
            }
        }
        guard abs(1 - pe) > 1e-12 else { return nil }
        return (po - pe) / (1 - pe)
    }

    // MARK: - Detection

    /// One flag's confusion counts and its rates; precision is nil when
    /// nothing was flagged, recall nil when there was nothing to find.
    public struct Rates: Sendable, Equatable {
        public let truePositives: Int
        public let falsePositives: Int
        public let falseNegatives: Int
        public let trueNegatives: Int

        public var precision: Double? {
            let denominator = truePositives + falsePositives
            return denominator == 0 ? nil : Double(truePositives) / Double(denominator)
        }

        public var recall: Double? {
            let denominator = truePositives + falseNegatives
            return denominator == 0 ? nil : Double(truePositives) / Double(denominator)
        }

        public var f1: Double? {
            guard let p = precision, let r = recall, p + r > 0 else { return nil }
            return 2 * p * r / (p + r)
        }

        public var n: Int { truePositives + falsePositives + falseNegatives + trueNegatives }
    }

    public static func rates(predicted: [Bool], actual: [Bool]) -> Rates {
        var tp = 0, fp = 0, fn = 0, tn = 0
        for (p, a) in zip(predicted, actual) {
            switch (p, a) {
            case (true, true): tp += 1
            case (true, false): fp += 1
            case (false, true): fn += 1
            case (false, false): tn += 1
            }
        }
        return Rates(truePositives: tp, falsePositives: fp, falseNegatives: fn, trueNegatives: tn)
    }

    // MARK: - Separation

    /// AUROC of a score against a binary label, by the rank statistic
    /// (Mann–Whitney U with mid-ranks, so ties land at 0.5 instead of
    /// depending on sort order). nil when either class is empty.
    public static func auroc(scores: [Double], labels: [Bool]) -> Double? {
        guard scores.count == labels.count, !scores.isEmpty else { return nil }
        let positives = labels.filter { $0 }.count
        let negatives = labels.count - positives
        guard positives > 0, negatives > 0 else { return nil }
        let ranks = midRanks(scores)
        let positiveRankSum = zip(ranks, labels).filter { $0.1 }.map(\.0).reduce(0, +)
        let u = positiveRankSum - Double(positives * (positives + 1)) / 2
        return u / Double(positives * negatives)
    }

    /// 1-based ranks with ties averaged.
    static func midRanks(_ xs: [Double]) -> [Double] {
        let order = xs.enumerated().sorted { $0.element < $1.element }
        var ranks = Array(repeating: 0.0, count: xs.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count, order[j + 1].element == order[i].element { j += 1 }
            let rank = Double(i + j + 2) / 2          // mean of (i+1)…(j+1)
            for k in i...j { ranks[order[k].offset] = rank }
            i = j + 1
        }
        return ranks
    }

    // MARK: - Ranking

    /// Kendall's τ_b — concordant minus discordant pairs, with the tie
    /// correction in the denominator. nil when every pair is tied on one
    /// side (the denominator collapses) or n < 2.
    public static func kendallTauB(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count > 1 else { return nil }
        var concordant = 0.0, discordant = 0.0
        for i in 0..<x.count {
            for j in (i + 1)..<x.count {
                let dx = x[i] - x[j], dy = y[i] - y[j]
                let product = dx * dy
                if product > 0 { concordant += 1 } else if product < 0 { discordant += 1 }
            }
        }
        let pairs = Double(x.count * (x.count - 1)) / 2
        let denominator = sqrt((pairs - tieCorrection(x)) * (pairs - tieCorrection(y)))
        guard denominator > 1e-12 else { return nil }
        return (concordant - discordant) / denominator
    }

    /// Σ t(t−1)/2 over each tie group.
    static func tieCorrection(_ xs: [Double]) -> Double {
        var counts: [Double: Int] = [:]
        for x in xs { counts[x, default: 0] += 1 }
        return counts.values.reduce(0.0) { $0 + Double($1 * ($1 - 1)) / 2 }
    }

    /// Spearman's ρ — Pearson on mid-ranks, so ties are handled. nil when
    /// either column is constant (no order to correlate) or n < 2.
    public static func spearmanRho(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count > 1 else { return nil }
        return pearson(midRanks(x), midRanks(y))
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(x, y) {
            sxy += (a - mx) * (b - my)
            sxx += (a - mx) * (a - mx)
            syy += (b - my) * (b - my)
        }
        guard sxx > 1e-12, syy > 1e-12 else { return nil }
        return sxy / sqrt(sxx * syy)
    }

    // MARK: - Logistic fit

    /// §7.4 check 6's weight suggestion. Newton/IRLS with a FIXED
    /// iteration cap — this fit is printed, never applied, so a stubborn
    /// dataset must cost a bounded number of passes and say so.
    public struct LogisticFit: Sendable, Equatable {
        /// Intercept first, then one per predictor column.
        public let coefficients: [Double]
        public let iterations: Int
        public let converged: Bool
        /// The data separate perfectly: the MLE is at infinity and the
        /// coefficients below are only the point the cap stopped at.
        public let separated: Bool
        public let n: Int

        /// The predictors' coefficients as shares of their total, for the
        /// "suggested weights" line. nil when no coefficient is positive
        /// (nothing to share out).
        public var suggestedWeights: [Double]? {
            let slopes = coefficients.dropFirst().map { max(0, $0) }
            let total = slopes.reduce(0, +)
            guard total > 1e-9 else { return nil }
            return slopes.map { $0 / total }
        }
    }

    /// `x` is one row of predictors per observation (the intercept is
    /// added here). nil when the shapes disagree, when a class is empty,
    /// or when the design matrix is singular on the first pass.
    public static func logisticFit(_ x: [[Double]], _ y: [Bool],
                                   maxIterations: Int = 25, tolerance: Double = 1e-8) -> LogisticFit? {
        guard x.count == y.count, let width = x.first?.count, width > 0,
              x.allSatisfy({ $0.count == width }) else { return nil }
        let positives = y.filter { $0 }.count
        guard positives > 0, positives < y.count else { return nil }
        let design = x.map { [1.0] + $0 }
        let p = width + 1
        var beta = Array(repeating: 0.0, count: p)
        var iterations = 0
        var converged = false
        for _ in 0..<maxIterations {
            iterations += 1
            var hessian = Array(repeating: Array(repeating: 0.0, count: p), count: p)
            var gradient = Array(repeating: 0.0, count: p)
            for (row, label) in zip(design, y) {
                let eta = zip(row, beta).reduce(0.0) { $0 + $1.0 * $1.1 }
                let mu = 1 / (1 + exp(-eta))
                let w = max(mu * (1 - mu), 1e-9)
                let residual = (label ? 1.0 : 0.0) - mu
                for i in 0..<p {
                    gradient[i] += row[i] * residual
                    for j in 0..<p { hessian[i][j] += row[i] * row[j] * w }
                }
            }
            guard let step = solve(hessian, gradient) else {
                return iterations == 1 ? nil : LogisticFit(coefficients: beta, iterations: iterations,
                                                           converged: false, separated: true, n: y.count)
            }
            for i in 0..<p { beta[i] += step[i] }
            if step.allSatisfy({ abs($0) < tolerance }) {
                converged = true
                break
            }
        }
        // Perfect separation drives the MLE to infinity; the run stops at
        // the cap with coefficients that only say "this splits cleanly".
        let separated = !converged || beta.contains { abs($0) > 25 }
        return LogisticFit(coefficients: beta, iterations: iterations, converged: converged,
                           separated: separated, n: y.count)
    }

    /// Gaussian elimination with partial pivoting; nil when singular.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a.enumerated().map { $0.element + [b[$0.offset]] }
        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<n where abs(m[row][column]) > abs(m[pivot][column]) { pivot = row }
            guard abs(m[pivot][column]) > 1e-12 else { return nil }
            m.swapAt(column, pivot)
            for row in 0..<n where row != column {
                let factor = m[row][column] / m[column][column]
                guard factor != 0 else { continue }
                for k in column...n { m[row][k] -= factor * m[column][k] }
            }
        }
        return (0..<n).map { m[$0][n] / m[$0][$0] }
    }
}
