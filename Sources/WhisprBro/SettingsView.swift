import SwiftUI
import WhisprBroCore

/// Preferences window (spec §11.7): the ModelManager pane (on-disk sha256
/// verify), the formatting-model preset picker (incl. the Qwen3 quality
/// preset), the idle-LLM-unload setting, the ASR fallback-engine slot, and the
/// offline posture at a glance.
struct SettingsView: View {
    @ObservedObject var pipeline: PipelineController
    @StateObject private var models = ModelStatusModel()
    // @AppStorage makes the ASR selection an observable SwiftUI dependency (a
    // plain UserDefaults static would not re-render the picker or its note).
    // Same "asrEngineKind" key AsrEngineKind.selected reads, so they stay in sync.
    @AppStorage("asrEngineKind") private var asrKindRaw = AsrEngineKind.parakeet.rawValue

    var body: some View {
        TabView {
            modelsTab.tabItem { Label("Models", systemImage: "shippingbox") }
            autoCleanTab.tabItem { Label("Auto-Clean", systemImage: "wand.and.sparkles") }
            performanceTab.tabItem { Label("Performance", systemImage: "gauge") }
            privacyTab.tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 460)
        .task { await models.refresh() }
    }

    // MARK: Models

    private var modelsTab: some View {
        Form {
            Section("Formatting model") {
                Picker("Model", selection: llmBinding) {
                    ForEach(LlmCatalog.all, id: \.key) { spec in
                        Text(label(for: spec)).tag(spec.key)
                            .disabled(!spec.isInstalled)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Qwen2.5 1.5B is the measured default. Qwen3 1.7B is a higher-quality preset (slower — best on Pro/Max). Only installed models can be selected.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Speech-recognition engine") {
                Picker("Engine", selection: asrBinding) {
                    ForEach(AsrEngineKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(asrEngineNote).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(models.groups) { g in
                    HStack {
                        Image(systemName: g.isVerified ? "checkmark.seal.fill"
                              : (g.isInstalled ? "exclamationmark.triangle.fill" : "xmark.seal"))
                            .foregroundStyle(g.isVerified ? .green : (g.isInstalled ? .orange : .secondary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.displayName)
                            Text(g.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } header: {
                HStack {
                    Text("Installed model integrity")
                    Spacer()
                    Button(models.verifying ? "Verifying…" : "Verify on disk") {
                        Task { await models.refresh() }
                    }
                    .disabled(models.verifying)
                }
            } footer: {
                Text("Re-hashes every model file against the checked-in sha256 manifest. Fetch or repair with scripts/fetch-models.sh.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Auto-Clean

    private var autoCleanTab: some View {
        Form {
            Section("Auto-Clean") {
                Picker("Level", selection: $pipeline.cleanupLevel) {
                    ForEach(AppConfig.Cleanup.Level.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(cleanupLevelNote).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("“Standard” resolves self-corrections: when you misspeak and restate — “meet at 2, actually 3” — only the corrected version “meet at 3” is kept. If unsure, it keeps both. It never changes facts, numbers, or names.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("How corrections work")
            } footer: {
                Text("In code editors, terminals, and notes, Auto-Clean's filler removal and self-correction are skipped (your normal per-app formatting still applies). The filler set and these verbatim apps are editable in config.toml (menu → Edit dictionary & config…).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Undo") {
                Label("An edit removed words? Menu → “Undo last Auto-Clean (paste raw)” re-inserts exactly what you said.", systemImage: "arrow.uturn.backward")
                    .font(.caption)
                Text("Note: raw is your verbatim words — it also restores fillers and drops added punctuation/capitalization. A single-deletion undo is a future feature.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Atypical speech") {
                Text("If you stutter, are dictating in a second language, or want your repetitions kept, set Level to “Off (verbatim)” — nothing is removed. Defaults stay conservative.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var cleanupLevelNote: String {
        switch pipeline.cleanupLevel {
        case .verbatim: "Nothing is removed — you get exactly what you said (with your dictionary applied)."
        case .fillers: "Removes filler words (um, uh, er) only. No wording is changed. Safe default."
        case .standard: "Removes fillers AND resolves self-corrections (opt-in). Uses the on-device model."
        }
    }

    // MARK: Performance

    private var performanceTab: some View {
        Form {
            Section("Idle LLM unload") {
                Toggle("Unload the formatting model when idle", isOn: $pipeline.idleUnloadEnabled)
                Stepper("After \(pipeline.idleUnloadMinutes) min idle",
                        value: $pipeline.idleUnloadMinutes, in: 1...60)
                    .disabled(!pipeline.idleUnloadEnabled)
                Text("Frees ~1GB of memory after the model sits unused. The next dictation reloads it (~1–2s once).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Privacy

    private var privacyTab: some View {
        Form {
            Section("History") {
                Toggle("Save dictation history", isOn: $pipeline.historyEnabled)
                Text("When off, dictations are inserted but never written to the local history database.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Offline") {
                Label("Runs entirely on this Mac — no network, no telemetry.", systemImage: "wifi.slash")
                Text("Enforced three ways: a CI symbol audit, a runtime connect() tripwire, and a tcpdump zero-packet capture. See docs/OFFLINE.md for the Little Snitch / LuLu deny-all rule.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Bindings & labels

    private var llmBinding: Binding<String> {
        Binding(get: { pipeline.llmModelKey }, set: { pipeline.selectLLM(key: $0) })
    }

    private var asrBinding: Binding<AsrEngineKind> {
        Binding(
            get: { AsrEngineKind(rawValue: asrKindRaw) ?? .parakeet },
            set: { asrKindRaw = $0.rawValue })   // @AppStorage write → view re-renders
    }

    private func label(for spec: LlmModelSpec) -> String {
        spec.isInstalled ? spec.displayName : "\(spec.displayName) — not installed"
    }

    private var asrEngineNote: String {
        (AsrEngineKind(rawValue: asrKindRaw) ?? .parakeet) == .whisperCpp
            ? "whisper.cpp is a fallback slot and isn't bundled in this build — the app stays on Parakeet. Selection applies on next launch."
            : "Parakeet runs on the Neural Engine (~150ms). Engine changes apply on next launch."
    }
}

/// Runs ModelManager.verifyAll off the main thread and publishes the result.
@MainActor
final class ModelStatusModel: ObservableObject {
    @Published var groups: [ModelManager.GroupStatus] = []
    @Published var verifying = false

    func refresh() async {
        verifying = true
        let result = await Task.detached(priority: .utility) {
            ModelManager.verifyAll()
        }.value
        groups = result
        verifying = false
    }
}
