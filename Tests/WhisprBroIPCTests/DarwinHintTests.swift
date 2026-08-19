import XCTest

@testable import WhisprBroIPC

/// Darwin hint post/observe round-trip. Names are unique per test run: the
/// Darwin center is machine-global, so a fixed name could be tripped by a
/// concurrent test process.
final class DarwinHintTests: XCTestCase {
    func testPostReachesObserver() {
        let name = "bro.whispr.test.hint.\(UUID().uuidString)"
        let delivered = expectation(description: "hint delivered")
        delivered.assertForOverFulfill = false // hints may coalesce, never multiply-count
        let token = DarwinHint.observe(name) { delivered.fulfill() }
        DarwinHint.post(name)
        wait(for: [delivered], timeout: 5)
        token.cancel()
    }

    func testCancelledObserverHearsNothing() {
        let name = "bro.whispr.test.hint.\(UUID().uuidString)"
        var count = 0
        let token = DarwinHint.observe(name) { count += 1 }
        token.cancel()
        DarwinHint.post(name)
        // Give an erroneous delivery a chance to arrive before asserting.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(count, 0)
    }

    func testContractHintNamesAreTheSpecifiedStrings() {
        // These three strings are cross-process ABI (a keyboard and an app of
        // different builds must agree) — pin them.
        XCTAssertEqual(KeyboardIPC.commandHintName, "bro.whispr.session.command")
        XCTAssertEqual(KeyboardIPC.statusHintName, "bro.whispr.session.status")
        XCTAssertEqual(KeyboardIPC.resultHintName, "bro.whispr.session.result")
    }
}
