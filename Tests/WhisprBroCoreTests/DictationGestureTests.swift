import XCTest

@testable import WhisprBroCore

/// Covers the press/release/latch rules — the gesture layer the macOS app
/// routes every hotkey event through.
///
/// The headline invariant, and the reason this file exists: **a hands-free
/// session ends only on a press, a cancel, or the safety cap.** Nothing in
/// here may ever hand back a `finish` because the speaker went quiet.
final class DictationGestureTests: XCTestCase {

    private let longHold = DictationGesture.minHoldToTranscribe + 0.5
    private let tap = DictationGesture.minHoldToTranscribe - 0.01

    // MARK: Push-to-talk (hold)

    func testHoldStartsAndFinishes() {
        XCTAssertEqual(DictationGesture.press(phase: .idle, locked: false, isDictateKey: true), .start)
        XCTAssertEqual(
            DictationGesture.release(phase: .recording, locked: false, heldFor: longHold),
            .finish(trim: false),
            "a held dictation is exactly the held audio — nothing to trim")
    }

    func testSubThresholdHoldDiscards() {
        // The arming tap of a double-tap: its audio must never be transcribed.
        XCTAssertEqual(
            DictationGesture.release(phase: .recording, locked: false, heldFor: tap), .discard)
        // Exactly at the threshold counts as a real hold (>=, not >).
        XCTAssertEqual(
            DictationGesture.release(
                phase: .recording, locked: false, heldFor: DictationGesture.minHoldToTranscribe),
            .finish(trim: false))
    }

    func testPressWhileBusyRefuses() {
        XCTAssertEqual(DictationGesture.press(phase: .busy, locked: false, isDictateKey: true), .refuseBusy)
        XCTAssertEqual(DictationGesture.press(phase: .unavailable, locked: false, isDictateKey: true), .ignore)
    }

    func testPressWhileAlreadyHoldingIsIgnored() {
        // A second bound key pressed mid-hold must not start a second capture.
        XCTAssertEqual(DictationGesture.press(phase: .recording, locked: false, isDictateKey: true), .ignore)
    }

    // MARK: Hands-free (double-tap latch)

    func testDoubleTapLatchesOnlyWhileRecording() {
        XCTAssertEqual(DictationGesture.doubleTap(phase: .recording, locked: false), .latchHandsFree)
        // Already latched, or nothing to latch: no-op.
        XCTAssertEqual(DictationGesture.doubleTap(phase: .recording, locked: true), .ignore)
        XCTAssertEqual(DictationGesture.doubleTap(phase: .idle, locked: false), .ignore)
        XCTAssertEqual(DictationGesture.doubleTap(phase: .busy, locked: false), .ignore)
    }

    /// Command mode is a different key. Forming a ⌘ chord while a hands-free
    /// session is running must not end his dictation — only the dictate key
    /// toggles the latch off.
    func testOnlyTheDictateKeyStopsALatchedSession() {
        XCTAssertEqual(DictationGesture.press(phase: .recording, locked: true, isDictateKey: false), .ignore)
        XCTAssertEqual(DictationGesture.press(phase: .recording, locked: true, isDictateKey: true),
                       .finish(trim: true))
        // Idle/busy are unaffected by which key it was.
        XCTAssertEqual(DictationGesture.press(phase: .idle, locked: false, isDictateKey: false), .start)
        XCTAssertEqual(DictationGesture.press(phase: .busy, locked: true, isDictateKey: false), .refuseBusy)
    }

    /// The fix: the press that follows a latch is the STOP. It is the only
    /// gesture that ends a hands-free session.
    func testPressWhileLatchedFinishes() {
        XCTAssertEqual(
            DictationGesture.press(phase: .recording, locked: true, isDictateKey: true), .finish(trim: true),
            "a latched session can have silence at both ends — trim it")
    }

