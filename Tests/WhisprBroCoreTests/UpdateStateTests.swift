import XCTest
@testable import WhisprBroCore

final class UpdateStateTests: XCTestCase {
    private func state(_ tag: String) -> UpdateState {
        UpdateState(latestTag: tag, releaseURL: "https://github.com/Micaxes/whispr-bro/releases/tag/\(tag)", checkedAt: 1)
    }

    func testAvailableWhenLatestIsNewer() {
        let result = UpdateStatus.evaluate(current: "0.1.0", state: state("v0.2.0"))
        XCTAssertEqual(result, .available(tag: "v0.2.0", url: "https://github.com/Micaxes/whispr-bro/releases/tag/v0.2.0"))
    }

    func testUpToDateWhenEqualOrOlder() {
        XCTAssertEqual(UpdateStatus.evaluate(current: "0.2.0", state: state("v0.2.0")), .upToDate)
        XCTAssertEqual(UpdateStatus.evaluate(current: "0.2.0", state: state("v0.1.9")), .upToDate)
    }

    func testUnknownWithoutState() {
        XCTAssertEqual(UpdateStatus.evaluate(current: "0.1.0", state: nil), .unknown)
    }

    func testUnknownOnUnparseableTag() {
        XCTAssertEqual(UpdateStatus.evaluate(current: "0.1.0", state: state("nightly")), .unknown)
        XCTAssertEqual(UpdateStatus.evaluate(current: "garbage", state: state("v0.2.0")), .unknown)
    }

    func testLoadRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("update-state.json")

        let json = #"{"latestTag":"v0.3.0","releaseURL":"https://example/tag/v0.3.0","checkedAt":1783763746}"#
        try json.write(to: file, atomically: true, encoding: .utf8)

        let loaded = UpdateState.load(from: file)
        XCTAssertEqual(loaded?.latestTag, "v0.3.0")
        XCTAssertEqual(loaded?.releaseURL, "https://example/tag/v0.3.0")
        XCTAssertEqual(UpdateStatus.evaluate(current: "0.1.0", state: loaded),
                       .available(tag: "v0.3.0", url: "https://example/tag/v0.3.0"))
    }

    func testLoadReturnsNilOnMissingOrMalformed() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        XCTAssertNil(UpdateState.load(from: missing))

        let bad = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        try "not json".write(to: bad, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bad) }
        XCTAssertNil(UpdateState.load(from: bad))
    }
}
