import XCTest
@testable import WhisprBroCore

/// `ModelResidency` — the one serial chain every load and unload of the
/// formatting model runs on — driven through a host whose load can be held
/// in flight, the way a real 1–2 s load is when the switch flips under it.
@MainActor
final class ModelResidencyTests: XCTestCase {
    /// The app's side: a model that loads when told, slowly when held.
    private final class Model: ModelResidencyHost {
        var rulesOnly = false
        var modelIsIdle = true
        var modelIsInstalled = true
        var modelIsAvailable = true
        private(set) var resident = false
        private(set) var calls: [String] = []
        private(set) var loading = false
        var failLoads = false
        /// While true a load waits for `finishLoad()`.
        var holdLoads = false
        private var held: CheckedContinuation<Void, Never>?

        struct Failed: Error {}

        func loadModel() async throws {
            calls.append("load")
            loading = true
            defer { loading = false }
            if holdLoads { await withCheckedContinuation { held = $0 } }
            if failLoads { throw Failed() }
            resident = true
        }

        func unloadModel() async {
            calls.append("unload")
            resident = false
        }

        func modelDidLoad(failure: Error?) { modelIsAvailable = failure == nil }
        func modelDidUnloadForRulesOnly() { calls.append("freed") }

        func finishLoad() {
            held?.resume()
            held = nil
        }
    }

    /// Launched with rules-only on: installed, available, not in memory.
    private func launchedInRulesOnly() -> (Model, ModelResidency) {
        let model = Model()
        model.rulesOnly = true
        let residency = ModelResidency(host: model, busyRetry: .milliseconds(5))
        residency.isUnloaded = true
        return (model, residency)
    }

    /// Launched with AI rewrite on: the model in memory.
    private func launchedWithTheModel() async -> (Model, ModelResidency) {
        let model = Model()
        let residency = ModelResidency(host: model, busyRetry: .milliseconds(5))
        residency.isUnloaded = true
        await residency.ensureLoaded()
        XCTAssertTrue(model.resident)
        return (model, residency)
    }

