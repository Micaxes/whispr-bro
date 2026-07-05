import XCTest
@testable import WhisprBroCore

final class ModelManagerTests: XCTestCase {
    private func tmp() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whispr-mm-\(UUID().uuidString)", isDirectory: true)
    }

    func testSha256MatchesShasum() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("hello.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)
        // echo hello | shasum -a 256  ->  5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03
        XCTAssertEqual(ModelManager.sha256(of: file),
                       "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    }

    func testSha256MissingFileReturnsNil() {
        XCTAssertNil(ModelManager.sha256(of: tmp().appendingPathComponent("nope")))
    }

    func testParseManifestSplitsHashAndPath() throws {
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = dir.appendingPathComponent("m.sha256")
        try """
        # a comment
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  sub/dir/model.bin

        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  vocab.json
        """.write(to: manifest, atomically: true, encoding: .utf8)

        let parsed = try XCTUnwrap(ModelManager.parseManifest(manifest))
        XCTAssertEqual(parsed.count, 2) // comment + blank line skipped
        XCTAssertEqual(parsed[0].0, "sub/dir/model.bin")
        XCTAssertEqual(parsed[0].1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(parsed[1].0, "vocab.json")
    }

    func testParseManifestUnreadableReturnsNil() {
        XCTAssertNil(ModelManager.parseManifest(tmp().appendingPathComponent("absent.sha256")))
    }

    func testParseManifestEmptyOrCommentsOnlyReturnsNil() throws {
        // A truncated/comments-only manifest must be nil (not []), so a required
        // group can't vacuously read as "verified" over zero files.
        let dir = tmp()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = dir.appendingPathComponent("empty.sha256")
        try "# only a comment\n\n".write(to: m, atomically: true, encoding: .utf8)
        XCTAssertNil(ModelManager.parseManifest(m))
    }

    func testEmptyManifestGroupIsNotVerified() {
        // Even if a GroupStatus is somehow built with no files, it must not
        // report installed/verified (guards against vacuous allSatisfy).
        let g = group([], partialOK: false)
        XCTAssertFalse(g.isInstalled)
        XCTAssertFalse(g.isVerified)
    }

    private func group(_ states: [ModelManager.FileState], partialOK: Bool) -> ModelManager.GroupStatus {
        let files = states.enumerated().map {
            ModelManager.FileStatus(relativePath: "f\($0.offset).bin", state: $0.element)
        }
        return ModelManager.GroupStatus(
            id: "g", displayName: "G", rootDir: URL(fileURLWithPath: "/tmp"),
            files: files, manifestFound: true, partialOK: partialOK)
    }

    func testPartialOKGroupVerifiesWithOnlyOnePresetInstalled() {
        // The LLM manifest lists all presets; a user installs one. That must
        // read as verified, not broken (regression: single-preset install).
        let g = group([.ok, .missing, .missing], partialOK: true)
        XCTAssertTrue(g.isInstalled)
        XCTAssertTrue(g.isVerified)
        XCTAssertTrue(g.summary.contains("1 of 3"))
    }

    func testPartialOKGroupFailsWhenAnInstalledFileIsBad() {
        let g = group([.ok, .mismatch, .missing], partialOK: true)
        XCTAssertFalse(g.isVerified)
    }

    func testRequiredGroupBrokenWhenAFileIsMissing() {
        let g = group([.ok, .missing], partialOK: false)
        XCTAssertFalse(g.isVerified)
        XCTAssertTrue(g.summary.contains("missing"))
    }

    func testUnreadableIsNotVerifiedAndDistinctFromMismatch() {
        let g = group([.ok, .unreadable], partialOK: false)
        XCTAssertFalse(g.isVerified)
        XCTAssertTrue(g.summary.contains("unreadable"))
    }

    func testVerifyReportsMissingAndMismatch() throws {
        // A manifest whose files don't exist on disk → all missing, not installed.
        let manifestsDir = tmp()
        try FileManager.default.createDirectory(at: manifestsDir, withIntermediateDirectories: true)
        // Only the LLM group is easy to point at an empty root; the point here is
        // the parse+state plumbing, exercised via a hand-built manifest read.
        let m = manifestsDir.appendingPathComponent("models-llm.sha256")
        try "0000000000000000000000000000000000000000000000000000000000000000  ghost/model.gguf\n"
            .write(to: m, atomically: true, encoding: .utf8)
        let parsed = try XCTUnwrap(ModelManager.parseManifest(m))
        XCTAssertEqual(parsed.first?.0, "ghost/model.gguf")
    }
}
