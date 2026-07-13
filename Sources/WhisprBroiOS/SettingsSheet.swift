import SwiftUI
import WhisprBroCore

/// Settings sheet: dictation language (English = fast Parakeet v2; it/es need
/// the multilingual v3, gated on it being installed), Auto-Clean level (same
/// UserDefaults keys as macOS), history toggle, and the privacy card.
struct SettingsSheet: View {
    @EnvironmentObject private var model: DictationModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DictationLanguage.storageKey) private var languageRaw = DictationLanguage.english.rawValue

    private var selectedLanguage: DictationLanguage {
        DictationLanguage(rawValue: languageRaw) ?? .english
    }

    var body: some View {
        NavigationStack {
            List {
                languageSection
                cleanupSection
                historySection
                privacySection
            }
            .scrollContentBackground(.hidden)
            .background(Brand.paper.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(Brand.sans(15, .semibold)).foregroundStyle(Brand.ink)
                }
            }
        }
    }

    // MARK: Language

    private var languageSection: some View {
        Section {
            ForEach(DictationLanguage.allCases, id: \.self) { lang in
                let installed = DictationModel.isInstalled(lang.parakeetVersion)
                Button {
                    languageRaw = lang.rawValue
                } label: {
                    row(
                        title: lang.displayName,
                        subtitle: lang == .english
                            ? "Fast Parakeet v2 (English only)"
                            : installed ? "Multilingual Parakeet v3"
                                        : "Multilingual Parakeet v3 — not installed",
                        selected: selectedLanguage == lang)
                }
                .disabled(!installed)
                .opacity(installed ? 1 : 0.4)
            }
        } header: {
            header("Dictation language")
        } footer: {
            footer("Italian & Spanish use the multilingual Parakeet v3 model, bundled "
                + "separately from the English build. Applies on next launch.")
        }
        .listRowBackground(Brand.raised)
    }

    // MARK: Auto-Clean

    private var cleanupSection: some View {
        Section {
            ForEach(AppConfig.Cleanup.Level.allCases, id: \.self) { level in
                Button {
                    model.cleanupLevel = level
                } label: {
                    row(
                        title: level.displayName,
                        subtitle: subtitle(for: level),
                        selected: model.cleanupLevel == level)
                }
            }
        } header: {
            header("Auto-Clean")
        } footer: {
            footer("Deterministic cleanup only on iOS for now — filler removal plus light "
                + "punctuation. On-device AI formatting arrives in a later phase.")
        }
        .listRowBackground(Brand.raised)
    }

    private func subtitle(for level: AppConfig.Cleanup.Level) -> String {
        switch level {
        case .verbatim: "Exactly what you said, dictionary only"
        case .fillers: "Strip \u{201C}um\u{201D}/\u{201C}uh\u{201D} + tidy punctuation"
        case .standard: "Same as Fillers on iOS (corrections need the AI stage)"
        }
    }

    // MARK: History

    private var historySection: some View {
        Section {
            Toggle(isOn: $model.historyEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save dictation history")
                        .font(Brand.sans(15)).foregroundStyle(Brand.ink)
                    Text("Kept in a local database on this device")
                        .font(Brand.sans(12)).foregroundStyle(Brand.mist)
                }
            }
            .tint(Brand.ink)
        } header: {
            header("History")
        }
        .listRowBackground(Brand.raised)
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 16)).foregroundStyle(Brand.ink)
                    Text("Zero network, by construction")
                        .font(Brand.sans(15, .semibold)).foregroundStyle(Brand.ink)
                }
                Text("The app binary contains no networking code — the same audited "
                    + "guarantee as whispr bro for Mac. Speech recognition, cleanup, and "
                    + "history all run on-device; your voice and transcripts never leave it.")
                    .font(Brand.sans(13)).foregroundStyle(Brand.bodyMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } header: {
            header("Privacy")
        }
        .listRowBackground(Brand.raised)
    }

    // MARK: Bits

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Brand.mono(10, .medium)).tracking(1).foregroundStyle(Brand.metaMuted)
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(Brand.sans(12)).foregroundStyle(Brand.mist)
    }

    private func row(title: String, subtitle: String, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Brand.sans(15)).foregroundStyle(Brand.ink)
                Text(subtitle).font(Brand.sans(12)).foregroundStyle(Brand.mist)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.ink)
            }
        }
        .contentShape(Rectangle())
    }
}
