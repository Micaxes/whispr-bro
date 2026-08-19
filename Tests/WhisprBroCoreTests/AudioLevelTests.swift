import XCTest

@testable import WhisprBroCore

/// Covers the perceptual (dB-normalized) display-level mapping the HUD
/// waveform and iOS level ring are driven by.
final class AudioLevelTests: XCTestCase {

    func testSilenceAndNoiseFloorGateToZero() {
        XCTAssertEqual(AudioLevel.perceptual(0), 0)
        // −60dB (below the −55dB floor) is room noise, not speech.
        XCTAssertEqual(AudioLevel.perceptual(0.001), 0)
    }

    func testConversationalSpeechFillsTheVisibleRange() {
        // −40dB (rms 0.01, quiet speech) must be clearly visible, not flat.
        let quiet = AudioLevel.perceptual(0.01)
        XCTAssertGreaterThan(quiet, 0.3)
        // −26dB (rms ~0.05, normal speech) lands in the upper half.
        let normal = AudioLevel.perceptual(0.05)
        XCTAssertGreaterThan(normal, 0.6)
        XCTAssertLessThan(normal, 1)
    }

    func testLoudSpeechSaturatesAtOne() {
        // −15dB ceiling (rms ~0.178) and anything louder pin at full scale.
        XCTAssertEqual(AudioLevel.perceptual(0.2), 1)
        XCTAssertEqual(AudioLevel.perceptual(1), 1)
    }

    func testMonotonicallyIncreasing() {
        let samples: [Float] = [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.15]
        let mapped = samples.map(AudioLevel.perceptual)
        XCTAssertEqual(mapped, mapped.sorted())
    }
}
