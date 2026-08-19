import SwiftUI
import UIKit

/// The typing surface under the toolbar — the "full QWERTY is a later phase"
/// of issue #13 P4, now real: the standard iOS key layout as row-string data,
/// three layers (letters / numbers / symbols), shift with one-shot auto-reset
/// and double-tap caps lock, press-and-repeat delete, and the mandatory globe
/// key. Deliberately dumb beyond that: no autocorrect, no predictions, no
/// key-pop previews, no haptics — the appex stays a thin client under its
/// ~48MB jetsam cap, and `textDocumentProxy` insertion is the whole output.

/// One of the three standard layers. Character rows are plain strings — one
/// key per character — so the data reads like the keyboard it draws. The
/// bottom row (layer/globe/space/return) is function keys only and is built
/// separately by `KeyGrid`.
enum KeyLayer {
    case letters, numbers, symbols

    var rows: [[String]] {
        let strings: [String] = switch self {
        case .letters: ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        case .numbers: ["1234567890", "-/:;()$&@\"", ".,?!'"]
        case .symbols: ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"]
        }
        return strings.map { $0.map(String.init) }
    }
}

/// Shift, native semantics: off → tap → on (auto-resets after one letter) →
/// tap → off; double-tap → caps lock; any single tap leaves caps lock.
enum ShiftState {
    case off, on, capsLock

    var uppercased: Bool { self != .off }
}

/// The key grid: three character rows + the function bottom row, sized like
/// the system keyboard — ten columns set the unit key width, gaps stay
/// constant, rows share the grid's height equally (the controller's height
/// constraint, not intrinsic content, decides the total).
struct KeyGrid: View {
    @ObservedObject var session: KeyboardSession
    weak var controller: UIInputViewController?
    var insertCharacter: (String) -> Void
    var deleteBackward: () -> Void
    var insertNewline: () -> Void

    @State private var layer: KeyLayer = .letters
    @State private var shift: ShiftState = .off
    @State private var lastShiftTapAt = Date.distantPast

    private static let gap: CGFloat = 5
    private static let rowGap: CGFloat = 8
    private static let doubleTapWindow: TimeInterval = 0.3

    var body: some View {
        GeometryReader { geo in
            let unit = (geo.size.width - Self.gap * 9) / 10
            VStack(spacing: Self.rowGap) {
                charRow(layer.rows[0], width: unit)
                charRow(layer.rows[1], width: unit)
                thirdRow(unit: unit)
                bottomRow(unit: unit)
            }
        }
    }

    // MARK: Rows

