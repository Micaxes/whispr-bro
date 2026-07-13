import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity UI for a dictation in progress: Lock Screen banner + Dynamic
/// Island with the elapsed timer, a coarse level bar, and a Stop button bound
/// to `StopDictationIntent` (which executes in the app process). This is the
/// platform-contract half of `StartDictationIntent` — an
/// `AudioRecordingIntent` recording is stopped by the system without a
/// visible Live Activity.
@main
struct WhisprBroWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DictationLiveActivity()
    }
}

struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            LockScreenDictationView(context: context)
                .activityBackgroundTint(WidgetBrand.ink)
                .activitySystemActionForegroundColor(WidgetBrand.paper)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedOrPhaseText(context: context)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        LevelBar(level: context.state.level)
                        StopButton(phase: context.state.phase)
                    }
                    .padding(.top, 6)
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                ElapsedOrPhaseText(context: context)
                    .frame(maxWidth: 46)
            } minimal: {
                PhaseIcon(phase: context.state.phase)
            }
        }
    }
}

private struct LockScreenDictationView: View {
    let context: ActivityViewContext<DictationActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            PhaseIcon(phase: context.state.phase)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 3) {
                Text("whispr bro")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(WidgetBrand.paper)
                LevelBar(level: context.state.level)
                    .frame(width: 110)
            }
            Spacer()
            ElapsedOrPhaseText(context: context)
            StopButton(phase: context.state.phase)
        }
        .padding(14)
    }
}

/// Recording → live timer from `startedAt` (ticks with no updates);
/// otherwise the phase label, so "stop" visibly hands over to the pipeline.
private struct ElapsedOrPhaseText: View {
    let context: ActivityViewContext<DictationActivityAttributes>

    var body: some View {
        switch context.state.phase {
        case .recording:
            Text(context.attributes.startedAt, style: .timer)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(WidgetBrand.paper)
                .multilineTextAlignment(.trailing)
        case .transcribing:
            Text("transcribing…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WidgetBrand.mist)
        case .done:
            Text("done")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WidgetBrand.mist)
        }
    }
}

private struct PhaseIcon: View {
    let phase: DictationActivityAttributes.Phase

    var body: some View {
        switch phase {
        case .recording:
            Image(systemName: "mic.fill").foregroundStyle(WidgetBrand.signal)
        case .transcribing:
            Image(systemName: "waveform").foregroundStyle(WidgetBrand.paper)
        case .done:
            Image(systemName: "checkmark").foregroundStyle(WidgetBrand.paper)
        }
    }
}

private struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetBrand.paper.opacity(0.18))
                Capsule()
                    .fill(WidgetBrand.paper)
                    // RMS ~0…0.3 for speech, scaled into 0…1 like the app's
                    // record-key ring.
                    .frame(width: geo.size.width * min(1, level * 6))
            }
        }
        .frame(height: 4)
    }
}

private struct StopButton: View {
    let phase: DictationActivityAttributes.Phase

    var body: some View {
        Button(intent: StopDictationIntent()) {
            Image(systemName: "stop.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WidgetBrand.ink)
                .padding(10)
                .background(WidgetBrand.paper, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(phase != .recording)
        .opacity(phase == .recording ? 1 : 0.35)
    }
}

/// Brand ink/paper/signal inlined (hex contract from "Whispr Bro Brand") —
/// BrandKit lives in the app target and this appex stays dependency-free.
private enum WidgetBrand {
    static let ink = Color(hex: 0x17130E)
    static let paper = Color(hex: 0xF4EFE4)
    static let signal = Color(hex: 0xB2452F)
    static let mist = Color(hex: 0x8C8578)
}

extension Color {
    /// 0xRRGGBB literal → sRGB Color (widget-local copy of BrandKit's).
    fileprivate init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