    /// The releases around a latched session are noise: the key-up of the
    /// arming tap, and the key-up of the stop press itself. Neither may end,
    /// discard, or double-finish the recording.
    func testReleasesNeverEndALatchedSession() {
        for held in [0, tap, longHold, 600] as [TimeInterval] {
            XCTAssertEqual(
                DictationGesture.release(phase: .recording, locked: true, heldFor: held), .ignore,
                "release must not touch a latched session (held \(held)s)")
        }
        // And after the stop press, while the transcript is landing.
        XCTAssertEqual(DictationGesture.release(phase: .busy, locked: true, heldFor: longHold), .ignore)
    }

    /// Exhaustive sweep of the whole input space: across every phase, both
    /// latch states and a spread of hold durations, a `finish` comes from
    /// exactly three places — a press while latched, the release of a real
    /// hold, and the cap. If a future change makes any other combination
    /// finish a recording, this fails.
    func testFinishComesFromExactlyThreeEvents() {
        let phases: [DictationGesture.Phase] = [.unavailable, .idle, .recording, .busy]
        let durations: [TimeInterval] = [0, 0.1, tap, DictationGesture.minHoldToTranscribe, longHold, 300]

        for phase in phases {
            for locked in [false, true] {
                // press
                let press = DictationGesture.press(phase: phase, locked: locked, isDictateKey: true)
                if case .finish = press {
                    XCTAssertEqual(phase, .recording); XCTAssertTrue(locked)
                    XCTAssertEqual(press, .finish(trim: true))
                }
                // doubleTap NEVER finishes anything, whatever the state.
                let dbl = DictationGesture.doubleTap(phase: phase, locked: locked)
                XCTAssertTrue(dbl == .ignore || dbl == .latchHandsFree, "doubleTap → \(dbl)")
                // cap
                let cap = DictationGesture.durationCap(phase: phase, locked: locked)
                if case .finish = cap {
                    XCTAssertEqual(phase, .recording)
                    XCTAssertEqual(cap, .finish(trim: locked))
                }
                // release
                for held in durations {
                    let rel = DictationGesture.release(phase: phase, locked: locked, heldFor: held)
                    if case .finish = rel {
                        XCTAssertEqual(phase, .recording)
                        XCTAssertFalse(locked, "a latched session must not finish on a release")
                        XCTAssertGreaterThanOrEqual(held, DictationGesture.minHoldToTranscribe)
                        XCTAssertEqual(rel, .finish(trim: false))
                    }
                }
            }
        }
    }

    /// The states the earlier suite left uncovered — each one a real sequence.
    func testStaleAndUnavailableStates() {
        // A cancel that left `isLocked` set, then a press: start a fresh
        // recording, never "stop" a recording that isn't running.
        XCTAssertEqual(DictationGesture.press(phase: .idle, locked: true, isDictateKey: true), .start)
        // A release with nothing recording (the stop press's key-up).
        XCTAssertEqual(DictationGesture.release(phase: .idle, locked: false, heldFor: longHold), .ignore)
        XCTAssertEqual(DictationGesture.release(phase: .idle, locked: true, heldFor: longHold), .ignore)
        XCTAssertEqual(DictationGesture.release(phase: .unavailable, locked: false, heldFor: longHold), .ignore)
        // A cap that fires while the app can't record at all.
        XCTAssertEqual(DictationGesture.durationCap(phase: .unavailable, locked: true), .ignore)
        XCTAssertEqual(DictationGesture.doubleTap(phase: .unavailable, locked: false), .ignore)
    }

    // MARK: Arming the double-tap window

