import CoreGraphics
import XCTest

@testable import WhisprBroCore

/// Covers the hotkey model: default bindings, chord matching, display strings,
/// and JSON round-trip.
final class HotkeyTests: XCTestCase {

    private let cmd = CGEventFlags.maskCommand.rawValue
    private let ctrl = CGEventFlags.maskControl.rawValue
    private let opt = CGEventFlags.maskAlternate.rawValue
    private let shift = CGEventFlags.maskShift.rawValue

    // MARK: Defaults

    func testDefaultBindings() {
        let d = HotkeyConfig.defaults
        // Dictate = Right Option (61), hold, modifier-only.
        let dictate = d.bindings(for: .dictate).first
        XCTAssertEqual(dictate?.keyCode, 61)
        XCTAssertEqual(dictate?.gesture, .hold)
        XCTAssertTrue(dictate?.isModifierOnly == true)
        // Hands-free = double-tap Right Option.
        XCTAssertEqual(d.bindings(for: .handsFree).first?.gesture, .doubleTap)
        XCTAssertEqual(d.bindings(for: .handsFree).first?.keyCode, 61)
        // Command mode = Right Command (54), hold.
        XCTAssertEqual(d.bindings(for: .commandMode).first?.keyCode, 54)
        // Cancel = Esc (53), tap, no modifiers.
        let cancel = d.bindings(for: .cancel).first
        XCTAssertEqual(cancel?.keyCode, 53)
        XCTAssertEqual(cancel?.gesture, .tap)
        XCTAssertEqual(cancel?.modifiers, 0)
        XCTAssertFalse(cancel?.isModifierOnly == true)
        // Paste last = ⌃⌘V (keyCode 9, ctrl+cmd).
        let paste = d.bindings(for: .pasteLast).first
        XCTAssertEqual(paste?.keyCode, 9)
        XCTAssertEqual(paste?.modifiers, ctrl | cmd)
        // Every action has at least one binding.
        for action in HotkeyAction.allCases {
            XCTAssertFalse(d.bindings(for: action).isEmpty, "\(action) has a default")
        }
    }

    // MARK: Chord matching

    func testChordSatisfied() {
        let pasteV = HotkeyBinding(keyCode: 9, modifiers: ctrl | cmd, gesture: .tap, isModifierOnly: false)
        // Exactly ⌃⌘ present → matches.
        XCTAssertTrue(pasteV.chordSatisfied(by: ctrl | cmd))
        // Superset (⌃⌘⇧) → still matches.
        XCTAssertTrue(pasteV.chordSatisfied(by: ctrl | cmd | shift))
        // Plain ⌘V (system paste) → does NOT match (ctrl missing).
        XCTAssertFalse(pasteV.chordSatisfied(by: cmd))
        // No modifiers → no match.
        XCTAssertFalse(pasteV.chordSatisfied(by: 0))
    }

    func testCancelFiresEvenWithModifiersHeld() {
        // Esc has no required modifiers, so it must fire while the dictate key
        // (Option) is physically held — the cancel-while-dictating requirement.
        let esc = HotkeyBinding(keyCode: 53, modifiers: 0, gesture: .tap, isModifierOnly: false)
        XCTAssertTrue(esc.chordSatisfied(by: 0))
        XCTAssertTrue(esc.chordSatisfied(by: opt))
        XCTAssertTrue(esc.chordSatisfied(by: cmd | ctrl))
    }

    // MARK: Device masks & display

    func testPressedMasks() {
        XCTAssertEqual(HotkeyBinding(keyCode: 61, gesture: .hold, isModifierOnly: true).pressedMask, 0x40)
        XCTAssertEqual(HotkeyBinding(keyCode: 54, gesture: .hold, isModifierOnly: true).pressedMask, 0x10)
        XCTAssertNil(HotkeyBinding(keyCode: 9, gesture: .tap, isModifierOnly: false).pressedMask)
        // Every modifier the recorder can capture must have one, or that key
        // silently never registers a press. fn/Globe has no L/R instance, so
        // it reads the secondary-fn bit rather than a device bit.
        for kc in [61, 58, 62, 59, 54, 55, 60, 56, 63] as [Int64] {
            XCTAssertNotNil(HotkeyBinding(keyCode: kc, gesture: .hold, isModifierOnly: true).pressedMask,
                            "keycode \(kc) is recordable but has no pressed mask")
        }
        XCTAssertEqual(HotkeyBinding(keyCode: 63, gesture: .hold, isModifierOnly: true).pressedMask,
                       CGEventFlags.maskSecondaryFn.rawValue)
    }