    /// Rows 1–2: character keys only, centered (the 9-key asdf row floats
    /// between the same margins as the 10-key row above it, like the system).
    private func charRow(_ keys: [String], width: CGFloat) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(keys, id: \.self) { key in
                CharKey(cap: cap(for: key), width: width) { insert(key) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Row 3: [shift]…letters…[delete] on the letters layer; [#+= / 123]
    /// …punctuation…[delete] on the others. The punctuation keys are wider
    /// than a unit, as on the system keyboard.
    private func thirdRow(unit: CGFloat) -> some View {
        HStack(spacing: Self.gap) {
            if layer == .letters {
                ShiftKey(state: shift, width: unit * 1.4, tap: shiftTapped)
            } else {
                LayerKey(cap: layer == .numbers ? "#+=" : "123", width: unit * 1.4) {
                    layer = layer == .numbers ? .symbols : .numbers
                }
            }
            Spacer(minLength: 0)
            ForEach(layer.rows[2], id: \.self) { key in
                CharKey(
                    cap: cap(for: key),
                    width: layer == .letters ? unit : unit * 1.2
                ) { insert(key) }
            }
            Spacer(minLength: 0)
            DeleteKey(width: unit * 1.4, deleteBackward: deleteBackward)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Row 4: [123/ABC][globe][space][return]. The globe follows
    /// `needsInputModeSwitchKey`; when hidden, the layer key absorbs its
    /// slot so the space bar keeps its native proportions.
    private func bottomRow(unit: CGFloat) -> some View {
        let side = unit * 1.25
        return HStack(spacing: Self.gap) {
            LayerKey(
                cap: layer == .letters ? "123" : "ABC",
                width: session.needsInputModeSwitchKey ? side : side * 2 + Self.gap
            ) {
                layer = layer == .letters ? .numbers : .letters
                shift = .off
            }
            if session.needsInputModeSwitchKey {
                GlobeKey(controller: controller)
                    .frame(width: side)
                    .frame(maxHeight: .infinity)
                    .background(Palette.specialKeyFill, in: RoundedRectangle(cornerRadius: 6))
                    .keyShadow()
            }
            SpaceKey { insertCharacter(" ") }
            ReturnKey(width: unit * 2.5, insertNewline: insertNewline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Character handling

    /// Key caps follow the shift state (case-adaptive caps, like the system
    /// keyboard since iOS 9). Non-letter layers render as-is.
    private func cap(for key: String) -> String {
        layer == .letters && shift.uppercased ? key.uppercased() : key
    }

    private func insert(_ key: String) {
        insertCharacter(cap(for: key))
        if shift == .on, layer == .letters { shift = .off } // one-shot shift
    }

    private func shiftTapped() {
        let now = Date()
        defer { lastShiftTapAt = now }
        if now.timeIntervalSince(lastShiftTapAt) < Self.doubleTapWindow {
            shift = .capsLock
            return
        }
        shift = shift == .off ? .on : .off
    }
}

// MARK: - Character keys

private struct CharKey: View {
    let cap: String
    let width: CGFloat
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Text(cap)
                .font(.system(size: 22))
                .foregroundStyle(Palette.keyText)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background(Palette.keyFill, in: RoundedRectangle(cornerRadius: 6))
                .keyShadow()
        }
        .buttonStyle(.plain)
    }
}

private struct SpaceKey: View {
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Text("space")
                .font(.system(size: 15))
                .foregroundStyle(Palette.keyText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.keyFill, in: RoundedRectangle(cornerRadius: 6))
                .keyShadow()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Function keys

private struct ShiftKey: View {
    let state: ShiftState
    let width: CGFloat
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(state == .off ? Palette.keyText : .black)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                // Engaged shift renders as a white key in BOTH modes, like
                // the system's — hence literal white/black, not the dynamic
                // pair.
                .background(
                    state == .off ? Palette.specialKeyFill : .white,
                    in: RoundedRectangle(cornerRadius: 6))
                .keyShadow()
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch state {
        case .off: "shift"
        case .on: "shift.fill"
        case .capsLock: "capslock.fill"
        }
    }
}

/// Layer switch ("123" / "ABC" / "#+="): caption key in the function style.
private struct LayerKey: View {
    let cap: String
    let width: CGFloat
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Text(cap)
                .font(.system(size: 15))
                .foregroundStyle(Palette.keyText)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background(Palette.specialKeyFill, in: RoundedRectangle(cornerRadius: 6))
                .keyShadow()
        }
        .buttonStyle(.plain)
    }
}

/// Backspace with key repeat: one delete on touch-down, then after a hold
/// threshold ~12 deletes/s until release. A zero-distance drag gesture is the
/// SwiftUI press/release pair a plain Button can't provide.
private struct DeleteKey: View {
    let width: CGFloat
    let deleteBackward: () -> Void

    @State private var isPressed = false
    @State private var repeatTimer: Timer?

    private static let holdDelay: TimeInterval = 0.45
    private static let repeatInterval: TimeInterval = 0.08

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Palette.keyText)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(Palette.specialKeyFill, in: RoundedRectangle(cornerRadius: 6))
            .keyShadow()
            .opacity(isPressed ? 0.5 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginPress() }
                    .onEnded { _ in endPress() }
            )
    }

    private func beginPress() {
        guard !isPressed else { return }
        isPressed = true
        deleteBackward()
        let hold = Timer(timeInterval: Self.holdDelay, repeats: false) { _ in
            let repeating = Timer(
                timeInterval: Self.repeatInterval, repeats: true
            ) { _ in
                deleteBackward()
            }
            RunLoop.main.add(repeating, forMode: .common)
            repeatTimer = repeating
        }
        RunLoop.main.add(hold, forMode: .common)
        repeatTimer = hold
    }

    private func endPress() {
        isPressed = false
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

private struct ReturnKey: View {
    let width: CGFloat
    let insertNewline: () -> Void

    var body: some View {
        Button(action: insertNewline) {
            Image(systemName: "return")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.keyText)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background(Palette.specialKeyFill, in: RoundedRectangle(cornerRadius: 6))
                .keyShadow()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Globe key

/// The next-keyboard key, inside the grid's bottom row. Apple requires this
/// affordance and it must be a real UIButton feeding
/// `handleInputModeList(from:with:)` the raw UIEvent — a SwiftUI Button has
/// no event to forward, so this one key stays UIKit under a
/// UIViewRepresentable shell (fill + shadow are drawn by SwiftUI so it styles
/// like its neighbors). `KeyGrid` hides it when `needsInputModeSwitchKey`
/// says the system provides the switch elsewhere.
struct GlobeKey: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        if let controller {
            button.addTarget(
                controller,
                action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {}
}

// MARK: - Shared key styling

extension View {
    /// The native keys' hairline bottom shadow (present in both modes) —
    /// shared by every key here and the toolbar keys in `KeyboardBarView`.
    func keyShadow() -> some View {
        shadow(color: .black.opacity(0.3), radius: 0, y: 1)
    }
}