    /// Only a TAP arms the latch. Without this, the release of an ordinary
    /// push-to-talk dictation arms the window, and a press 150ms later latches
    /// hands-free behind his back — an open mic he never asked for.
    func testOnlyATapArmsTheDoubleTap() {
        XCTAssertTrue(DictationGesture.armsDoubleTap(heldFor: 0))
        XCTAssertTrue(DictationGesture.armsDoubleTap(heldFor: tap))
        XCTAssertFalse(DictationGesture.armsDoubleTap(heldFor: DictationGesture.minHoldToTranscribe))
        XCTAssertFalse(DictationGesture.armsDoubleTap(heldFor: longHold))
        XCTAssertFalse(DictationGesture.armsDoubleTap(heldFor: 5))
        // The two rules are the same question asked twice: a release that
        // discards its audio is exactly a release that arms the window.
        for held in [0, 0.05, tap, DictationGesture.minHoldToTranscribe, longHold, 30] as [TimeInterval] {
            let discards = DictationGesture.release(
                phase: .recording, locked: false, heldFor: held) == .discard
            XCTAssertEqual(discards, DictationGesture.armsDoubleTap(heldFor: held), "at \(held)s")
        }
    }

    // MARK: Safety caps

    func testCapsAreOrderedAndBounded() {
        XCTAssertGreaterThan(DictationGesture.maxHandsFreeSeconds, DictationGesture.maxHoldSeconds,
                             "hands-free is the mode you're meant to talk in")
        XCTAssertEqual(DictationGesture.maxHoldSeconds, 90)
        // 300s = the iOS SessionController budget (~19MB of 16kHz Float32).
        // Raising it re-opens a memory decision this codebase already made.
        XCTAssertEqual(DictationGesture.maxHandsFreeSeconds, 300)
    }

    // MARK: Safety cap

    func testDurationCapFinishesWhateverTheMode() {
        XCTAssertEqual(DictationGesture.durationCap(phase: .recording, locked: false), .finish(trim: false))
        XCTAssertEqual(DictationGesture.durationCap(phase: .recording, locked: true), .finish(trim: true))
        // A cap that fires after the recording already ended is a no-op, never
        // a second finish (the repeating timer can outlive one dictation).
        XCTAssertEqual(DictationGesture.durationCap(phase: .idle, locked: false), .ignore)
        XCTAssertEqual(DictationGesture.durationCap(phase: .busy, locked: true), .ignore)
    }

    // MARK: Full sequences

    /// Double-tap → speak → pause → keep speaking → press. One dictation,
    /// ended by him, with the pause in the middle of it.
    func testHandsFreeRoundTrip() {
        var locked = false
        var phase = DictationGesture.Phase.idle

        // First tap: starts, then releases under the threshold (arming).
        XCTAssertEqual(DictationGesture.press(phase: phase, locked: locked, isDictateKey: true), .start)
        phase = .recording
        XCTAssertEqual(DictationGesture.release(phase: phase, locked: locked, heldFor: tap), .discard)
        phase = .idle

        // Second tap: starts again, and the double-tap latches it.
        XCTAssertEqual(DictationGesture.press(phase: phase, locked: locked, isDictateKey: true), .start)
        phase = .recording
        XCTAssertEqual(DictationGesture.doubleTap(phase: phase, locked: locked), .latchHandsFree)
        locked = true
        // Its key-up, and any long pause in the dictation, change nothing.
        XCTAssertEqual(DictationGesture.release(phase: phase, locked: locked, heldFor: tap), .ignore)

        // His press ends it.
        XCTAssertEqual(DictationGesture.press(phase: phase, locked: locked, isDictateKey: true), .finish(trim: true))
        phase = .busy
        locked = false
        XCTAssertEqual(DictationGesture.release(phase: phase, locked: locked, heldFor: 0.05), .ignore)
    }

    func testHoldRoundTrip() {
        XCTAssertEqual(DictationGesture.press(phase: .idle, locked: false, isDictateKey: true), .start)
        XCTAssertEqual(
            DictationGesture.release(phase: .recording, locked: false, heldFor: 2.0),
            .finish(trim: false))
        XCTAssertEqual(DictationGesture.press(phase: .busy, locked: false, isDictateKey: true), .refuseBusy)
    }
}
