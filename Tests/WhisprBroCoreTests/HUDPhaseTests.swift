import XCTest

@testable import WhisprBroCore

/// Pins which HUD phases are LIVE (the mic is open, the mark ripples, the
/// waveform runs) — the rule behind the idle-CPU leak.
///
/// The leak: the HUD panel is created once and only ordered out, so whatever
/// phase it held when `hide()` ran kept rendering at display rate behind the
/// scenes. `cancelRecording()` and the floor guard hide straight from
/// `.recording`, and the model's default phase was `.recording` too. A hidden
/// panel must rest on a phase that is not live; everything below exists so that
/// stays true.
final class HUDPhaseTests: XCTestCase {

    /// The ONLY source of truth for the table below. No `default:` — adding a
    /// `HUDPhase` case fails to compile here until someone decides, on purpose,
    /// whether it is live.
    private func expectedLive(_ phase: HUDPhase) -> Bool {
        switch phase {
        case .recording, .locked: true
        case .transcribing, .inserting, .refused, .warning, .idle: false
        }
    }

    private let samples: [HUDPhase] = [
        .recording,
        .locked(hint: "Right ⌥ to finish"),
        .locked(hint: ""),
        .transcribing,
        .inserting,
        .refused("Canceled"),
        .refused(""),
        .warning("Hotkey stopped — check Input Monitoring"),
        .idle,
    ]

    func testOnlyAnOpenMicIsLive() {
        for phase in samples {
            XCTAssertEqual(phase.isLive, expectedLive(phase), "\(phase)")
        }
        XCTAssertTrue(HUDPhase.recording.isLive)
        XCTAssertTrue(HUDPhase.locked(hint: "Esc to cancel").isLive,
                      "a latched mic is still a live mic — the ripple must not drop out at the latch")
    }

    /// The fix's invariant: the phase a hidden panel is left holding is not live.
    func testTheRestingPhaseIsNotLive() {
        XCTAssertFalse(HUDPhase.idle.isLive)
        XCTAssertNotEqual(HUDPhase.idle, .recording)
    }

    /// Toasts (refused / warning) linger on screen after the mic has closed;
    /// none of them may keep the pebble in its live layout.
    func testToastsAndPipelineStagesAreNotLive() {
        XCTAssertFalse(HUDPhase.transcribing.isLive)
        XCTAssertFalse(HUDPhase.inserting.isLive)
        XCTAssertFalse(HUDPhase.refused("Canceled").isLive)
        XCTAssertFalse(HUDPhase.warning("Hands-free capped — copied, ⌘V to paste").isLive)
    }

    /// The hands-free hint is part of the phase's identity (the HUD repaints
    /// when a rebind changes it), but never its liveness.
    func testLockedHintChangesIdentityNotLiveness() {
        let a = HUDPhase.locked(hint: "Right ⌥ to finish")
        let b = HUDPhase.locked(hint: "Esc to cancel")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.isLive, b.isLive)
    }
}
