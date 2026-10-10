// gesture-probe.swift — play a modifier-key gesture at the running app and let
// its own log say what it made of it.
//
// The dictation gesture is a timing gesture: a tap arms, a second press inside
// the window latches. Testing it by hand measures the tester's hand, not the
// rules — so this posts the key events with exact durations and gaps, and the
// app's `hotkey` log lines report the timings it actually observed.
//
//   swiftc -O scripts/gesture-probe.swift -o /tmp/gesture-probe
//   /tmp/gesture-probe double 300 220     # two presses: 300ms held, 220ms gap
//   /tmp/gesture-probe hold 1500          # one 1500ms hold
//   /tmp/gesture-probe esc                # cancel whatever is running
//
// Needs Accessibility for the posting process (it synthesizes input). Right ⌥
// is keycode 61; the flag it sets while down is NX_DEVICERALTKEYMASK (0x40).
import CoreGraphics
import Foundation

let rightOption: CGKeyCode = 61
let downFlags = CGEventFlags(rawValue: 0x8_0040)   // maskAlternate | device-right ⌥
let upFlags = CGEventFlags(rawValue: 0)
let src = CGEventSource(stateID: .hidSystemState)

func post(pressed: Bool) {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: rightOption, keyDown: pressed)
    else { fputs("could not create event\n", stderr); exit(1) }
    e.type = .flagsChanged
    e.flags = pressed ? downFlags : upFlags
    e.post(tap: .cghidEventTap)
}

func postKey(_ code: CGKeyCode) {
    for pressed in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: pressed)
        else { return }
        e.flags = []
        e.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

func ms(_ v: Double) { usleep(useconds_t(v * 1000)) }

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "double"
let a = args.count > 2 ? Double(args[2]) ?? 150 : 150
let b = args.count > 3 ? Double(args[3]) ?? 120 : 120

switch mode {
case "double":
    // Tap (a ms), gap (b ms), second press — held briefly, as a hand would.
    post(pressed: true);  ms(a)
    post(pressed: false); ms(b)
    post(pressed: true);  ms(120)
    post(pressed: false)
    print("posted: double-tap — first press \(Int(a))ms, gap \(Int(b))ms")
case "hold":
    post(pressed: true);  ms(a)
    post(pressed: false)
    print("posted: hold \(Int(a))ms")
case "press":
    post(pressed: true);  ms(a)
    post(pressed: false)
    print("posted: single press \(Int(a))ms")
case "esc":
    postKey(53)
    print("posted: esc")
default:
    fputs("usage: gesture-probe double|hold|press|esc [ms] [gap-ms]\n", stderr)
    exit(2)
}
