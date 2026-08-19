import XCTest

@testable import WhisprBroIPC

/// The test-injectable container override — the hook every other suite here
/// implicitly relies on to run without App Group entitlements.
final class SharedContainerTests: XCTestCase {
    override func tearDown() {
        SharedContainer.directoryOverride = nil
    }

    func testOverrideWinsAndClears() {
        let injected = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispr-ipc-container-\(UUID().uuidString)")
        SharedContainer.directoryOverride = injected
        XCTAssertEqual(SharedContainer.url(), injected)

        SharedContainer.directoryOverride = nil
        // Without the override the result is entitlement-dependent (nil on an
        // unprovisioned host is the documented degraded state) — the contract
        // is only that it no longer returns the injected directory.
        XCTAssertNotEqual(SharedContainer.url(), injected)
    }
}
