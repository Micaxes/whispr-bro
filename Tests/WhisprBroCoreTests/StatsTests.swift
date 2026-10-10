import XCTest
@testable import WhisprBroCore

/// Every statistic §7.4 reports, pinned against values worked out by hand
/// in the comments — and, just as important, against the degenerate cases
/// where the honest answer is "undefined": no data, one class, every label
/// the same, every value tied, a design that separates perfectly. A
/// calibration report that printed 0.0 for "undefined" would read as a
/// failed check instead of no check at all.
final class StatsTests: XCTestCase {
    // MARK: - Cohen's κ

    /// a = [0,0,1,1], b = [0,1,1,1] → Po = 3/4; margins a(2,2), b(1,3) →
    /// Pe = (2·1 + 2·3)/16 = 0.5 → κ = (0.75 − 0.5)/0.5 = 0.5.
    func testCohensKappaMatchesTheHandCount() {
        XCTAssertEqual(Stats.cohensKappa([0, 0, 1, 1], [0, 1, 1, 1], categories: 2)!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(Stats.agreement([0, 0, 1, 1], [0, 1, 1, 1])!, 0.75, accuracy: 1e-12)
    }

    func testCohensKappaIsPerfectAndZeroAtTheTwoPoles() {
        XCTAssertEqual(Stats.cohensKappa([0, 1, 0, 1], [0, 1, 0, 1], categories: 2)!, 1.0, accuracy: 1e-12)
        // Both raters split 2/2 and agree on none: Po = 0, Pe = 0.5 → −1.
        XCTAssertEqual(Stats.cohensKappa([0, 0, 1, 1], [1, 1, 0, 0], categories: 2)!, -1.0, accuracy: 1e-12)
    }

    func testCohensKappaIsUndefinedWhenNobodyVaried() {
        // Both said SHIP every time: perfect agreement, zero information.
        XCTAssertNil(Stats.cohensKappa([2, 2, 2], [2, 2, 2], categories: 3))
        XCTAssertNil(Stats.cohensKappa([], [], categories: 3))
        XCTAssertNil(Stats.cohensKappa([0, 1], [0], categories: 2))          // ragged
        XCTAssertNil(Stats.cohensKappa([0, 5], [0, 1], categories: 3))       // out of range
        XCTAssertNil(Stats.agreement([], []))
    }

    // MARK: - Weighted κ

    /// a = [0,1,2], b = [0,1,1] with quadratic weights w = 1 − (i−j)²/4:
    /// Po = (1 + 1 + 0.75)/3 = 0.9167; Pe = 0.75 → κ_w = 0.1667/0.25 = 2/3.
    func testQuadraticWeightedKappaMatchesTheHandCount() {
        XCTAssertEqual(Stats.weightedKappa([0, 1, 2], [0, 1, 1], categories: 3)!, 2.0 / 3, accuracy: 1e-12)
        // One level apart costs less than two: the same number of
        // disagreements, further away, scores lower.
        let near = Stats.weightedKappa([2, 2, 1, 0], [2, 1, 1, 0], categories: 3)!
        let far = Stats.weightedKappa([2, 2, 1, 0], [2, 0, 1, 0], categories: 3)!
        XCTAssertGreaterThan(near, far)
    }

    /// §7.4's own boundary, on 200 rows split 100 SHIP / 100 WRONG: the
    /// metric calling d of the SHIPs wrong costs 0.01 of κ each, so d = 40
    /// lands exactly on 0.60 and d = 41 on 0.59.
    func testWeightedKappaAtTheValidityBoundary() {
        func kappa(mislabelled d: Int) -> Double {
            let his = Array(repeating: 2, count: 100) + Array(repeating: 0, count: 100)
            let metric = Array(repeating: 2, count: 100 - d) + Array(repeating: 0, count: d)
                + Array(repeating: 0, count: 100)
            return Stats.weightedKappa(metric, his, categories: 3)!
        }
        XCTAssertEqual(kappa(mislabelled: 40), 0.60, accuracy: 1e-9)
        XCTAssertEqual(kappa(mislabelled: 41), 0.59, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(kappa(mislabelled: 40), Calibration.Thresholds.weightedKappa)
        XCTAssertLessThan(kappa(mislabelled: 41), Calibration.Thresholds.weightedKappa)
    }

    func testWeightedKappaIsUndefinedOnOneCategoryOrNoVariation() {
        XCTAssertNil(Stats.weightedKappa([0, 0], [0, 0], categories: 1))
        XCTAssertNil(Stats.weightedKappa([1, 1, 1], [1, 1, 1], categories: 3))
        XCTAssertNil(Stats.weightedKappa([], [], categories: 3))
    }

    // MARK: - Precision / recall

    func testRatesCountTheConfusionMatrix() {
        let r = Stats.rates(predicted: [true, true, false, false], actual: [true, false, true, false])
        XCTAssertEqual([r.truePositives, r.falsePositives, r.falseNegatives, r.trueNegatives], [1, 1, 1, 1])
        XCTAssertEqual(r.precision!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(r.recall!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(r.f1!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(r.n, 4)
    }

    func testPrecisionAndRecallAreUndefinedWithNothingToDivideBy() {
        // Nothing flagged: precision undefined (not 0 — it flagged nothing
        // wrong either).
        let none = Stats.rates(predicted: [false, false], actual: [true, false])
        XCTAssertNil(none.precision)
        XCTAssertEqual(none.recall!, 0.0, accuracy: 1e-12)
        // Nothing to find: recall undefined.
        let nothing = Stats.rates(predicted: [true, false], actual: [false, false])
        XCTAssertNil(nothing.recall)
        XCTAssertEqual(nothing.precision!, 0.0, accuracy: 1e-12)
        XCTAssertNil(Stats.rates(predicted: [], actual: []).f1)
    }

    // MARK: - AUROC

    /// scores [0.9, 0.8, 0.7, 0.6] with labels [+,−,+,−]: mid-ranks
    /// 4,3,2,1 → positive rank sum 6, U = 6 − 3 = 3, AUC = 3/4.
    func testAurocMatchesTheHandCount() {
        XCTAssertEqual(Stats.auroc(scores: [0.9, 0.8, 0.7, 0.6], labels: [true, false, true, false])!,
                       0.75, accuracy: 1e-12)
        XCTAssertEqual(Stats.auroc(scores: [1, 1, 0, 0], labels: [true, true, false, false])!,
                       1.0, accuracy: 1e-12)
        XCTAssertEqual(Stats.auroc(scores: [0, 0, 1, 1], labels: [true, true, false, false])!,
                       0.0, accuracy: 1e-12)
    }

    func testAurocIsExactlyOneHalfWhenEverythingTies() {
        XCTAssertEqual(Stats.auroc(scores: [1, 1, 1, 1], labels: [true, false, true, false])!,
                       0.5, accuracy: 1e-12)
    }

    func testAurocIsUndefinedWithOneClassOrNoRows() {
        XCTAssertNil(Stats.auroc(scores: [1, 2, 3], labels: [true, true, true]))
        XCTAssertNil(Stats.auroc(scores: [1, 2, 3], labels: [false, false, false]))
        XCTAssertNil(Stats.auroc(scores: [], labels: []))
        XCTAssertNil(Stats.auroc(scores: [1, 2], labels: [true]))
    }

    func testMidRanksAverageTies() {
        XCTAssertEqual(Stats.midRanks([10, 20, 20, 40]), [1, 2.5, 2.5, 4])
        XCTAssertEqual(Stats.midRanks([5, 5, 5]), [2, 2, 2])
    }

    // MARK: - Kendall τ_b

    /// x = 1,2,3,4 vs y = 1,2,4,3: five concordant pairs, one discordant,
    /// no ties → τ = 4/6 = 2/3.
    func testKendallTauMatchesTheHandCount() {
        XCTAssertEqual(Stats.kendallTauB([1, 2, 3, 4], [1, 2, 4, 3])!, 2.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(Stats.kendallTauB([1, 2, 3], [1, 2, 3])!, 1.0, accuracy: 1e-12)
        XCTAssertEqual(Stats.kendallTauB([1, 2, 3], [3, 2, 1])!, -1.0, accuracy: 1e-12)
    }

    /// x = [1,1,2], y = [1,2,3]: C = 2, D = 0, one tie group of two in x →
    /// τ_b = 2/√((3−1)(3−0)) = 2/√6 = 0.8165.
    func testKendallTauBCorrectsForTies() {
        XCTAssertEqual(Stats.kendallTauB([1, 1, 2], [1, 2, 3])!, 2 / 6.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(Stats.tieCorrection([1, 1, 2]), 1)
        XCTAssertEqual(Stats.tieCorrection([1, 1, 1]), 3)
    }

    func testKendallTauIsUndefinedWhenOneSideIsAllTiesOrTooShort() {
        XCTAssertNil(Stats.kendallTauB([1, 1, 1], [1, 2, 3]))
        XCTAssertNil(Stats.kendallTauB([1], [1]))
        XCTAssertNil(Stats.kendallTauB([], []))
    }

    // MARK: - Spearman ρ

    /// x = 1,2,3,4 vs y = 2,1,4,3: Σd² = 4 → ρ = 1 − 6·4/(4·15) = 0.6.
    func testSpearmanRhoMatchesTheHandCount() {
        XCTAssertEqual(Stats.spearmanRho([1, 2, 3, 4], [2, 1, 4, 3])!, 0.6, accuracy: 1e-12)
        XCTAssertEqual(Stats.spearmanRho([1, 2, 3], [10, 20, 30])!, 1.0, accuracy: 1e-12)
        // Monotone but not linear: ρ is 1 where Pearson would not be.
        XCTAssertEqual(Stats.spearmanRho([1, 2, 3], [1, 4, 900])!, 1.0, accuracy: 1e-12)
    }

    func testSpearmanRhoIsUndefinedOnAConstantColumn() {
        XCTAssertNil(Stats.spearmanRho([1, 1, 1], [1, 2, 3]))
        XCTAssertNil(Stats.spearmanRho([1, 2], [1]))
        XCTAssertNil(Stats.spearmanRho([1], [1]))
    }

    // MARK: - Logistic fit

    /// A predictor that carries no information: p(y) = 0.5 at x = 0 and at
    /// x = 1, so the MLE is intercept 0, slope 0.
    func testLogisticFitOnAnUninformativePredictor() throws {
        let fit = try XCTUnwrap(Stats.logisticFit([[0], [0], [1], [1]], [false, true, false, true]))
        XCTAssertTrue(fit.converged)
        XCTAssertEqual(fit.coefficients[0], 0, accuracy: 1e-6)
        XCTAssertEqual(fit.coefficients[1], 0, accuracy: 1e-6)
        XCTAssertFalse(fit.separated)
        XCTAssertEqual(fit.n, 4)
    }

    /// p(y=1 | x=0) = 1/3 and p(y=1 | x=1) = 2/3, so the MLE is the log
    /// odds themselves: intercept ln(1/2) = −0.6931, slope ln(4) = 1.3863.
    func testLogisticFitRecoversTheLogOdds() throws {
        let x = [[0.0], [0.0], [0.0], [1.0], [1.0], [1.0]]
        let y = [false, false, true, true, true, false]
        let fit = try XCTUnwrap(Stats.logisticFit(x, y))
        XCTAssertTrue(fit.converged)
        XCTAssertEqual(fit.coefficients[0], log(0.5), accuracy: 1e-6)
        XCTAssertEqual(fit.coefficients[1], log(4.0), accuracy: 1e-6)
        XCTAssertLessThanOrEqual(fit.iterations, 25)
    }

    /// Perfect separation: the MLE is at infinity. The fit stops at the
    /// cap and SAYS so rather than pretending to a weight.
    func testLogisticFitFlagsPerfectSeparation() throws {
        let fit = try XCTUnwrap(Stats.logisticFit([[0], [0], [1], [1]], [false, false, true, true],
                                                  maxIterations: 10))
        XCTAssertTrue(fit.separated)
        XCTAssertLessThanOrEqual(fit.iterations, 10)
        XCTAssertGreaterThan(fit.coefficients[1], 0)     // the direction is still right
    }

    func testLogisticFitIsUndefinedWithOneClassOrNoRows() {
        XCTAssertNil(Stats.logisticFit([[0], [1]], [true, true]))
        XCTAssertNil(Stats.logisticFit([[0], [1]], [false, false]))
        XCTAssertNil(Stats.logisticFit([], []))
        XCTAssertNil(Stats.logisticFit([[0, 1], [1]], [true, false]))       // ragged
    }

    func testSuggestedWeightsShareOutThePositiveSlopes() {
        let fit = Stats.LogisticFit(coefficients: [-1, 1, 1, 2], iterations: 3, converged: true,
                                    separated: false, n: 10)
        XCTAssertEqual(fit.suggestedWeights!, [0.25, 0.25, 0.5])
        let flat = Stats.LogisticFit(coefficients: [0, 0, 0, 0], iterations: 1, converged: true,
                                     separated: false, n: 10)
        XCTAssertNil(flat.suggestedWeights)
    }

    func testGaussianSolveAndItsSingularCase() {
        // 2x + y = 5 · x + 3y = 10 → x = 1, y = 3.
        let solution = Stats.solve([[2, 1], [1, 3]], [5, 10])!
        XCTAssertEqual(solution[0], 1, accuracy: 1e-12)
        XCTAssertEqual(solution[1], 3, accuracy: 1e-12)
        XCTAssertNil(Stats.solve([[1, 2], [2, 4]], [1, 2]))
    }
}
