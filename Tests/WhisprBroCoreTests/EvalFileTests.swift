import XCTest
@testable import WhisprBroCore

/// The one writer every eval file goes through (§7 privacy): 0600 from the
/// first byte, no world-readable window, and the refusal of a path inside a
/// source checkout. The mode is the point — `Data.write(options: .atomic)`
/// and `FileManager.createFile(atPath:contents:)` both land 0644 under the
/// default umask, and these files hold his raw dictations verbatim.
final class EvalFileTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/dev/null")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("whispr-evalfile-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    func testWriteCreatesTheFileOwnerOnly() throws {
        let target = path("run.json")
        try EvalFile.write(Data("{}".utf8), to: target)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "{}")
        XCTAssertEqual(EvalFile.posixPermissions(of: target), 0o600)
        // The directory the writer had to create is owner-only too.
        XCTAssertEqual(EvalFile.posixPermissions(of: directory.path), 0o700)
    }

    /// The guarantee pinned where it is MADE, not after the fact: the final
    /// mode says nothing about the window the bytes travelled through.
    /// `createFile(atPath:contents:)` with a payload routes through
    /// `NSData`'s atomic write on Darwin — its own auxiliary file, 0644,
    /// holding the whole report until the mode is applied at the end — so
    /// the staging file must be created EMPTY at 0600 and written into.
    func testWriteNeverHandsBytesToAFileItDidNotCreateOwnerOnly() throws {
        let spy = CreateFileSpy()
        let target = path("run.md")
        let payload = Data(String(repeating: "one row of raw dictation, verbatim.\n", count: 4_000).utf8)
        try EvalFile.write(payload, to: target, fileManager: spy)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), payload)
        XCTAssertEqual(EvalFile.posixPermissions(of: target), 0o600)
        XCTAssertFalse(spy.calls.isEmpty, "the staging file is created through the file manager")
        for call in spy.calls {
            XCTAssertEqual(call.bytes ?? 0, 0, "bytes handed to createFile at \(call.path)")
            XCTAssertEqual(call.mode, EvalFile.mode, "mode at \(call.path)")
        }
    }

    /// What `EvalFile.write` asked the file system to create, and with
    /// what in it.
    private final class CreateFileSpy: FileManager {
        struct Call {
            let path: String
            let bytes: Int?
            let mode: Int?
        }

        var calls: [Call] = []

        override func createFile(atPath path: String, contents data: Data?,
                                 attributes attr: [FileAttributeKey: Any]?) -> Bool {
            calls.append(Call(path: path, bytes: data?.count,
                              mode: (attr?[.posixPermissions] as? NSNumber)?.intValue))
            return super.createFile(atPath: path, contents: data, attributes: attr)
        }
    }

    func testRewritingAnExistingFileKeepsItOwnerOnly() throws {
        let target = path("run.json")
        try EvalFile.write(Data("one".utf8), to: target)
        try EvalFile.write(Data("two".utf8), to: target)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "two")
        XCTAssertEqual(EvalFile.posixPermissions(of: target), 0o600)
        // The staging file is gone — a swap, not a leftover.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(siblings, ["run.json"])
    }

    /// A file that was 0644 before this helper existed (or that a hand-run
    /// `echo` created) is tightened before a byte is appended to it.
    func testRewritingA0644FileTightensIt() throws {
        let target = path("leaderboard.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: target, contents: Data("{\"old\":1}\n".utf8),
                                                     attributes: [.posixPermissions: 0o644]))
        XCTAssertEqual(EvalFile.posixPermissions(of: target), 0o644)
        try EvalFile.appendLine(Data("{\"new\":2}".utf8), to: target)
        XCTAssertEqual(EvalFile.posixPermissions(of: target), 0o600)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "{\"old\":1}\n{\"new\":2}\n")
    }

    func testAppendLineCreatesTheFileOwnerOnlyAndAppends() throws {
        let target = path("ratings.jsonl")
        try EvalFile.appendLine(Data("a".utf8), to: target)
        XCTAssertEqual(EvalFile.posixPermissions(of: target), 0o600)
        try EvalFile.appendLine(Data("b".utf8), to: target)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "a\nb\n")
        XCTAssertEqual(EvalFile.posixPermissions(of: target), 0o600)
    }

    func testWriteReportsThePathItCouldNotWrite() {
        // A path whose parent cannot be created (a file stands where the
        // directory would go).
        let blocker = path("blocked")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker, contents: Data()))
        XCTAssertThrowsError(try EvalFile.write(Data("x".utf8), to: blocker + "/run.json")) { error in
            XCTAssertTrue("\(error)".hasPrefix("could not write "), "\(error)")
        }
    }

    func testPosixPermissionsIsNilForAMissingFile() {
        XCTAssertNil(EvalFile.posixPermissions(of: path("nothing-here.json")))
    }

    /// Ratings, derived fixture files and calibration reports name (or
    /// carry) his dictations: refused inside a checkout, the same test
    /// `--append` and `history-export --out` apply.
    func testRefusesAPathInsideASourceCheckout() throws {
        let checkout = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent("runs"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: checkout.appendingPathComponent("Package.swift").path,
                                                     contents: Data()))
        XCTAssertTrue(EvalFile.refusesPrivatePath(checkout.appendingPathComponent("runs/ratings.jsonl").path))
        XCTAssertFalse(EvalFile.refusesPrivatePath(path("ratings.jsonl")))
    }

    func testEvalHomeReadsTheEnvironmentAndExpandsATilde() {
        XCTAssertNil(EvalFile.evalHome([:]))
        XCTAssertNil(EvalFile.evalHome(["WHISPR_EVAL_HOME": "   "]))
        XCTAssertEqual(EvalFile.evalHome(["WHISPR_EVAL_HOME": "/tmp/eval"]), "/tmp/eval")
        XCTAssertEqual(EvalFile.evalHome(["WHISPR_EVAL_HOME": "~/eval"]),
                       NSString(string: "~/eval").expandingTildeInPath)
    }
}