    func testDisplayStrings() {
        XCTAssertEqual(HotkeyBinding(keyCode: 61, gesture: .hold, isModifierOnly: true).displayString, "Right ⌥")
        XCTAssertEqual(HotkeyBinding(keyCode: 54, gesture: .hold, isModifierOnly: true).displayString, "Right ⌘")
        let paste = HotkeyBinding(keyCode: 9, modifiers: ctrl | cmd, gesture: .tap, isModifierOnly: false)
        XCTAssertEqual(paste.displayString, "⌃⌘V")
        XCTAssertEqual(HotkeyBinding(keyCode: 53, gesture: .tap, isModifierOnly: false).displayString, "esc")
    }

    // MARK: Persistence

    func testConfigJSONRoundTrip() throws {
        let data = try JSONEncoder().encode(HotkeyConfig.defaults)
        let decoded = try JSONDecoder().decode(HotkeyConfig.self, from: data)
        XCTAssertEqual(decoded, HotkeyConfig.defaults)
    }

    func testRebindReplacesOnlyThatActionButCarriesHandsFree() {
        var entries = HotkeyConfig.defaults.entries.filter { $0.action != .dictate }
        entries.append(.init(.dictate, HotkeyBinding(keyCode: 58, gesture: .hold, isModifierOnly: true))) // Left Option
        let cfg = HotkeyConfig(entries: entries).normalized()
        XCTAssertEqual(cfg.bindings(for: .dictate).first?.keyCode, 58)
        // Command mode, Cancel, Paste, Copy are untouched.
        XCTAssertEqual(cfg.bindings(for: .commandMode).first?.keyCode, 54)
        XCTAssertEqual(cfg.bindings(for: .cancel).first?.keyCode, 53)
        // Hands-free FOLLOWS the dictate key — it is that key double-tapped.
        // Left behind on 61 it would exist on neither key: the new key never
        // latches, and the old key fires the latch against an idle pipeline.
        XCTAssertEqual(cfg.bindings(for: .handsFree).first?.keyCode, 58)
        XCTAssertEqual(cfg.bindings(for: .handsFree).first?.gesture, .doubleTap)
    }

    // MARK: Hands-free is the dictate key (normalization)

    func testNormalizeIsIdempotentAndLeavesDefaultsAlone() {
        XCTAssertEqual(HotkeyConfig.defaults.normalized(), HotkeyConfig.defaults)
        XCTAssertEqual(HotkeyConfig.defaults.normalized().normalized(), HotkeyConfig.defaults)
        XCTAssertEqual(HotkeyConfig(entries: []).normalized(), HotkeyConfig(entries: []))
    }

    func testNormalizeRepairsAStrandedHandsFreeBinding() {
        // The shape a pre-fix install is sitting in on disk: Dictate moved,
        // hands-free left on the old key.
        let stranded = HotkeyConfig(entries: [
            .init(.dictate, HotkeyBinding(keyCode: 62, gesture: .hold, isModifierOnly: true)),   // Right ⌃
            .init(.handsFree, HotkeyBinding(keyCode: 61, gesture: .doubleTap, isModifierOnly: true)),
        ])
        let fixed = stranded.normalized()
        XCTAssertEqual(fixed.bindings(for: .handsFree).first?.keyCode, 62)
        XCTAssertTrue(fixed.entriesInEmitOrder(keyCode: 61).isEmpty, "nothing is left on the old key")
        XCTAssertEqual(fixed.entriesInEmitOrder(keyCode: 62).map(\.action), [.dictate, .handsFree])
    }

