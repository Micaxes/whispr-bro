import SwiftUI
import UIKit
import WhisprBroIPC

/// Brand palette subset plus — new for this codebase — dark-mode-aware key
/// colors. `Brand` in the apps is AppKit/UIKit-bound and the appex links
/// neither the app nor core, so the needed brand values are restated (same
/// hex as Brand.swift / BrandKit.swift). No custom fonts either — the appex
/// bundles no TTFs, so mono text uses the system monospaced face.
///
/// Why this is the first adaptive surface: the apps own their whole window
/// and can paint cream everywhere, but a keyboard is embedded in the SYSTEM's
/// chrome — an opaque cream slab clashes with the host app and the native
/// keyboard material, badly so in dark mode. So the chrome and key fills here
/// track the system appearance (dynamic `UIColor` closures, resolved per
/// trait collection) and the brand survives as accents only: `signal` for
/// record/cancel, the `ink` pebble + `paper` waveform in the status strip,
/// `creamAccent` for the pending-result state.
enum Palette {
    // Brand literals — fixed in both modes, used as accents only.
    static let ink = Color(red: 0x17 / 255.0, green: 0x13 / 255.0, blue: 0x0E / 255.0)
    static let paper = Color(red: 0xF4 / 255.0, green: 0xEF / 255.0, blue: 0xE4 / 255.0)
    static let creamAccent = Color(red: 0xE7 / 255.0, green: 0xDC / 255.0, blue: 0xC6 / 255.0)
    static let signal = Color(red: 0xB2 / 255.0, green: 0x45 / 255.0, blue: 0x2F / 255.0)
    static let lightMono = Color(red: 0xC7 / 255.0, green: 0xBF / 255.0, blue: 0xAD / 255.0)
    static let pebbleBorder = paper.opacity(0.14)

    // Dynamic key colors, matched by eye to the native iOS keyboard.

    /// Character keys: white in light mode, the system's mid gray in dark.
    static let keyFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.42, alpha: 1)
            : .white
    })
    /// Function keys (shift, delete, layer, globe, return, toolbar keys):
    /// the darker gray the system uses for non-character keys.
    static let specialKeyFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.26, alpha: 1)
            : UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1)
    })
    /// Key glyphs/captions — semantic, so they flip with the mode.
    static let keyText = Color(uiColor: .label)
    static let keyTextSecondary = Color(uiColor: .secondaryLabel)
    /// Escape hatch only: the controller keeps its root view CLEAR so the
    /// system's keyboard background material shows through — that is what
    /// blends the appex with native chrome in both modes. If a host ever
    /// renders the appex without that material, point the controller's
    /// background at this opaque approximation of it, never back at cream.
    static let chromeFallback = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.17, alpha: 1)
            : UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1)
    })
}

/// The keyboard surface (issue #13 P4, layout rev): a compact toolbar row —
/// [status strip, flexible][settings gear][✕ while recording][mic, far
/// right] — above a standard iOS-style typing grid (`KeyGrid`). Without Full
/// Access the strip + mic give way to an inline explainer (the app connection
/// needs the App Group, which iOS only grants an open-access keyboard) while
/// typing keeps working and the gear stays reachable. The globe key lives in
/// the grid's bottom row — it must forward the raw UIEvent to
/// `handleInputModeList`, hence the weak `controller` reference threaded
/// through to `GlobeKey`.
struct KeyboardBar: View {
    @ObservedObject var session: KeyboardSession
    weak var controller: UIInputViewController?
    var insertCharacter: (String) -> Void
    var deleteBackward: () -> Void
    var insertNewline: () -> Void
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if session.hasFullAccess {
                    StatusStrip(session: session)
                    SettingsKey(open: openSettings)
                    if session.phase == .recording || session.phase == .starting {
                        CancelKey { session.cancelTapped() }
                    }
                    MicKey(phase: session.phase) { session.micTapped() }
                } else {
                    FullAccessPanel()
                    SettingsKey(open: openSettings)
                }
            }
            .frame(height: 40)
            .animation(.easeOut(duration: 0.15), value: session.phase)

            KeyGrid(
                session: session,
                controller: controller,
                insertCharacter: insertCharacter,
                deleteBackward: deleteBackward,
                insertNewline: insertNewline)
        }
    }
}

