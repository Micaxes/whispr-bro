import Foundation

/// "Rules only — no AI rewrite": the saved switch that takes the formatting
/// model out of dictation. With it on, a dictation is the deterministic path
/// alone — dictionary, self-repair rules, filler strip, spoken layout, the
/// rule-based cleanup — and the ~1 GB model is not in memory unless
/// something that needs it asks (Command Mode editing a selection), and then
/// only until that edit has landed.
///
/// **Why it exists.** Measured on the maintainer's dictations
/// (docs/self-repair.md §5), the rules fix 23 of 33 self-repairs with no
/// damage; the 1.5B formatter run after them fixed none of the other ten,
/// damaged 37 words in 3 dictations, and spent 0.47 s median (1.3 s at p90)
/// on each dictation it saw. Off by default: turning it on is his call, and
/// until he does nothing changes.
///
/// A live defaults toggle like `cleanupLevel` (not a `config.toml` key, so
/// the menu and the file cannot disagree). Every decision about the model
/// below is one `PipelineController` or `ModelResidency` acts on — neither
/// decides anything itself — so they are pinned here by test; the store is
/// injected so the tests never touch a real defaults domain.
public struct RulesOnlyMode {
    public static let storageKey = "rulesOnly"

    private let store: RulesOnlyStore

    /// The app's own defaults; a test passes an in-memory store.
    public init(store: RulesOnlyStore = UserDefaults.standard) {
        self.store = store
    }

    public init(defaults: UserDefaults) {
        self.init(store: defaults)
    }

    /// Off unless he turned it on.
    public var isOn: Bool {
        get { store.bool(forKey: Self.storageKey) }
        nonmutating set { store.set(newValue, forKey: Self.storageKey) }
    }

    // MARK: - When the model is in memory

    /// Bring-up loads the model only when it is installed and rules-only is
    /// off. With rules-only on it waits until something needs it.
    public static func loadsModelAtLaunch(rulesOnly: Bool, modelInstalled: Bool) -> Bool {
        modelInstalled && !rulesOnly
    }

    /// Whether a dictation at `level` reaches the model: never at the
    /// verbatim level (the whole stage is off), never in rules-only. The
    /// formatter stage loads the model on demand exactly when this is true.
    public static func dictationNeedsModel(rulesOnly: Bool, level: AppConfig.Cleanup.Level) -> Bool {
        !rulesOnly && level != .verbatim
    }

    /// What one Command Mode use does with the model.
    public enum Command: Equatable, Sendable {
        /// Nothing selected: the spoken words are a dictation, and reach the
        /// model only as a dictation does (`dictationNeedsModel`).
        case dictation
        /// Edit the selection with the model, loading it if it is not in
        /// memory, and keep it there.
        case edit
        /// Rules-only: edit the selection with the model, loaded for it, then
        /// free the model again once the edit has landed — the switch
        /// promises the memory back.
        case editThenUnload
    }

    public static func command(hasSelection: Bool, rulesOnly: Bool) -> Command {
        guard hasSelection else { return .dictation }
        return rulesOnly ? .editThenUnload : .edit
    }

    /// What flipping the switch queues on the model's serial chain
    /// (`ModelResidency`).
    public enum Transition: Equatable, Sendable {
        /// Turned on: free the model — queued every time, whether or not it
        /// is resident yet. A load still in flight (the switch was just
        /// turned off) finishes first and this frees what it loaded; with
        /// nothing resident by the time it runs, it does nothing. Deciding
        /// on residency here instead is the race that left the model in
        /// memory: flipped back on during the load, "not resident yet"
        /// queued nothing, and the load landed.
        case unloadModel
        /// Turned off with the model installed: load it in the background,
        /// so the next dictation does not pay for it. Does nothing if it is
        /// resident, or if the switch is back on, by the time it runs.
        case loadModel
        case none
    }

    public static func transition(toRulesOnly on: Bool, modelInstalled: Bool) -> Transition {
        if on { return .unloadModel }
        return modelInstalled ? .loadModel : .none
    }
}

/// Where `RulesOnlyMode` keeps the switch: `UserDefaults` in the app. (A
/// test's in-memory store leaves nothing behind; a throwaway `UserDefaults`
/// suite leaves its plist in ~/Library/Preferences even once emptied.)
public protocol RulesOnlyStore {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
}

extension UserDefaults: RulesOnlyStore {}
