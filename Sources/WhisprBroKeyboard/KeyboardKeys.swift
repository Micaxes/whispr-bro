import SwiftUI
import UIKit

/// The typing surface under the toolbar — the "full QWERTY is a later phase"
/// of issue #13 P4, now at native parity: the standard iOS key layout as
/// row-string data, three layers (letters / numbers / symbols), shift with
/// one-shot auto-reset + double-tap caps lock and host-trait auto-
/// capitalization, press-and-repeat delete that escalates to word deletion,
/// key-pop callout balloons, touch-down click sounds, and the mandatory globe
/// key. Correction/prediction smarts live in `AutocorrectEngine` behind
/// `AutocorrectController` — the keys only route through it — so the appex
/// still stays a thin client under its ~48MB jetsam cap: no haptics, no
/// long-press alternates (explicit non-goal), and `textDocumentProxy`
/// insertion remains the whole output.

/// System key sounds, fired on touch-DOWN like the system keyboard. EVERY
/// sound routes through `playInputClick` — the native keyboard differentiates
/// delete (1155) and function (1156) via AudioServices, but that route
/// IGNORES Settings > Sounds > Keyboard Clicks and there is no API to read
/// the toggle; only `playInputClick` honors it. Honoring the user's toggle
/// beats differentiated sounds, so the single click is the accepted tradeoff
/// (`Sound` survives to keep call sites intent-typed if the OS ever opens a
/// toggle-respecting route). ALL gated on Full Access: without it
/// `playInputClick()` stalls the appex for whole seconds before failing
/// silently, so the gate mirrors `hasFullAccess` each appearance
/// (`KeyboardViewController.viewWillAppear`). `playInputClick` itself only
/// sounds because the controller's root view is a `UIInputView` conforming
/// to `UIInputViewAudioFeedback` (see `ClickFeedbackInputView`).
enum KeyClick {
    enum Sound {
        case character, delete, function
    }

    /// Mirrored from `hasFullAccess` — see type doc.
    static var enabled = false