// MARK: - Mic key (the hero)

private struct MicKey: View {
    let phase: MicPhase
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .symbolEffect(.pulse, isActive: pulses)
                .foregroundStyle(glyph)
                .frame(width: 56, height: 40)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(border, lineWidth: 1.5)
                )
                .overlay(alignment: .topTrailing) { badge }
                .keyShadow()
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch phase {
        case .idle, .arming: "mic"
        case .armed, .starting: "mic.fill"
        case .recording: "checkmark"
        case .transcribing: "ellipsis"
        case .pendingResult: "text.insert"
        case .bounce: "arrow.up.forward.app"
        }
    }

    private var glyph: Color {
        switch phase {
        case .idle, .arming: Palette.keyText
        case .pendingResult: Palette.ink
        case .bounce: Palette.signal
        default: Palette.paper
        }
    }

    private var background: Color {
        switch phase {
        case .idle, .arming: Palette.specialKeyFill
        case .pendingResult: Palette.creamAccent
        default: Palette.ink
        }
    }

    private var border: Color {
        switch phase {
        case .recording: Palette.creamAccent
        case .bounce: Palette.signal
        default: .clear
        }
    }

    private var pulses: Bool {
        switch phase {
        case .arming, .starting, .transcribing: true
        default: false
        }
    }

    @ViewBuilder private var badge: some View {
        if case .pendingResult(let count) = phase, count > 1 {
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.paper)
                .frame(minWidth: 16, minHeight: 16)
                .background(Palette.ink, in: Circle())
                .offset(x: 5, y: -5)
        }
    }
}

/// Cancel (✕) — shown next to the mic while a dictation is starting or
/// recording. `signal` is the brand's destructive-only color.
private struct CancelKey: View {
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.signal)
                .frame(width: 40, height: 40)
                .background(Palette.specialKeyFill, in: RoundedRectangle(cornerRadius: 8))
                .keyShadow()
        }
        .buttonStyle(.plain)
    }
}

/// Toolbar gear — deep-links into the app's Settings sheet
/// (whisprbro://settings). Reachable with or without Full Access: language,
/// Auto-Clean, and history all live there, and pointing at them costs the
/// appex nothing.
private struct SettingsKey: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.keyText)
                .frame(width: 40, height: 40)
                .background(Palette.specialKeyFill, in: RoundedRectangle(cornerRadius: 8))
                .keyShadow()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status strip

/// The toolbar's flexible middle: a mini ink pebble (like the mac HUD) that
/// shows the live waveform while recording — joined by the streaming partial
/// preview when one is flowing (`KeyboardSession.partialText`) — and a mono
/// status line otherwise.
/// When IPC is disabled (`KeyboardSession.ipcEnabled` false — App Group
/// container unavailable, `SharedContainer`'s documented degraded mode) the
/// idle line tells the truth instead of promising an arming flow that can
/// never progress: dictating opens the app.
private struct StatusStrip: View {
    @ObservedObject var session: KeyboardSession

