import SwiftUI
import WhisprBroCore

/// Preferences window (spec §11.7), rebuilt to the brand "App UI" mockup (design
/// §6f): a cream window with an echo-w title bar, a left tab rail with an
/// "offline" card, and branded radio rows / cards. All bindings are unchanged
/// from the previous Form-based version.
struct SettingsView: View {
    @ObservedObject var pipeline: PipelineController
    @ObservedObject var models: ModelStatusModel
    /// Which settings sub-section to show (driven by the unified window sidebar).
    let tab: Tab
    @AppStorage("asrEngineKind") private var asrKindRaw = AsrEngineKind.parakeet.rawValue
    @AppStorage(DictationLanguage.storageKey) private var languageRaw = DictationLanguage.english.rawValue
    @AppStorage(AppIconVariant.storageKey) private var iconVariantRaw = AppIconVariant.dark.rawValue
    @AppStorage(MicrophoneManager.storageKey) private var micUIDRaw = ""
    @AppStorage(AppLanguage.storageKey) private var appLangRaw = AppLanguage.system.rawValue
    @ObservedObject private var update = UpdateModel.shared
    @State private var micDevices: [AudioInputDevice] = []
    @State private var showShortcuts = false

    enum Tab: String, CaseIterable, Hashable { case general, models, autoClean, performance, privacy, appearance
        var title: String {
            switch self {
            case .general: "General"
            case .models: "Models"
            case .autoClean: "Auto-Clean"
            case .performance: "Performance"
            case .privacy: "Privacy"
            case .appearance: "Appearance"
            }
        }
    }