    static func play(_ sound: Sound) {
        guard enabled else { return }
        UIDevice.current.playInputClick() // one toggle-honoring sound, all keys
    }
}

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
    @ObservedObject var autocorrect: AutocorrectController
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
        .onAppear(perform: applyAutoCapHint)
        // VALUE flips only (deletes, resyncs, cursor moves) — every insertion
        // additionally re-applies unconditionally, see `insert`.
        .onChange(of: autocorrect.autoCapHint) { applyAutoCapHint() }
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
    /// …punctuation…[delete] on the others. The five punctuation keys use the
    /// native even-fill width — sides are 1.4u, so
    /// (10u + 9g − 2×1.4u − 6g)/5 = 1.44u + 0.6g (≈1.5×unit) fills the row
    /// edge-to-edge with no spacers, exactly like the system keyboard.
    private func thirdRow(unit: CGFloat) -> some View {
        let punctuationWidth = unit * 1.44 + Self.gap * 0.6
        return HStack(spacing: Self.gap) {
            if layer == .letters {
                ShiftKey(state: shift, width: unit * 1.4, tap: shiftTapped)
                Spacer(minLength: 0)
            } else {
                LayerKey(cap: layer == .numbers ? "#+=" : "123", width: unit * 1.4) {
                    layer = layer == .numbers ? .symbols : .numbers
                }
            }
            ForEach(layer.rows[2], id: \.self) { key in
                CharKey(
                    cap: cap(for: key),
                    width: layer == .letters ? unit : punctuationWidth
                ) { insert(key) }
            }
            if layer == .letters {
                Spacer(minLength: 0)
            }
            DeleteKey(
                width: unit * 1.4,
                deleteBackward: deleteBackward,
                deleteWordBackward: { autocorrect.deleteWordBackward() })
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
            SpaceKey {
                insertCharacter(" ")
                applyAutoCapHint() // every insertion re-applies — see `insert`
            }
            ReturnKey(width: unit * 2.5, label: session.returnKeyLabel) {
                insertNewline()
                applyAutoCapHint() // every insertion re-applies — see `insert`
            }
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
        // Unconditional re-apply, NOT only on value change: in an
        // .allCharacters field the hint is constantly true, so `.onChange`
        // never re-fires after the one-shot reset above — without this,
        // letters 2+ would type lowercase. The hint was just recomputed from
        // the post-insert context, so .sentences/.words behave identically
        // (mid-word/mid-sentence the hint is false and this is a no-op).
        applyAutoCapHint()
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

    /// Host-trait auto-capitalization (`AutocorrectController.autoCapHint`):
    /// when the context says the next letter starts a sentence/word, raise
    /// shift exactly as if the user had tapped it — one-shot, letters layer
    /// only, and never LOWERS (the existing one-shot reset handles the way
    /// down; caps lock and a user-raised shift are left alone).
    private func applyAutoCapHint() {
        if autocorrect.autoCapHint, shift == .off, layer == .letters { shift = .on }
    }
}

// MARK: - Key-pop callout

/// The pressed character key's cap + bounds, floated up by anchor preference
/// to `KeyboardBar`, which draws the balloon in an overlay spanning the WHOLE
/// bar — the pop must rise above its key row (over the toolbar, for row 1),
/// which no key's own bounds could host.
struct KeyCallout {
    let cap: String
    let anchor: Anchor<CGRect>
}

struct KeyCalloutKey: PreferenceKey {
    static let defaultValue: KeyCallout? = nil

    static func reduce(value: inout KeyCallout?, nextValue: () -> KeyCallout?) {
        if let next = nextValue() { value = next }
    }
}

/// The native key-pop balloon (iPhone only — `CharKey` publishes no anchor on
/// pad, matching the system). Head ≈1.45× the key width, corner radius 11,
/// 44pt glyph; head, neck and key cover are ONE nonzero-filled path in the
/// key fill so they read as a single connected surface. The head is clamped
/// inside the bar's width (edge keys pin to the side instead of centering)
/// and its rise above the key top is capped — the appex cannot draw outside
/// its own input view, and toolbar (40) + VStack spacing (8) give row 1
/// exactly 48pt of in-view headroom.
struct KeyCalloutBalloon: View {
    let cap: String
    let keyRect: CGRect
    let containerWidth: CGFloat

    private static let widthFactor: CGFloat = 1.45
    private static let cornerRadius: CGFloat = 11
    /// Max rise of the head's top edge above the key top (< the 48pt
    /// headroom, see type doc).
    private static let maxRise: CGFloat = 46
    /// How far the head overlaps the key top — the connected neck.
    private static let neckOverlap: CGFloat = 8

    var body: some View {
        let width = min(keyRect.width * Self.widthFactor, containerWidth)
        let originX = min(max(keyRect.midX - width / 2, 0), containerWidth - width)
        let top = max(keyRect.minY - Self.maxRise, 0)
        let head = CGRect(
            x: originX, y: top,
            width: width, height: keyRect.minY - top + Self.neckOverlap)
        balloonPath(head: head)
            .fill(Palette.keyFill)
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .keyShadow()
            .overlay {
                Text(cap)
                    .font(.system(size: 44))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Palette.keyText)
                    .frame(width: head.width, height: head.height)
                    .position(x: head.midX, y: head.midY)
            }
    }

    private func balloonPath(head: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: head,
            cornerSize: CGSize(width: Self.cornerRadius, height: Self.cornerRadius))
        path.addRoundedRect(in: keyRect, cornerSize: CGSize(width: 6, height: 6))
        return path
    }
}

// MARK: - Character keys

/// A character key with native press behavior: touch-down = click sound +
/// callout balloon (via anchor preference — see `KeyCallout`); drag off the
/// key (+ slop) = cancel the balloon AND the insert (the system's escape
/// gesture; slide-retargeting is out of scope); touch-up inside = insert.
/// A zero-distance drag gesture is the press/release pair a Button can't
/// provide — and a Button's action would fire on up anyway, too late for the
/// balloon.
///
/// `touchActive` is `@GestureState`, deliberately: SwiftUI never calls
/// `onEnded` when the SYSTEM cancels a touch (incoming-call banner, app
/// switch), but a `@GestureState` always resets — the `.onChange` watching
/// its falling edge is the guaranteed cleanup, so a cancelled touch can
/// never leave a stuck balloon or a stale `cancelled` latch eating the next
/// touch's click. The gesture itself lost the button semantics VoiceOver
/// needs, so the accessibility modifiers restore them: button trait, the
/// character as the label, and activation (double-tap) performing the
/// click + insert.
private struct CharKey: View {
    let cap: String
    let width: CGFloat
    let tap: () -> Void