    var body: some View {
        ZStack {
            if session.phase == .recording {
                if let partial = session.partialText {
                    // Live preview: waveform compressed to a small leading
                    // strip (the NEWEST 10 levels — 28 bars at fixed spacing
                    // would overflow 44pt), the TAIL of the preview trailing-
                    // aligned beside it (head truncation — the newest speech
                    // is what matters). Paper on ink, like the waveform: the
                    // pebble is a fixed-brand surface, not an adaptive key.
                    HStack(spacing: 10) {
                        Waveform(levels: Array(session.levels.suffix(10)))
                            .frame(width: 44)
                            .padding(.vertical, 8)
                        Text(partial)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Palette.paper)
                            .lineLimit(2)
                            .truncationMode(.head)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                } else {
                    // No partials (assets not installed, degraded IPC…):
                    // exactly today's waveform-only strip.
                    Waveform(levels: session.levels)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            } else {
                line
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(labelColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
        .background(
            Capsule()
                .fill(Palette.ink)
                .overlay(Capsule().strokeBorder(Palette.pebbleBorder, lineWidth: 1))
        )
    }

    /// The non-waveform strip content, as `Text` (not `String`) so the error
    /// state can inline its triangle glyph in the same run — Wispr's orange
    /// triangle, in brand signal.
    private var line: Text {
        showsError
            ? Text("\(Image(systemName: "exclamationmark.triangle.fill")) \(errorCopy)")
            : Text(label)
    }

    /// Error strip precedence: only over the idle label. A pending transcript
    /// beats it (that key is the more actionable state and the mic key is
    /// already re-themed for it), and a mic tap mid-error hands the strip to
    /// the arming hint — the retry deep-link is the answer to every one of
    /// these errors, so the "it's in progress" line supersedes the complaint.
    /// Only a RETRY tap's hint can be live here: the hint opened by the tap
    /// that CAUSED the failure is killed when the error latches
    /// (`KeyboardSession.updateSessionError`) — it outlives the error hold,
    /// so left alive it would mask micStartFailed for its whole life.
    private var showsError: Bool {
        session.phase == .idle && session.sessionError != .none && !session.showsArmingHint
    }

    private var errorCopy: String {
        switch session.sessionError {
        case .none: "" // unreachable behind showsError
        case .micStartFailed: "couldn't start audio capture — tap mic to retry"
        case .micInterrupted: "mic taken by another app"
        case .modelLoadFailed: "model failed to load — open whispr bro"
        case .transcriptionFailed: "transcription failed — try again"
        }
    }

    private var label: String {
        switch session.phase {
        case .idle:
            if session.showsArmingHint {
                "finishing in whispr bro — swipe back when armed"
            } else if !session.ipcEnabled {
                "keyboard link off in this build — dictating opens whispr bro"
            } else {
                "tap mic to arm dictation"
            }
        case .arming: "arming…"
        case .armed: "armed — tap mic to dictate"
        case .starting: "starting…"
        case .recording: "" // waveform branch
        case .transcribing: "transcribing…"
        case .pendingResult(let count):
            count == 1
                ? "transcript ready — tap to insert"
                : "\(count) transcripts ready — tap to insert"
        case .bounce: "whispr bro stopped — tap to reopen"
        }
    }

    private var labelColor: Color {
        session.phase == .bounce || showsError ? Palette.signal : Palette.lightMono
    }
}

/// Center-tapered bar waveform, the keyboard sibling of the mac HUD's (brand
/// doc: "28 samples · center-tapered"): cream capsules on the ink pebble, a
/// `sin(i·π)` envelope tapering the ends to zero.
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let spacing: CGFloat = 2.5
            let barWidth = max(1.5, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    let taper = sin(Double(index) / Double(max(1, count - 1)) * .pi)
                    Capsule()
                        .fill(Palette.paper)
                        .frame(
                            width: barWidth,
                            height: max(2, CGFloat(level) * CGFloat(taper) * geo.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - Full Access explainer

/// Shown in place of the mic + strip when `hasFullAccess` is false. Full
/// Access is what lets iOS grant the keyboard its App Group — the only
/// channel to the whispr bro app. One line of WHY with the privacy stance up
/// front (the toggle scares, rightly — this binary contains zero networking
/// code) and one line of WHERE, nothing else.
private struct FullAccessPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("allow full access — dictation runs on-device, nothing leaves your phone")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.keyText)
            Text("settings → general → keyboard → keyboards → whispr bro")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.keyTextSecondary)
        }
        .lineLimit(2)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
        .background(Palette.keyFill, in: RoundedRectangle(cornerRadius: 8))
        .keyShadow()
    }
}
