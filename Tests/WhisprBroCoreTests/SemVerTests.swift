import XCTest
@testable import WhisprBroCore

final class SemVerTests: XCTestCase {
    func testParsesPlainAndPrefixed() {
        XCTAssertEqual(SemVer("1.2.3").map(\.description), "1.2.3")
        XCTAssertEqual(SemVer("v1.2.3").map(\.description), "1.2.3")
        XCTAssertEqual(SemVer("V0.1.0").map(\.description), "0.1.0")
        XCTAssertEqual(SemVer("  v2.0.1  ").map(\.description), "2.0.1")
    }

    func testMissingComponentsDefaultToZero() {
        XCTAssertEqual(SemVer("1").map(\.description), "1.0.0")
        XCTAssertEqual(SemVer("v1.4").map(\.description), "1.4.0")
    }

    func testIgnoresPreReleaseAndBuildMetadata() {
        XCTAssertEqual(SemVer("0.2.0-beta.1"), SemVer("0.2.0"))
        XCTAssertEqual(SemVer("1.0.0+build.7"), SemVer("1.0.0"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(SemVer("latest"))
        XCTAssertNil(SemVer(""))
        XCTAssertNil(SemVer("v"))
        XCTAssertNil(SemVer("1.x.0"))
    }

    func testOrdering() {
        XCTAssertTrue(SemVer("0.2.0")! > SemVer("0.1.0")!)
        XCTAssertTrue(SemVer("1.0.0")! > SemVer("0.9.9")!)
        XCTAssertTrue(SemVer("0.1.1")! > SemVer("0.1.0")!)
        XCTAssertFalse(SemVer("0.1.0")! > SemVer("0.1.0")!)
        XCTAssertFalse(SemVer("v0.1.0")! > SemVer("0.2.0")!)
    }
}
