import CoreGraphics
import XCTest

@testable import WhisprBroCore

/// Sequences of real key events through the modifier gesture rules — the layer
/// where both hands-free bugs lived and where nothing was covered before.
final class ModifierGestureTrackerTests: XCTestCase {

    private let rightOption: Int64 = 61
    private let rightCommand: Int64 = 54
    /// The NX device bit the tap reports while Right ⌥ is physically down.
    private let rOptFlags = UInt64(0x40)
    /// A quick, ordinary tap of a modifier key.
    private let tapHold: TimeInterval = 0.15
    /// A deliberate, unhurried tap — still nobody's dictation, and exactly what
    /// the old 0.22s ceiling threw away.
    private let slowTapHold: TimeInterval = 0.40
    /// A dictation.
    private let realHold: TimeInterval = 1.2

    private func tracker(_ config: HotkeyConfig = .defaults) -> ModifierGestureTracker {
        ModifierGestureTracker(config: config)
    }

    private func down(_ t: inout ModifierGestureTracker, _ key: Int64, at now: TimeInterval)
        -> [ModifierGestureTracker.Event] {
        t.flagsChanged(keyCode: key, pressed: true, flags: rOptFlags, now: now)
    }

    private func up(_ t: inout ModifierGestureTracker, _ key: Int64, at now: TimeInterval)
        -> [ModifierGestureTracker.Event] {
        t.flagsChanged(keyCode: key, pressed: false, flags: 0, now: now)
    }

    // MARK: Hold

    func testHoldBeginsAndEnds() {
        var t = tracker()
        XCTAssertEqual(down(&t, rightOption, at: 10), [.init(.dictate, .began)])
        XCTAssertEqual(t.heldActions, [.dictate])
        XCTAssertEqual(up(&t, rightOption, at: 10 + realHold), [.init(.dictate, .ended)])
        XCTAssertTrue(t.heldActions.isEmpty)
    }

    func testAutoRepeatIsIgnored() {
        var t = tracker()
        _ = down(&t, rightOption, at: 10)
        XCTAssertEqual(down(&t, rightOption, at: 10.1), [], "a repeat press must not re-begin")
        XCTAssertEqual(up(&t, rightOption, at: 11).count, 1)
        XCTAssertEqual(up(&t, rightOption, at: 11.1), [], "a second key-up must not re-end")
    }

    func testUnboundKeyIsIgnored() {
        var t = tracker()
        XCTAssertEqual(down(&t, 58, at: 10), [], "Left ⌥ is not bound by default")
        XCTAssertFalse(t.isBound(58))
        XCTAssertTrue(t.isBound(rightOption))
    }

    // MARK: The double-tap latch

    /// The whole gesture, and the ordering that makes it work: the hold's
    /// `.began` must reach the pipeline BEFORE the latch fires, or the latch
    /// sees an idle app and does nothing.
    func testDoubleTapLatchesAndTheHoldComesFirst() {
        var t = tracker()
        _ = down(&t, rightOption, at: 10)
        _ = up(&t, rightOption, at: 10 + tapHold)
        let second = down(&t, rightOption, at: 10 + tapHold + 0.12)
        XCTAssertEqual(second, [.init(.dictate, .began), .init(.handsFree, .fired)])
    }

    /// The bug as reported: the hands-free latch only took when the key was
    /// hammered. Every speed a hand actually produces must latch — not just
    /// the fast one.
    ///
    /// Each row is (first press held, gap before the second press). The last two
    /// rows both failed under the old 0.22s ceiling / 0.35s release-to-press
    /// window, which is why the gesture only took when he hammered the key.
    func testEveryNaturalDoubleTapSpeedLatches() {
        let speeds: [(hold: TimeInterval, gap: TimeInterval, label: String)] = [
            (0.06, 0.05, "hammered"),
            (0.12, 0.10, "brisk"),
            (0.18, 0.16, "ordinary"),
            (0.30, 0.22, "unhurried"),
            (0.40, 0.25, "deliberate"),
        ]
        for speed in speeds {
            var t = tracker()
            _ = down(&t, rightOption, at: 10)
            _ = up(&t, rightOption, at: 10 + speed.hold)
            let second = down(&t, rightOption, at: 10 + speed.hold + speed.gap)
            XCTAssertEqual(
                second, [.init(.dictate, .began), .init(.handsFree, .fired)],
                "a \(speed.label) double-tap must latch")
        }
    }

