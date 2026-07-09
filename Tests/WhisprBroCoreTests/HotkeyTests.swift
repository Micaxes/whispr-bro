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

    func testDeviceSpecificMasks() {
        XCTAssertEqual(HotkeyBinding(keyCode: 61, gesture: .hold, isModifierOnly: true).deviceSpecificMask, 0x40)
        XCTAssertEqual(HotkeyBinding(keyCode: 54, gesture: .hold, isModifierOnly: true).deviceSpecificMask, 0x10)
        XCTAssertNil(HotkeyBinding(keyCode: 9, gesture: .tap, isModifierOnly: false).deviceSpecificMask)
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

    func testRebindReplacesOnlyThatAction() {
        var entries = HotkeyConfig.defaults.entries.filter { $0.action != .dictate }
        entries.append(.init(.dictate, HotkeyBinding(keyCode: 58, gesture: .hold, isModifierOnly: true))) // Left Option
        let cfg = HotkeyConfig(entries: entries)
        XCTAssertEqual(cfg.bindings(for: .dictate).first?.keyCode, 58)
        // Hands-free (a different action on the same physical key) is untouched.
        XCTAssertEqual(cfg.bindings(for: .handsFree).first?.keyCode, 61)
    }
}
