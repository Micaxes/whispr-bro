import XCTest

@testable import WhisprBroCore

/// The one test that can actually catch the bug coming back.
///
/// `DictationGesture` has no silence input by construction, so its tests prove
/// the RULES never end a dictation on a pause — but the bug lived in the
/// EFFECT: a 0.15s timer in `PipelineController` that fed samples to
/// `VadGate.feed` and called `finishRecording` on end-of-speech. That file is
/// in an `executableTarget` and no unit test can reach it.
///
/// So this reads the source. Crude, and deliberately so: it fails the moment
/// anything re-couples the voice-activity detector to the end of a recording,
/// which is the only regression that matters here.
final class NoSilenceEndingTests: XCTestCase {

    /// Repo root, walked up from this file (Tests/WhisprBroCoreTests/…).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhisprBroCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func source(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("source not readable at \(url.path) — not a source checkout")
        }
        return text
    }

    /// The macOS pipeline may not ask the VAD when a dictation is over. `trim`
    /// is the one allowed use: it shortens finished audio, it never ends it.
    func testPipelineNeverAsksVadWhenSpeechEnded() throws {
        let pipeline = try source("Sources/WhisprBro/PipelineController.swift")
        let banned = ["vad.feed(", "beginStream(", "startVadAutoStop", "speechEnd", "vadTimer"]
        for token in banned {
            XCTAssertFalse(
                pipeline.contains(token),
                """
                PipelineController references `\(token)`. Silence must not end a \
                dictation — hands-free ends on his press, on Cancel, or on the cap. \
                See DictationGesture's contract.
                """)
        }
        // The only VAD calls left are loading the model and trimming a
        // finished utterance. Anything else is a new coupling to speech.
        let vadCalls = Set(
            pipeline
                .components(separatedBy: "vad.")
                .dropFirst()
                .map { String($0.prefix(while: { $0.isLetter })) })
        XCTAssertEqual(vadCalls, ["load", "trim"], "unexpected VadGate calls: \(vadCalls)")
    }

    /// The way out is printed by two views, so its wording is composed once in
    /// Core and rendered verbatim. A renderer that appends its own suffix gives
    /// him "Right ⌥ to finish to finish" — which shipped once, because the
    /// views live in an `executableTarget` no test can reach. This is the
    /// guard: the phrase exists in exactly one place.
    func testTheExitHintIsComposedInOnePlace() throws {
        XCTAssertEqual(
            DictationGesture.exitHint(dictateKeyLabel: "Right ⌥", cancelKeyLabel: "esc"),
            "Right ⌥ to finish")
        // No dictate key: fall back to Cancel, named as it is labelled.
        XCTAssertEqual(
            DictationGesture.exitHint(dictateKeyLabel: nil, cancelKeyLabel: "esc"),
            "esc to cancel")
        // Neither bound: never name a key that does nothing.
        XCTAssertEqual(
            DictationGesture.exitHint(dictateKeyLabel: nil, cancelKeyLabel: nil),
            "no shortcut bound — see Settings")

        // The composition itself is an interpolated (or concatenated) value with
        // the suffix stuck on. Prose that happens to end in "to finish" — the
        // menu's standing one-liner — is fine; a second assembly is not.
        let assemblies = [") to finish", "+ \" to finish", "appending(\" to finish"]
        for file in ["Sources/WhisprBro/HUD.swift",
                     "Sources/WhisprBro/MenuBarView.swift",
                     "Sources/WhisprBro/PipelineController.swift"] {
            let text = try source(file)   // hoisted: an XCTSkip thrown inside an
                                          // assert's autoclosure is recorded as a
                                          // FAILURE, not a skip.
            for assembly in assemblies {
                XCTAssertFalse(text.contains(assembly),
                               "\(file) composes the exit wording itself — render exitHint verbatim")
            }
        }
    }

    /// And the capability itself is gone from Core, so it can't be wired back
    /// in by a one-line call.
    func testVadGateExposesNoStreamingApi() throws {
        let vad = try source("Sources/WhisprBroCore/Audio/VadGate.swift")
        for token in ["func feed(", "beginStream", "processStreamingChunk", "VadStreamState"] {
            XCTAssertFalse(vad.contains(token), "VadGate re-exposes `\(token)` — streaming auto-stop is gone for good")
        }
        XCTAssertTrue(vad.contains("func trim("), "trim is the VAD's remaining job")
    }
}