    private func flip(_ model: Model, _ residency: ModelResidency, to on: Bool) {
        model.rulesOnly = on
        residency.rulesOnlyChanged(to: on)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    // MARK: - The race

    func testTurnedBackOnDuringTheLoadTheModelIsFreed() async {
        // Off: the background load starts and takes its time.
        let (model, residency) = launchedInRulesOnly()
        model.holdLoads = true
        flip(model, residency, to: false)
        await waitUntil { model.loading }
        // On again while it loads: nothing is resident yet, and the unload
        // is queued anyway — behind the load.
        flip(model, residency, to: true)
        XCTAssertFalse(model.resident)
        model.finishLoad()
        await residency.drain()
        XCTAssertEqual(model.calls, ["load", "unload", "freed"])
        XCTAssertFalse(model.resident, "rules-only on: the ~1 GB is back")
        XCTAssertTrue(residency.isUnloaded, "and the next use knows to load it")
    }

    func testOffThenOnBeforeTheLoadRunsLoadsNothing() async {
        let (model, residency) = launchedInRulesOnly()
        flip(model, residency, to: false)
        flip(model, residency, to: true)
        await residency.drain()
        XCTAssertEqual(model.calls, [], "the load saw the switch back on and stood down")
        XCTAssertFalse(model.resident)
    }

    func testTheLastFlipWins() async {
        // Off, on, off during one load: the model ends up in memory, once.
        let (model, residency) = launchedInRulesOnly()
        model.holdLoads = true
        flip(model, residency, to: false)
        await waitUntil { model.loading }
        flip(model, residency, to: true)
        flip(model, residency, to: false)
        model.finishLoad()
        await residency.drain()
        XCTAssertEqual(model.calls, ["load"])
        XCTAssertTrue(model.resident)
        XCTAssertFalse(residency.isUnloaded)
        // And on again, settled: freed.
        flip(model, residency, to: true)
        await residency.drain()
        XCTAssertEqual(model.calls, ["load", "unload", "freed"])
        XCTAssertFalse(model.resident)
    }

    func testEveryFlipToOnQueuesTheUnload() {
        // The decision no longer looks at whether the model is resident yet.
        XCTAssertEqual(RulesOnlyMode.transition(toRulesOnly: true, modelInstalled: true), .unloadModel)
        XCTAssertEqual(RulesOnlyMode.transition(toRulesOnly: true, modelInstalled: false), .unloadModel)
        XCTAssertEqual(RulesOnlyMode.transition(toRulesOnly: false, modelInstalled: true), .loadModel)
        XCTAssertEqual(RulesOnlyMode.transition(toRulesOnly: false, modelInstalled: false), .none)
    }

    // MARK: - The unload

    func testTheUnloadWaitsForADictationThenFrees() async {
        let (model, residency) = await launchedWithTheModel()
        model.modelIsIdle = false          // a dictation is using it
        flip(model, residency, to: true)
        await residency.drain()
        XCTAssertTrue(model.resident, "never under a dictation")
        model.modelIsIdle = true           // it landed
        await waitUntil { !model.resident }
        XCTAssertEqual(model.calls, ["load", "unload", "freed"])
    }

    func testNothingToFreeIsNothingDone() async {
        let (model, residency) = launchedInRulesOnly()
        residency.unloadForRulesOnly()
        await residency.drain()
        XCTAssertEqual(model.calls, [])
        // Nor with rules-only off by the time it runs.
        let (other, otherResidency) = await launchedWithTheModel()
        otherResidency.unloadForRulesOnly()
        await otherResidency.drain()
        XCTAssertEqual(other.calls, ["load"])
        XCTAssertTrue(other.resident)
    }

    // MARK: - On demand

    func testEnsureLoadedLoadsOnlyAnInstalledModelThatIsOut() async {
        let (model, residency) = launchedInRulesOnly()
        await residency.ensureLoaded()     // Command Mode in rules-only
        await residency.ensureLoaded()
        XCTAssertEqual(model.calls, ["load"])
        XCTAssertTrue(model.resident)
        let missing = Model()
        missing.modelIsInstalled = false
        let none = ModelResidency(host: missing)
        none.isUnloaded = true
        await none.ensureLoaded()
        XCTAssertEqual(missing.calls, [])
    }

    func testAFailedLoadIsReportedAndTriedAgainNextTime() async {
        let (model, residency) = launchedInRulesOnly()
        model.failLoads = true
        await residency.ensureLoaded()
        XCTAssertFalse(model.modelIsAvailable)
        XCTAssertTrue(residency.isUnloaded)
        model.failLoads = false
        await residency.ensureLoaded()
        XCTAssertTrue(model.modelIsAvailable)
        XCTAssertEqual(model.calls, ["load", "load"])
    }

    // MARK: - The chain

    /// The order ops were asked in, kept by reference.
    private final class Order { var steps: [String] = [] }

    func testOpsRunInTheOrderAskedEvenAcrossALoad() async {
        let (model, residency) = launchedInRulesOnly()
        model.holdLoads = true
        let order = Order()
        residency.serial { order.steps.append("first") }
        // The flip queues its load at once — not from a Task, behind
        // whatever is asked meanwhile — so this op lands after it.
        flip(model, residency, to: false)
        residency.serial { order.steps.append("after the load") }
        await waitUntil { model.loading }
        XCTAssertEqual(order.steps, ["first"], "nothing overtakes the load in flight")
        model.finishLoad()
        await residency.drain()
        XCTAssertEqual(order.steps, ["first", "after the load"])
        XCTAssertTrue(model.resident)
    }

    func testNothingRunsAfterShutdown() async {
        let (model, residency) = launchedInRulesOnly()
        await residency.shutDown()
        await residency.ensureLoaded()
        flip(model, residency, to: false)
        await residency.drain()
        XCTAssertEqual(model.calls, [])
        XCTAssertTrue(residency.isShuttingDown)
    }
}
