import SwiftUI
import UIKit

/// The Dictate tab: a big brand record key with a live level ring, the last
/// transcript as a copy/share card, and status banners for the permission /
/// models-missing / error states. Tap starts the mic (indicator lights), tap
/// again stops → transcript lands on the pasteboard.
struct HomeView: View {
    @EnvironmentObject private var model: DictationModel
    @State private var showingSettings = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                banner
                recordKey
                statusLine
                transcriptCard
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.paper.ignoresSafeArea())
        .navigationTitle("whispr bro")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Brand.ink)
                }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsSheet() }
    }

    // MARK: Record key

    private var isRecording: Bool { model.state == .recording }
    private var canRecord: Bool {
        switch model.state {
        case .idle, .recording, .needsPermission: true
        default: false
        }
    }

    private var recordKey: some View {
        Button(action: { model.toggleRecording() }) {
            ZStack {
                // Live level ring: RMS (~0…0.3 for speech) scaled into 0…1.
                Circle()
                    .stroke(Brand.creamAccent, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: isRecording ? CGFloat(min(1, model.level * 6)) : 0)
                    .stroke(Brand.ink, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1.0 / 24), value: model.level)
                Circle()
                    .fill(isRecording ? Brand.signal : Brand.ink)
                    .padding(14)
                EchoWMark(color: Brand.paper, listening: isRecording)
                    .frame(width: 92, height: 62)
            }
            .frame(width: 196, height: 196)
        }
        .buttonStyle(.plain)
        .disabled(!canRecord)
        .opacity(canRecord ? 1 : 0.4)
        .padding(.top, 12)
        .accessibilityLabel(isRecording ? "Stop dictation" : "Start dictation")
    }

    private var statusLine: some View {
        Text(statusText.uppercased())
            .font(Brand.mono(12, .medium)).tracking(1.5)
            .foregroundStyle(isRecording ? Brand.signal : Brand.mist)
    }

    private var statusText: String {
        switch model.state {
        case .needsPermission: "microphone needed"
        case .modelsMissing: "models missing"
        case .loading: "loading models…"
        case .idle: "tap to dictate"
        case .recording: "listening — tap to stop"
        case .transcribing: "transcribing…"
        case .error: "error"
        }
    }

    // MARK: Banners

    @ViewBuilder private var banner: some View {
        switch model.state {
        case .needsPermission:
            card {
                bannerTitle("Microphone access needed")
                bannerBody("whispr bro transcribes on-device — audio never leaves this iPhone.")
                if model.microphoneDenied {
                    bannerButton("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } else {
                    bannerButton("Allow microphone") { model.requestMicrophone() }
                }
            }
        case .modelsMissing:
            card {
                bannerTitle("Speech models not installed")
                bannerBody("Models are bundled into release builds (scripts/make-ios-app.sh release). "
                    + "This build shipped without them — nothing to download; the app never touches the network.")
                bannerButton("Check again") { model.retry() }
            }
        case .error(let message):
            card {
                bannerTitle("Something went wrong", color: Brand.signal)
                bannerBody(message)
                bannerButton("Retry") { model.retry() }
            }
        default:
            EmptyView()
        }
    }

    private func bannerTitle(_ text: String, color: Color = Brand.ink) -> some View {
        Text(text).font(Brand.sans(15, .semibold)).foregroundStyle(color)
    }

    private func bannerBody(_ text: String) -> some View {
        Text(text).font(Brand.sans(13)).foregroundStyle(Brand.bodyMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bannerButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.paper)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Brand.ink, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Last transcript

    @ViewBuilder private var transcriptCard: some View {
        if !model.lastTranscript.isEmpty {
            card {
                HStack {
                    Text("LAST DICTATION")
                        .font(Brand.mono(10, .medium)).tracking(1).foregroundStyle(Brand.metaMuted)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = model.lastTranscript
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14)).foregroundStyle(Brand.mist)
                    }
                    .buttonStyle(.plain)
                    ShareLink(item: model.lastTranscript) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14)).foregroundStyle(Brand.mist)
                    }
                    .buttonStyle(.plain)
                }
                Text(model.lastTranscript)
                    .font(Brand.sans(15)).foregroundStyle(Brand.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if !model.lastTimings.isEmpty {
                    Text(model.lastTimings)
                        .font(Brand.mono(10.5)).foregroundStyle(Brand.metaMuted)
                }
                Text("Copied to the clipboard — paste it anywhere.")
                    .font(Brand.sans(12)).foregroundStyle(Brand.mist)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Brand.raised, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Brand.ink.opacity(0.08), lineWidth: 1))
    }
}