    /// The detail pane for one settings sub-section (the sidebar owns navigation).
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch tab {
                case .general: generalContent
                case .models: modelsContent
                case .autoClean: autoCleanContent
                case .performance: performanceContent
                case .privacy: privacyContent
                case .appearance: appearanceContent
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Brand.raised)
        .onAppear { micDevices = MicrophoneManager.inputDevices() }
    }

    // MARK: General

    @ViewBuilder private var generalContent: some View {
        section("Keyboard shortcuts") {
            BrandCard {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keyboard shortcuts").font(Brand.sans(14, .medium)).foregroundStyle(Brand.ink)
                        Text("Dictate, hands-free, command mode, cancel, paste/copy last.")
                            .font(Brand.sans(12)).foregroundStyle(Brand.bodyMuted)
                    }
                    Spacer()
                    Button("Edit…") { showShortcuts = true }
                        .buttonStyle(.plain).font(Brand.sans(12, .medium)).foregroundStyle(Brand.ink)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.raised))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.ink.opacity(0.16), lineWidth: 1))
                        .popover(isPresented: $showShortcuts, arrowEdge: .trailing) {
                            ShortcutsSettingsView(pipeline: pipeline)
                                .padding(20).frame(width: 470).background(Brand.raised)
                        }
                }
            }
        }

        section("Microphone") {
            BrandRadioRow(title: "System default", selected: micUIDRaw.isEmpty) { micUIDRaw = "" }
            ForEach(micDevices) { dev in
                BrandRadioRow(title: dev.name, selected: micUIDRaw == dev.uid) { micUIDRaw = dev.uid }
            }
            BrandCaption("Which input device to record from. Applies on your next dictation.")
        }

        section("Dictation language") {
            ForEach(DictationLanguage.allCases, id: \.self) { lang in
                BrandRadioRow(
                    title: lang.displayName,
                    subtitle: lang == .english ? "Fast Parakeet v2 (English only)" : "Multilingual Parakeet v3",
                    selected: (DictationLanguage(rawValue: languageRaw) ?? .english) == lang
                ) { languageRaw = lang.rawValue }
            }
            BrandCaption(languageNote)
        }

        section("App language") {
            ForEach(AppLanguage.allCases) { lang in
                BrandRadioRow(title: lang.displayName, selected: appLangRaw == lang.rawValue) {
                    appLangRaw = lang.rawValue
                    lang.apply()
                }
            }
            BrandCaption("Your preferred language for the app interface. Restart to apply — the UI isn't fully translated yet, so this mainly affects system text and formatting.")
        }

        section("Software update") {
            BrandCard {
                Toggle(isOn: Binding(get: { update.autoCheckEnabled }, set: { update.setAutoCheck($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for updates automatically").font(Brand.sans(14)).foregroundStyle(Brand.ink)
                        Text("Once a day, in the background.").font(Brand.sans(12)).foregroundStyle(Brand.bodyMuted)
                    }
                }
                .toggleStyle(.switch).tint(Brand.ink)

                Rectangle().fill(Brand.ink.opacity(0.06)).frame(height: 1)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current version").font(Brand.sans(12)).foregroundStyle(Brand.bodyMuted)
                        Text(updateVersionLine).font(Brand.mono(13)).foregroundStyle(Brand.ink)
                    }
                    Spacer()
                    if case .available = update.availability {
                        Button("View release") { update.openReleasePage() }
                            .buttonStyle(.plain).font(Brand.sans(12, .semibold)).foregroundStyle(Brand.paper)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.ink))
                    }
                    Button(update.isChecking ? "Checking…" : "Check now") { update.checkNow() }
                        .buttonStyle(.plain).font(Brand.sans(12, .medium)).foregroundStyle(Brand.ink)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.raised))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.ink.opacity(0.16), lineWidth: 1))
                        .disabled(update.isChecking)
                }
            }
            BrandCaption("On by default. whispr·bro's app contains zero networking code — when this is on, a separate helper process contacts GitHub once a day just to read the latest release tag. Your audio and transcripts never leave this Mac. New versions download in your browser. Turn it off here to make zero network connections.")
        }
    }

    private var updateVersionLine: String {
        switch update.availability {
        case .available(let tag, _): "\(update.currentVersion)  ·  \(tag) available"
        case .upToDate: "\(update.currentVersion)  ·  up to date"
        case .unknown: update.currentVersion
        }
    }

    // MARK: Models

    @ViewBuilder private var modelsContent: some View {
        section("Formatting model") {
            ForEach(LlmCatalog.all, id: \.key) { spec in
                BrandRadioRow(
                    title: spec.isInstalled ? spec.displayName : "\(spec.displayName) — not installed",
                    subtitle: llmSubtitle(spec.key),
                    selected: pipeline.llmModelKey == spec.key,
                    enabled: spec.isInstalled
                ) { pipeline.selectLLM(key: spec.key) }
            }
            BrandCaption("Only installed models can be selected. Qwen2.5 1.5B is the measured default.")
        }

        section("Speech-recognition engine") {
            ForEach(AsrEngineKind.allCases, id: \.self) { kind in
                BrandRadioRow(
                    title: kind.displayName,
                    selected: (AsrEngineKind(rawValue: asrKindRaw) ?? .parakeet) == kind
                ) { asrKindRaw = kind.rawValue }
            }
            BrandCaption(asrEngineNote)
        }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BrandSectionLabel("Installed model integrity")
                Spacer()
                Button(models.verifying ? "Verifying…" : "Verify on disk") {
                    Task { await models.refresh() }
                }
                .buttonStyle(.plain)
                .font(Brand.sans(12, .medium))
                .foregroundStyle(Brand.ink)
                .disabled(models.verifying)
            }
            BrandCard {
                ForEach(Array(models.groups.enumerated()), id: \.element.id) { i, g in
                    if i > 0 { Rectangle().fill(Brand.ink.opacity(0.06)).frame(height: 1) }
                    integrityRow(g)
                }
                if models.groups.isEmpty {
                    BrandCaption("Run scripts/fetch-models.sh to install models.")
                }
            }
            BrandCaption("Re-hashes every model file against the checked-in sha256 manifest.")
        }
    }

    private func integrityRow(_ g: ModelManager.GroupStatus) -> some View {
        // Neutral only for a cleanly absent OPTIONAL set. Anything else that
        // isn't verified — including a partial/corrupt install that reads as
        // "not installed" — is a fault the row must not soften.
        let absentOptional = g.optional && g.isCleanlyAbsent
        return HStack(spacing: 10) {
            ZStack {
                Circle().fill(g.isVerified ? Brand.ink : (absentOptional ? Brand.mist : Brand.signal))
                Image(systemName: g.isVerified ? "checkmark" : (absentOptional ? "minus" : "exclamationmark"))
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.paper)
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.displayName).font(Brand.sans(13, .medium)).foregroundStyle(Brand.ink)
                Text(g.summary).font(Brand.mono(11.5)).foregroundStyle(Brand.mist)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: Auto-Clean

    @ViewBuilder private var autoCleanContent: some View {
        section("Auto-Clean level") {
            ForEach(AppConfig.Cleanup.Level.allCases, id: \.self) { level in
                BrandRadioRow(
                    title: level.displayName,
                    subtitle: cleanupSubtitle(level),
                    selected: pipeline.cleanupLevel == level
                ) { pipeline.cleanupLevel = level }
            }
        }
        section("How corrections work") {
            BrandCaption("“Standard” resolves self-corrections: say “meet at 2, actually 3” and only “meet at 3” is kept. If unsure, it keeps both. It never changes facts, numbers, or names. In code editors, terminals, and notes, filler removal and self-correction are skipped.")
        }
        section("Atypical speech") {
            BrandCaption("If you stutter, dictate in a second language, or want repetitions kept, set the level to “Off (verbatim)” — nothing is removed.")
        }
    }

    // MARK: Performance

    @ViewBuilder private var performanceContent: some View {
        section("Idle LLM unload") {
            BrandCard {
                Toggle(isOn: $pipeline.idleUnloadEnabled) {
                    Text("Unload the formatting model when idle").font(Brand.sans(14)).foregroundStyle(Brand.ink)
                }
                .toggleStyle(.switch).tint(Brand.ink)
                Rectangle().fill(Brand.ink.opacity(0.06)).frame(height: 1)
                Stepper(value: $pipeline.idleUnloadMinutes, in: 1...60) {
                    Text("After \(pipeline.idleUnloadMinutes) min idle").font(Brand.sans(14)).foregroundStyle(Brand.ink)
                }
                .disabled(!pipeline.idleUnloadEnabled)
            }
            BrandCaption("Frees ~1GB of memory after the model sits unused. The next dictation reloads it (~1–2s once).")
        }
    }

    // MARK: Privacy

    @ViewBuilder private var privacyContent: some View {
        section("History") {
            BrandCard {
                Toggle(isOn: $pipeline.historyEnabled) {
                    Text("Save dictation history").font(Brand.sans(14)).foregroundStyle(Brand.ink)
                }
                .toggleStyle(.switch).tint(Brand.ink)
            }
            BrandCaption("When off, dictations are inserted but never written to the local history database.")
        }
        section("Offline") {
            BrandCard {
                HStack(spacing: 8) {
                    Circle().fill(Brand.ink).frame(width: 7, height: 7)
                    Text("Your audio & transcripts never leave this Mac — no telemetry.")
                        .font(Brand.sans(14)).foregroundStyle(Brand.ink)
                }
                BrandCaption("The app binary contains zero networking code — enforced three ways: a CI symbol audit, a runtime connect() tripwire, and a tcpdump zero-packet capture over a dictation cycle. The one exception is the optional updater (a separate helper, on by default) that checks GitHub once a day — turn it off in General to make zero network connections. See docs/OFFLINE.md for the Little Snitch / LuLu deny-all rule.")
            }
        }
    }

    // MARK: Appearance

    @ViewBuilder private var appearanceContent: some View {
        section("App icon") {
            ForEach(AppIconVariant.allCases, id: \.self) { variant in
                iconRow(variant)
            }
            BrandCaption("Switches the live Dock icon (visible while a window like this one is open). The Finder icon is set when the app is built (default Dark; run WHISPR_ICON=cream scripts/make-app.sh to change it).")
        }
    }

    private func iconRow(_ variant: AppIconVariant) -> some View {
        let selected = iconVariantRaw == variant.rawValue
        return Button {
            iconVariantRaw = variant.rawValue
            variant.applyToDock()
        } label: {
            HStack(spacing: 14) {
                iconPreview(variant).frame(width: 46, height: 46)
                Text(variant.displayName).font(Brand.sans(14, .semibold)).foregroundStyle(Brand.ink)
                Spacer()
                Circle()
                    .strokeBorder(selected ? Brand.ink : Color(hex: 0xB7AC94), lineWidth: selected ? 5 : 1.5)
                    .background(Circle().fill(Brand.paper))
                    .frame(width: 17, height: 17)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? Brand.paper : Brand.raised))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Brand.ink : Brand.ink.opacity(0.10), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private func iconPreview(_ variant: AppIconVariant) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(
                    colors: variant == .dark ? [Color(hex: 0x221D16), Color(hex: 0x100D09)]
                                             : [Color(hex: 0xFBF8F1), Color(hex: 0xEADFC9)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            EchoWMark(color: variant == .dark ? Brand.paper : Brand.ink).frame(width: 26, height: 17)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Brand.ink.opacity(variant == .cream ? 0.10 : 0), lineWidth: 1))
    }

    // MARK: Helpers

    @ViewBuilder private func section(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BrandSectionLabel(label)
            content()
        }
    }

    private func llmSubtitle(_ key: String) -> String {
        switch key {
        case "qwen2_5_1_5b": "Measured default · Metal"
        case "qwen3_1_7b": "Higher quality · best on Pro/Max"
        case "llama3_2_1b": "1B · fastest, lower quality"
        default: "GGUF · llama.cpp"
        }
    }

    private func cleanupSubtitle(_ level: AppConfig.Cleanup.Level) -> String {
        switch level {
        case .verbatim: "Nothing removed — exactly what you said."
        case .fillers: "Removes fillers (um, uh, er) only. Safe default."
        case .standard: "Fillers + self-correction resolution (opt-in)."
        }
    }

    private var languageNote: String {
        (DictationLanguage(rawValue: languageRaw) ?? .english) == .english
            ? "English uses the fast Parakeet v2 model. Language changes apply on next launch."
            : "Italian & Spanish use the multilingual Parakeet v3 model — install it with scripts/fetch-models.sh. Applies on next launch."
    }

    private var asrEngineNote: String {
        (AsrEngineKind(rawValue: asrKindRaw) ?? .parakeet) == .whisperCpp
            ? "whisper.cpp isn't bundled in this build — the app stays on Parakeet. Applies on next launch."
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