    /// The window is press-to-press, so how long he rests on the first tap is
    /// not also charged against the gap he has left for the second. Same rhythm
    /// (0.6s between presses), two very different first taps: both latch.
    func testTheWindowIsMeasuredPressToPressNotReleaseToPress() {
        for hold in [0.08, slowTapHold] as [TimeInterval] {
            var t = tracker()
            _ = down(&t, rightOption, at: 10)
            _ = up(&t, rightOption, at: 10 + hold)
            XCTAssertEqual(
                down(&t, rightOption, at: 10.6),
                [.init(.dictate, .began), .init(.handsFree, .fired)],
                "0.6s press-to-press is inside the window whatever the first tap cost")
        }
    }

    /// A window belongs to the press that uses it. A third press must start an
    /// ordinary hold, not re-latch off the tap two presses ago.
    func testAWindowIsSpentByThePressThatLatches() {
        var t = tracker()
        _ = down(&t, rightOption, at: 10)
        _ = up(&t, rightOption, at: 10 + tapHold)
        XCTAssertEqual(down(&t, rightOption, at: 10.3).count, 2, "the latch")
        _ = up(&t, rightOption, at: 10.35)   // released while latched — a tap, so it arms
        XCTAssertEqual(down(&t, rightOption, at: 10.5), [.init(.dictate, .began)],
                       "…but off ITS own tap, not the spent one")
    }

    /// A key-up with no key-down behind it (tap created mid-hold, or `clear()`
    /// ran in between): the duration is unknown, and unknown arms nothing.
    func testAReleaseWithNoRecordedPressArmsNothing() {
        var t = tracker()
        _ = down(&t, rightOption, at: 10)
        _ = t.clear()
        _ = up(&t, rightOption, at: 10.1)
        XCTAssertEqual(down(&t, rightOption, at: 10.2), [.init(.dictate, .began)])
    }