    /// True while a finger is down — auto-resets on gesture END and system
    /// CANCEL alike (see type doc); `pressed`/`cancelled` are cleaned from
    /// its falling edge.
    @GestureState private var touchActive = false
    @State private var pressed = false
    @State private var cancelled = false
    @State private var size = CGSize.zero

    private static let dragSlop: CGFloat = 20
    /// Callout balloons are an iPhone-only native behavior (iPad shows none —
    /// there the pressed key dims instead, also native).
    private static let calloutsEnabled = UIDevice.current.userInterfaceIdiom == .phone

    var body: some View {
        Text(cap)
            .font(.system(size: 22))
            .foregroundStyle(Palette.keyText)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(Palette.keyFill, in: RoundedRectangle(cornerRadius: 6))
            .keyShadow()
            .opacity(pressed && !Self.calloutsEnabled ? 0.5 : 1)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
            .anchorPreference(key: KeyCalloutKey.self, value: .bounds) { anchor in
                pressed && Self.calloutsEnabled ? KeyCallout(cap: cap, anchor: anchor) : nil
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touchActive) { _, active, _ in active = true }
                    .onChanged { drag in
                        if !pressed, !cancelled {
                            pressed = true
                            KeyClick.play(.character)
                        }
                        if pressed, isOutside(drag.location) {
                            pressed = false
                            cancelled = true
                        }
                    }
                    .onEnded { _ in
                        if pressed { tap() } // touch-up inside inserts
                        pressed = false
                        cancelled = false
                    }
            )
            .onChange(of: touchActive) { _, active in
                // The falling edge fires for BOTH endings. A normal lift
                // already ran `onEnded` (event time precedes this render-time
                // hook, so the insert is never lost) and this is idempotent;
                // a system cancel runs ONLY this — the stuck-balloon fix.
                if !active {
                    pressed = false
                    cancelled = false
                }
            }
            .accessibilityElement()
            .accessibilityLabel(cap)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                KeyClick.play(.character)
                tap()
            }
    }

    private func isOutside(_ point: CGPoint) -> Bool {
        point.x < -Self.dragSlop || point.x > size.width + Self.dragSlop
            || point.y < -Self.dragSlop || point.y > size.height + Self.dragSlop
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
        }
        // Native pressed space DARKENS to the function gray (the inverse of
        // the function keys' lighten).
        .buttonStyle(KeySoundButtonStyle(
            sound: .character, fill: Palette.keyFill, pressedFill: Palette.specialKeyFill))
    }
}

// MARK: - Function keys

/// Touch-down key sound + the native pressed look for the Button-based keys:
/// a Button's action fires on touch-UP, but native clicks are on touch-DOWN —
/// the `isPressed` flip is the down edge. The style owns the key's rounded
/// background so `isPressed` can swap the fill UNDER the glyph, per the
/// native palette: function keys lighten to the character-key fill, the
/// space bar darkens to the function fill (light-mode letter keys don't dim
/// at all — those are `CharKey`'s balloon, not this style).
private struct KeySoundButtonStyle: ButtonStyle {
    let sound: KeyClick.Sound
    let fill: Color
    /// Shown while pressed instead of `fill`.
    let pressedFill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? pressedFill : fill,
                in: RoundedRectangle(cornerRadius: 6))
            .keyShadow()
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { KeyClick.play(sound) }
            }
    }
}

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
        }
        // Engaged shift renders as a white key in BOTH modes, like the
        // system's — hence literal white/black, not the dynamic pair.
        .buttonStyle(KeySoundButtonStyle(
            sound: .function,
            fill: state == .off ? Palette.specialKeyFill : .white,
            pressedFill: Palette.keyFill))
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
        }
        .buttonStyle(KeySoundButtonStyle(
            sound: .function, fill: Palette.specialKeyFill, pressedFill: Palette.keyFill))
    }
}