    /// The two-click path that used to destroy the gesture: remove the Dictate
    /// shortcut (which correctly drops the latch), then set a new one. The
    /// latch has to come BACK — rewriting an existing entry isn't enough, it
    /// must be created.
    func testNormalizeRecreatesHandsFreeAfterDictateIsRemovedAndReset() {
        let removed = HotkeyConfig(entries: HotkeyConfig.defaults.entries
            .filter { $0.action != .dictate }).normalized()
        XCTAssertTrue(removed.bindings(for: .handsFree).isEmpty)

        var entries = removed.entries
        entries.append(.init(.dictate, HotkeyBinding(keyCode: 58, gesture: .hold, isModifierOnly: true)))
        let reset = HotkeyConfig(entries: entries).normalized()
        XCTAssertEqual(reset.bindings(for: .handsFree).first?.keyCode, 58)
        XCTAssertEqual(reset.entriesInEmitOrder(keyCode: 58).map(\.action), [.dictate, .handsFree])
    }

    /// A config saved by an older build that had its own Hands-free row and an
    /// X button on it: the latch comes back, because it is part of the dictate
    /// gesture rather than a shortcut of its own.
    func testNormalizeRestoresAHandsFreeEntryThatWasNeverThere() {
        let legacy = HotkeyConfig(entries: HotkeyConfig.defaults.entries
            .filter { $0.action != .handsFree })
        let fixed = legacy.normalized()
        XCTAssertEqual(fixed.bindings(for: .handsFree).first?.keyCode, 61)
        XCTAssertEqual(fixed.bindings(for: .handsFree).first?.gesture, .doubleTap)
    }

    /// A double-tap can only be matched on `flagsChanged`, so a dictate key
    /// that isn't modifier-only carries no latch — and the config says so
    /// rather than storing one that `handleKeyDown` would silently drop.
    func testNoLatchOnANonModifierDictateKey() {
        let keyDictate = HotkeyConfig(entries: [
            .init(.dictate, HotkeyBinding(keyCode: 9, modifiers: ctrl | cmd, gesture: .hold, isModifierOnly: false)),
            .init(.handsFree, HotkeyBinding(keyCode: 61, gesture: .doubleTap, isModifierOnly: true)),
        ])
        XCTAssertTrue(keyDictate.normalized().bindings(for: .handsFree).isEmpty)
    }

    func testNormalizeDropsHandsFreeWithNoDictateKey() {
        // He deleted the Dictate shortcut: there is no key to double-tap, so
        // the latch must not linger pointing at nothing.
        let noDictate = HotkeyConfig(entries: HotkeyConfig.defaults.entries.filter { $0.action != .dictate })
        let fixed = noDictate.normalized()
        XCTAssertTrue(fixed.bindings(for: .handsFree).isEmpty)
        XCTAssertEqual(fixed.bindings(for: .commandMode).first?.keyCode, 54)
    }

    func testNormalizeCollapsesDuplicateHandsFreeEntries() {
        let doubled = HotkeyConfig(entries: HotkeyConfig.defaults.entries + [
            .init(.handsFree, HotkeyBinding(keyCode: 58, gesture: .doubleTap, isModifierOnly: true)),
        ])
        XCTAssertEqual(doubled.normalized().bindings(for: .handsFree).count, 1)
        XCTAssertEqual(doubled.normalized().bindings(for: .handsFree).first?.keyCode, 61)
    }

    // MARK: Emit order (the hands-free latch depends on it)

    /// `dictate` (hold) and `handsFree` (double-tap) share Right ⌥, and the
    /// latch acts on the recording the hold just started — so the hold MUST be
    /// delivered first, whatever order the entries happen to be in.
    func testHoldIsEmittedBeforeDoubleTapOnTheSameKey() {
        let ordered = HotkeyConfig.defaults.entriesInEmitOrder(keyCode: 61)
        XCTAssertEqual(ordered.map(\.action), [.dictate, .handsFree])

        // Re-recording the Dictate shortcut moves it to the END of the entry
        // list (HotkeyRecorder.update: filter + append). Entry order must not
        // decide delivery order, or hands-free becomes unreachable.
        var entries = HotkeyConfig.defaults.entries.filter { $0.action != .dictate }
        entries.append(.init(.dictate, HotkeyBinding(keyCode: 61, gesture: .hold, isModifierOnly: true)))
        let rebound = HotkeyConfig(entries: entries)
        XCTAssertEqual(rebound.entries.last?.action, .dictate, "precondition: the rebind moved it last")
        XCTAssertEqual(rebound.entriesInEmitOrder(keyCode: 61).map(\.action), [.dictate, .handsFree],
                       "a rebind must not reorder DELIVERY")
    }