    /// The trace is what a "why didn't it take" report is read from, so it has
    /// to carry the numbers the decision was made on.
    func testTraceReportsWhatTheGestureMeasured() {
        var t = tracker()
        _ = down(&t, rightOption, at: 10)
        XCTAssertEqual(t.lastTrace?.pressed, true)
        XCTAssertNil(t.lastTrace?.sincePreviousPress, "nothing precedes the first press")
        XCTAssertEqual(t.lastTrace?.armed, false)

        _ = up(&t, rightOption, at: 10 + slowTapHold)
        XCTAssertEqual(t.lastTrace?.pressed, false)
        XCTAssertEqual(t.lastTrace?.heldFor ?? 0, slowTapHold, accuracy: 0.001)
        XCTAssertEqual(t.lastTrace?.armed, true, "a 400ms tap is a tap")

        _ = down(&t, rightOption, at: 10.6)
        XCTAssertEqual(t.lastTrace?.sincePreviousPress ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(t.lastTrace?.latched, true)

        // And a hold reports itself as one.
        _ = up(&t, rightOption, at: 12)
        XCTAssertEqual(t.lastTrace?.armed, false)
    }

    /// The HIGH bug: re-recording Dictate moves it to the end of the entries
    /// array. Delivery order must not follow it.
    func testLatchSurvivesARebindThatReordersEntries() {
        var entries = HotkeyConfig.defaults.entries.filter { $0.action != .dictate }
        entries.append(.init(.dictate, HotkeyBinding(keyCode: 61, gesture: .hold, isModifierOnly: true)))
        var t = tracker(HotkeyConfig(entries: entries))

        _ = down(&t, rightOption, at: 10)
        _ = up(&t, rightOption, at: 10 + tapHold)
        XCTAssertEqual(down(&t, rightOption, at: 10.3),
                       [.init(.dictate, .began), .init(.handsFree, .fired)],
                       "a rebind must not make hands-free unreachable")
    }

    /// And the same rebind through the real path: normalization carries
    /// hands-free onto the new key, so the gesture works on the key he chose
    /// and nothing is left firing on the old one.
    func testRebindingTheDictateKeyMovesTheLatchWithIt() {
        var entries = HotkeyConfig.defaults.entries.filter { $0.action != .dictate }
        entries.append(.init(.dictate, HotkeyBinding(keyCode: 58, gesture: .hold, isModifierOnly: true)))
        var t = tracker(HotkeyConfig(entries: entries).normalized())

        // The NEW key latches.
        _ = t.flagsChanged(keyCode: 58, pressed: true, flags: 0x20, now: 10)
        _ = t.flagsChanged(keyCode: 58, pressed: false, flags: 0, now: 10 + tapHold)
        XCTAssertEqual(t.flagsChanged(keyCode: 58, pressed: true, flags: 0x20, now: 10.3),
                       [.init(.dictate, .began), .init(.handsFree, .fired)])
        // The OLD key does nothing at all.
        XCTAssertFalse(t.isBound(rightOption))
    }

    func testASecondPressOutsideTheWindowIsJustAHold() {
        var t = tracker()
        _ = down(&t, rightOption, at: 10)
        _ = up(&t, rightOption, at: 10 + tapHold)
        XCTAssertEqual(down(&t, rightOption, at: 10.9), [.init(.dictate, .began)],
                       "0.9s press-to-press is outside the 0.70s window")
    }

    /// The MEDIUM bug: a real dictation's release used to arm the window, so a
    /// press moments later latched a mic he never asked for.
    func testARealHoldDoesNotArmTheLatch() {
        // Widening the window cannot make a dictation latch: only a press that
        // produced no dictation ever opens one.
        var t = tracker()
        _ = down(&t, rightOption, at: 10)
        _ = up(&t, rightOption, at: 10 + realHold)          // a dictation, not a tap
        XCTAssertEqual(down(&t, rightOption, at: 10 + realHold + 0.15),
                       [.init(.dictate, .began)],
                       "a press after a dictation must not latch hands-free")
    }

    /// And the residual: the hands-free STOP press is itself short, so without
    /// consuming it the next press would re-latch.
    func testAConsumedStopPressArmsNothing() {
        var t = tracker()
        // …latched, mic open. He presses to stop; the app consumes that press.
        _ = down(&t, rightOption, at: 20)
        t.suppressDoubleTap()
        _ = up(&t, rightOption, at: 20 + tapHold)
        XCTAssertEqual(down(&t, rightOption, at: 20.3), [.init(.dictate, .began)],
                       "stopping a session is not the first half of starting one")
    }

    func testSuppressAlsoClosesAWindowAlreadyOpen() {
        var t = tracker()
        _ = down(&t, rightOption, at: 10)
        _ = up(&t, rightOption, at: 10 + tapHold)   // window armed
        _ = down(&t, rightOption, at: 10.2)         // …which latches here
        t.suppressDoubleTap()                       // but the app consumed this press
        _ = up(&t, rightOption, at: 10.25)
        XCTAssertEqual(down(&t, rightOption, at: 10.4), [.init(.dictate, .began)])
    }

    // MARK: Reconcile

    func testClearReleasesHeldActionsAndDisarms() {
        var t = tracker()
        _ = down(&t, rightOption, at: 10)
        XCTAssertEqual(t.clear(), [.init(.dictate, .ended)])
        XCTAssertTrue(t.heldActions.isEmpty)
        // A lost key-up's duration is unknown — it must not have armed anything.
        XCTAssertEqual(down(&t, rightOption, at: 10.1), [.init(.dictate, .began)])
    }

    func testReloadReleasesThenRebinds() {
        var t = tracker()
        _ = down(&t, rightOption, at: 10)
        let released = t.reload(HotkeyConfig(entries: [
            .init(.dictate, HotkeyBinding(keyCode: 58, gesture: .hold, isModifierOnly: true)),
        ]))
        XCTAssertEqual(released, [.init(.dictate, .ended)])
        XCTAssertFalse(t.isBound(rightOption))
        XCTAssertTrue(t.isBound(58))
    }

    // MARK: Other keys

    func testCommandModeKeyIsIndependent() {
        var t = tracker()
        _ = down(&t, rightOption, at: 10)
        XCTAssertEqual(down(&t, rightCommand, at: 10.1), [.init(.commandMode, .began)])
        XCTAssertEqual(t.heldActions, [.dictate, .commandMode])
        XCTAssertEqual(up(&t, rightCommand, at: 11), [.init(.commandMode, .ended)])
        XCTAssertEqual(t.heldActions, [.dictate])
    }

    func testPressedMaskAndKeyBindingsAreNotTracked() {
        let t = tracker()
        XCTAssertEqual(t.pressedMask(for: rightOption), 0x40)
        XCTAssertEqual(t.pressedMask(for: rightCommand), 0x10)
        // Esc / ⌃⌘V are key bindings — the modifier tracker never sees them.
        XCTAssertFalse(t.isBound(53))
        XCTAssertFalse(t.isBound(9))
    }
}
