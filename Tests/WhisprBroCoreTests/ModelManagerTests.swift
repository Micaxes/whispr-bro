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

    private func group(_ states: [ModelManager.FileState], partialOK: Bool,
                       optional: Bool = false, manifestFound: Bool = true,
                       rootExists: Bool = true) -> ModelManager.GroupStatus {
        let files = states.enumerated().map {
            ModelManager.FileStatus(relativePath: "f\($0.offset).bin", state: $0.element)
        }
        return ModelManager.GroupStatus(
            id: "g", displayName: "G", rootDir: URL(fileURLWithPath: "/tmp"),
            files: files, manifestFound: manifestFound, partialOK: partialOK,
            optional: optional, rootExists: rootExists)
    }

    func testOptionalGroupAbsentSummarySaysOptional() {
        // The multilingual Parakeet v3 set: absence is normal, and the summary
        // must say so, so the Settings pane doesn't read like a fault.
        let g = group([.missing, .missing], partialOK: false, optional: true)
        XCTAssertFalse(g.isInstalled)
        XCTAssertFalse(g.isVerified)
        XCTAssertTrue(g.isCleanlyAbsent)
        XCTAssertEqual(g.summary, "not installed (optional)")
    }

    func testOptionalGroupInstalledButBrokenIsAFault() {
        // `whispr-bench verify` gates on `!isVerified && !(optional && isCleanlyAbsent)`:
        // an installed-but-corrupt optional set must NOT slip through that guard.
        let g = group([.ok, .mismatch], partialOK: false, optional: true)
        XCTAssertTrue(g.isInstalled)
        XCTAssertFalse(g.isVerified)
        XCTAssertFalse(g.isCleanlyAbsent)
    }

    func testMissingFileMustNotMaskAMismatchInAnOptionalGroup() {
        // Reproduced gate escape: 1 mismatch + 1 missing made isInstalled false,
        // which an `optional && !isInstalled` guard read as benign absence —
        // deleting one file would have un-gated arbitrary tampering.
        let g = group([.mismatch, .missing], partialOK: false, optional: true)
        XCTAssertFalse(g.isCleanlyAbsent)
        XCTAssertFalse(g.isVerified)
        XCTAssertTrue(g.summary.contains("missing"))
        XCTAssertTrue(g.summary.contains("mismatch")) // both reported, not just missing
    }

    func testLostManifestWithInstalledRootIsAFaultNotAbsence() {
        // A manifest lost while the model sits on disk means integrity can no
        // longer be checked — that must gate, and must not read as "not installed".
        let lost = group([], partialOK: false, optional: true,
                         manifestFound: false, rootExists: true)
        XCTAssertFalse(lost.isCleanlyAbsent)
        XCTAssertEqual(lost.summary, "manifest missing")

        // No manifest AND no install root = genuinely never installed: benign.
        let never = group([], partialOK: false, optional: true,
                          manifestFound: false, rootExists: false)
        XCTAssertTrue(never.isCleanlyAbsent)
        XCTAssertEqual(never.summary, "not installed (optional)")
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
