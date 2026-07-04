import XCTest
@testable import WhisprBroCore

final class PreRollBufferTests: XCTestCase {
    func testIdleTrimKeepsOnlyMostRecentPreRoll() {
        let buffer = PreRollBuffer(preRollSampleCount: 100)
        buffer.append(Array(repeating: 1, count: 80))
        buffer.append(Array(repeating: 2, count: 80))

        buffer.beginUtterance()
        let utterance = buffer.endUtterance()

        XCTAssertEqual(utterance.count, 100)
        // Oldest 60 of the 1s were trimmed: 20 ones remain, then 80 twos.
        XCTAssertEqual(Array(utterance.prefix(20)), Array(repeating: 1, count: 20))
        XCTAssertEqual(Array(utterance.suffix(80)), Array(repeating: 2, count: 80))
    }

    func testUtteranceSplicesPreRollBeforeHeldAudio() {
        let buffer = PreRollBuffer(preRollSampleCount: 50)
        buffer.append(Array(repeating: 1, count: 50))

        buffer.beginUtterance()
        buffer.append(Array(repeating: 2, count: 200))
        let utterance = buffer.endUtterance()

        XCTAssertEqual(utterance.count, 250)
        XCTAssertEqual(Array(utterance.prefix(50)), Array(repeating: 1, count: 50))
        XCTAssertEqual(Array(utterance.suffix(200)), Array(repeating: 2, count: 200))
    }

    func testEndUtteranceResetsStateAndPreRollRefills() {
        let buffer = PreRollBuffer(preRollSampleCount: 10)
        buffer.append([1, 2, 3])
        buffer.beginUtterance()
        _ = buffer.endUtterance()

        // A fresh utterance with no appends in between is empty…
        buffer.beginUtterance()
        XCTAssertEqual(buffer.endUtterance().count, 0)

        // …and post-utterance audio refills the pre-roll for the next one.
        buffer.append([7, 8])
        buffer.beginUtterance()
        XCTAssertEqual(buffer.endUtterance(), [7, 8])
    }

    func testIsCapturingTransitions() {
        let buffer = PreRollBuffer(preRollSampleCount: 10)
        XCTAssertFalse(buffer.isCapturing)
        buffer.beginUtterance()
        XCTAssertTrue(buffer.isCapturing)
        _ = buffer.endUtterance()
        XCTAssertFalse(buffer.isCapturing)
    }

    func testAppendWhileCapturingDoesNotTrim() {
        let buffer = PreRollBuffer(preRollSampleCount: 10)
        buffer.beginUtterance()
        buffer.append(Array(repeating: 3, count: 500))
        XCTAssertEqual(buffer.endUtterance().count, 500)
    }

    // MARK: - drainNewSamples (streaming VAD tail)

    func testDrainReturnsOnlyNewSamplesSinceLastDrain() {
        let buffer = PreRollBuffer(preRollSampleCount: 4)
        buffer.append([9, 9]) // pre-roll
        buffer.beginUtterance()

        buffer.append([1, 2, 3])
        XCTAssertEqual(buffer.drainNewSamples(), [9, 9, 1, 2, 3]) // pre-roll + first tail
        XCTAssertEqual(buffer.drainNewSamples(), []) // nothing new

        buffer.append([4, 5])
        XCTAssertEqual(buffer.drainNewSamples(), [4, 5])
        XCTAssertEqual(buffer.endUtterance(), [9, 9, 1, 2, 3, 4, 5]) // full utterance intact
    }

    func testDrainIsEmptyWhenNotCapturing() {
        let buffer = PreRollBuffer(preRollSampleCount: 4)
        buffer.append([1, 2])
        XCTAssertEqual(buffer.drainNewSamples(), []) // idle: pre-roll is not drainable
    }

    func testDrainCursorResetsPerUtterance() {
        let buffer = PreRollBuffer(preRollSampleCount: 2)
        buffer.beginUtterance()
        buffer.append([1, 2, 3])
        _ = buffer.drainNewSamples()
        _ = buffer.endUtterance()

        buffer.beginUtterance()
        buffer.append([7, 8])
        XCTAssertEqual(buffer.drainNewSamples(), [7, 8]) // fresh cursor, not offset by prior utterance
    }
}
