import XCTest
import os.log
@testable import WhisprBroCore

// The FoundationModelsFormatter pieces that are testable WITHOUT the
// Foundation Models daemon: the transcript-marker scaffolding (pure string
// work) and the deadline race, which takes an injected request closure —
// so a fast, a throwing, and a wedged request can be raced deterministically.
// The daemon-dependent paths (availability, prewarm, respond) stay covered by
// `whispr-bench eval` (docs/llm-measurement-gate.md).
#if canImport(FoundationModels)
final class FoundationModelsFormatterTests: XCTestCase {
    private let log = Logger(subsystem: "com.micaxes.whispr-bro", category: "fm-tests")

    // MARK: - Transcript markers

    func testStripMarkersRemovesWrapper() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("needs OS 26") }
        XCTAssertEqual(
            FoundationModelsFormatter.stripTranscriptMarkers(
                "<transcript>\nHello world.\n</transcript>"),
            "Hello world.")
    }

    func testStripMarkersTrimsBeforeMatching() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("needs OS 26") }
        // Surrounding whitespace must not defeat the prefix/suffix match.
        XCTAssertEqual(
            FoundationModelsFormatter.stripTranscriptMarkers(
                "  <transcript>Hi there.</transcript>\n"),
            "Hi there.")
    }

    func testStripMarkersHandlesPartialEcho() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("needs OS 26") }
        // The model may echo only one marker; each side strips independently.
        XCTAssertEqual(
            FoundationModelsFormatter.stripTranscriptMarkers("<transcript>Hello."),
            "Hello.")
        XCTAssertEqual(
            FoundationModelsFormatter.stripTranscriptMarkers("Hello.</transcript>"),
            "Hello.")
    }

    func testStripMarkersLeavesLegitContentUntouched() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("needs OS 26") }
        // Angle brackets and tags INSIDE the text are user content, not
        // scaffolding — a dictation may legitimately mention them.
        let math = "Set a < b and b > c."
        XCTAssertEqual(FoundationModelsFormatter.stripTranscriptMarkers(math), math)
        let html = "Use <b>bold</b> tags here."
        XCTAssertEqual(FoundationModelsFormatter.stripTranscriptMarkers(html), html)
        // Even the marker itself, mid-sentence, is content (no prefix match).
        let midText = "The <transcript> tag appears mid-sentence."
        XCTAssertEqual(FoundationModelsFormatter.stripTranscriptMarkers(midText), midText)
    }

    func testStripMarkersNoMarkersUnchanged() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("needs OS 26") }
        let clean = "The quarterly report shows revenue grew twelve percent."
        XCTAssertEqual(FoundationModelsFormatter.stripTranscriptMarkers(clean), clean)
    }

    func testWrapStripRoundTrip() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("needs OS 26") }
        // Whatever wrapTranscript adds, stripTranscriptMarkers removes — the
        // prompt scaffolding must never leak into validated output.
        for transcript in [
            "hello world",
            "line one.\nline two.",
            "compare a < b and use <b>bold</b> tags",
        ] {
            XCTAssertEqual(
                FoundationModelsFormatter.stripTranscriptMarkers(
                    FoundationModelsFormatter.wrapTranscript(transcript)),
                transcript)
        }
    }

    // MARK: - Deadline race (injected closures — no daemon)

    func testRaceFastRequestWins() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("needs OS 26") }
        let outcome = await FoundationModelsFormatter.race(
            deadline: .seconds(5), log: log) { "ok" }
        guard case .responded(let text) = outcome else {
            return XCTFail("expected .responded, got \(outcome)")
        }
        XCTAssertEqual(text, "ok")
    }

    func testRaceThrowingRequestReportsRequestFailed() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("needs OS 26") }
        struct Boom: Error {}
        let outcome = await FoundationModelsFormatter.race(
            deadline: .seconds(5), log: log) { throw Boom() }
        // A thrown request and a timeout must stay distinguishable.
        guard case .failed(.requestFailed) = outcome else {
            return XCTFail("expected .failed(.requestFailed), got \(outcome)")
        }
    }

    func testRaceDeadlineUnblocksWedgedRequest() async throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("needs OS 26") }
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await FoundationModelsFormatter.race(
            deadline: .milliseconds(100), log: log) {
                // Ignores cooperative cancellation, like the wedged daemon.
                try? await Task.sleep(for: .milliseconds(600))
                return "late"
            }
        let elapsed = clock.now - start
        guard case .failed(.timedOut) = outcome else {
            return XCTFail("expected .failed(.timedOut), got \(outcome)")
        }
        // The caller unblocked at the deadline, not when the request gave up.
        XCTAssertLessThan(elapsed, .milliseconds(500))
        // Let the orphan finish and resume late: the one-shot guard must drop
        // it — a double resume of the checked continuation would crash here.
        try await Task.sleep(for: .milliseconds(700))
    }
}
#endif