/// Backspace with key repeat: one delete on touch-down, then after a hold
/// threshold ~12 deletes/s until release — and after ~2s of held repeats the
/// escalation the system does too: whole-word deletion at a slower cadence
/// (`AutocorrectController.deleteWordBackward`). A zero-distance drag gesture
/// is the SwiftUI press/release pair a plain Button can't provide.
///
/// `pressed` is `@GestureState`, NOT `@State`, and that is load-bearing:
/// SwiftUI never calls `onEnded` when the SYSTEM cancels a touch
/// (incoming-call banner, app switch), so `@State` + `.onEnded` teardown
/// would leave the repeat firing forever — word-deleting the host document
/// every 0.3s. A `@GestureState` always resets on end AND cancel; the
/// `.onChange` watching its edges is the guaranteed timer teardown, and as
/// a belt-and-braces watchdog every timer tick re-checks `pressed` before
/// its burst — a repeat that somehow outlives the press stops itself
/// instead of deleting anything. The gesture lost VoiceOver's button
/// semantics, so the accessibility modifiers restore them: activation
/// (double-tap) performs one click + delete (no repeat — VoiceOver users
/// activate discretely).
private struct DeleteKey: View {
    let width: CGFloat
    let deleteBackward: () -> Void
    let deleteWordBackward: () -> Void

    /// Auto-resets on gesture END and system CANCEL alike — see type doc.
    @GestureState private var pressed = false
    @State private var repeatTimer: Timer?

    private static let holdDelay: TimeInterval = 0.45
    private static let repeatInterval: TimeInterval = 0.08
    /// Held this long past touch-down, char repeats escalate to word deletes.
    private static let wordEscalationDelay: TimeInterval = 2.0
    private static let wordRepeatInterval: TimeInterval = 0.3

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Palette.keyText)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(Palette.specialKeyFill, in: RoundedRectangle(cornerRadius: 6))
            .keyShadow()
            .opacity(pressed ? 0.5 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
            .onChange(of: pressed) { _, isPressed in
                if isPressed { beginPress() } else { endPress() }
            }
            .accessibilityElement()
            .accessibilityLabel("delete")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                KeyClick.play(.delete)
                deleteBackward()
            }
    }

    private func beginPress() {
        KeyClick.play(.delete)
        deleteBackward()
        let escalateAt = Date().addingTimeInterval(Self.wordEscalationDelay)
        let hold = Timer(timeInterval: Self.holdDelay, repeats: false) { _ in
            guard pressed else { return } // watchdog — see type doc
            let repeating = Timer(
                timeInterval: Self.repeatInterval, repeats: true
            ) { timer in
                guard pressed else { return endPress() } // watchdog
                if Date() >= escalateAt {
                    // Escalate: swap the char-repeat timer for the slower
                    // word-delete cadence.
                    timer.invalidate()
                    let words = Timer(
                        timeInterval: Self.wordRepeatInterval, repeats: true
                    ) { _ in
                        guard pressed else { return endPress() } // watchdog
                        deleteWordBackward()
                    }
                    RunLoop.main.add(words, forMode: .common)
                    repeatTimer = words
                    deleteWordBackward()
                } else {
                    deleteBackward()
                }
            }
            RunLoop.main.add(repeating, forMode: .common)
            repeatTimer = repeating
        }
        RunLoop.main.add(hold, forMode: .common)
        repeatTimer = hold
    }

    private func endPress() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

/// Return, captioned per the host field's `returnKeyType` ("return", "go",
/// "search", …) — mirrored on `KeyboardSession.returnKeyLabel`, like the
/// system keyboard's blue action captions (color stays the function fill:
/// the tinted variants are out of scope).
private struct ReturnKey: View {
    let width: CGFloat
    let label: String
    let insertNewline: () -> Void

    var body: some View {
        Button(action: insertNewline) {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Palette.keyText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: width)
                .frame(maxHeight: .infinity)
        }
        .buttonStyle(KeySoundButtonStyle(
            sound: .function, fill: Palette.specialKeyFill, pressedFill: Palette.keyFill))
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