    func testEmitOrderFiltersByKeyAndIsStable() {
        // Only that key's entries, and ties keep their entry order.
        let d = HotkeyConfig.defaults
        XCTAssertEqual(d.entriesInEmitOrder(keyCode: 54).map(\.action), [.commandMode])
        XCTAssertEqual(d.entriesInEmitOrder(keyCode: 53).map(\.action), [.cancel])
        XCTAssertTrue(d.entriesInEmitOrder(keyCode: 99).isEmpty)

        let two = HotkeyConfig(entries: [
            .init(.pasteLast, HotkeyBinding(keyCode: 9, modifiers: ctrl | cmd, gesture: .tap, isModifierOnly: false)),
            .init(.copyLast, HotkeyBinding(keyCode: 9, modifiers: ctrl | cmd, gesture: .tap, isModifierOnly: false)),
        ])
        XCTAssertEqual(two.entriesInEmitOrder(keyCode: 9).map(\.action), [.pasteLast, .copyLast])
    }

    func testGesturePriorities() {
        XCTAssertLessThan(HotkeyGesture.hold.emitPriority, HotkeyGesture.doubleTap.emitPriority)
        XCTAssertLessThan(HotkeyGesture.tap.emitPriority, HotkeyGesture.doubleTap.emitPriority)
    }

    // MARK: Load semantics (Settings delete support)

    /// The guarantee, through the real disk path: a stored config with the
    /// latch stranded on the old key repairs itself at launch, without him
    /// touching Settings — and a save can never write the broken shape back.
    func testLoadAndSaveRepairAStrandedConfig() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: HotkeyConfig.storageKey)
        defer {
            if let saved { defaults.set(saved, forKey: HotkeyConfig.storageKey) }
            else { defaults.removeObject(forKey: HotkeyConfig.storageKey) }
        }

        // Write the broken shape the way an older build would have.
        let stranded = HotkeyConfig(entries: [
            .init(.dictate, HotkeyBinding(keyCode: 58, gesture: .hold, isModifierOnly: true)),
            .init(.handsFree, HotkeyBinding(keyCode: 61, gesture: .doubleTap, isModifierOnly: true)),
            .init(.cancel, HotkeyBinding(keyCode: 53, gesture: .tap, isModifierOnly: false)),
        ])
        defaults.set(try JSONEncoder().encode(stranded), forKey: HotkeyConfig.storageKey)

        let loaded = HotkeyConfig.load()
        XCTAssertEqual(loaded.bindings(for: .handsFree).first?.keyCode, 58, "repaired on load")
        XCTAssertEqual(loaded.bindings(for: .cancel).first?.keyCode, 53, "other actions survive")

        // And a save normalizes on the way out, whatever it is handed.
        stranded.save()
        XCTAssertEqual(HotkeyConfig.load().bindings(for: .handsFree).first?.keyCode, 58)
        let onDisk = try JSONDecoder().decode(
            HotkeyConfig.self, from: defaults.data(forKey: HotkeyConfig.storageKey)!)
        XCTAssertEqual(onDisk.bindings(for: .handsFree).first?.keyCode, 58,
                       "the broken shape must not be what is persisted")
    }

    /// A deliberately emptied config (every shortcut deleted in Settings) must
    /// survive a relaunch — load() may only fall back to defaults on a missing
    /// or undecodable blob, never on a valid-but-empty one.
    func testLoadPreservesDeliberatelyEmptyConfig() throws {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: HotkeyConfig.storageKey)
        defer { // restore whatever the host had, even on assert failure
            if let saved { defaults.set(saved, forKey: HotkeyConfig.storageKey) }
            else { defaults.removeObject(forKey: HotkeyConfig.storageKey) }
        }

        HotkeyConfig(entries: []).save()
        XCTAssertTrue(HotkeyConfig.load().entries.isEmpty)

        defaults.set(Data("not json".utf8), forKey: HotkeyConfig.storageKey)
        XCTAssertEqual(HotkeyConfig.load(), .defaults)

        defaults.removeObject(forKey: HotkeyConfig.storageKey)
        XCTAssertEqual(HotkeyConfig.load(), .defaults)
    }
}
