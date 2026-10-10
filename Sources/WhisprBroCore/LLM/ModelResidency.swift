import Foundation

/// What `ModelResidency` needs from the app: the model itself, and the state
/// each op reads when it RUNS — not when it was queued.
@MainActor
public protocol ModelResidencyHost: AnyObject {
    /// "Rules only — no AI rewrite" (`RulesOnlyMode`), as it is now.
    var rulesOnly: Bool { get }
    /// Nothing is using the model right now: no dictation, no command.
    var modelIsIdle: Bool { get }
    /// The model file is on disk.
    var modelIsInstalled: Bool { get }
    /// The model can be used: it loaded, or it is on disk waiting for
    /// rules-only to be turned off. False once a load has failed.
    var modelIsAvailable: Bool { get }
    /// Load the model into memory (~1–2 s).
    func loadModel() async throws
    /// Free it.
    func unloadModel() async
    /// A load ended: nil when it worked, else why not.
    func modelDidLoad(failure: Error?)
    /// The model was freed for rules-only.
    func modelDidUnloadForRulesOnly()
}

/// When the formatting model is in memory. Every load and unload of it —
/// on demand for a dictation or a command, for "Rules only", for the idle
/// timeout, for a model swap — runs on ONE serial chain, in the order it was
/// asked for: none can interleave with another, none can overtake one queued
/// before it, and each reads the state it acts on when it runs.
///
/// **The race the chain closes.** A load takes 1–2 s. Turn rules-only off
/// and a load is queued; turn it back on while that load is still running
/// and the model is not resident yet — so "free the resident model" used to
/// find nothing to free, and the load then landed with rules-only on,
/// leaving ~1 GB in memory for the session. Now a flip to on always queues
/// the unload: it runs after the load in flight and frees what it loaded,
/// and with nothing resident it does nothing. A flip to off queues the load,
/// which does nothing if the switch is back on by the time it runs.
///
/// The app (`PipelineController`) owns the engine and its state and acts
/// through `ModelResidencyHost`; this type owns the order. Pinned by test
/// with a host whose load can be held in flight (`ModelResidencyTests`).
@MainActor
public final class ModelResidency {
    /// An installed model that is out of memory — unloaded for idle, or left
    /// out by rules-only: the next use that needs it loads it. (Never set for
    /// a model that is not installed or failed to load.)
    public var isUnloaded = false
    /// Teardown has begun: every op still queued, and any queued later, does
    /// nothing — none may reload the model after shutdown freed it.
    public private(set) var isShuttingDown = false

    private weak var host: ModelResidencyHost?
    private let busyRetry: Duration
    private var tail: Task<Void, Never> = Task {}
    private var queued = 0

    /// - Parameter busyRetry: how long a rules-only unload that found the
    ///   model in use waits before it asks again.
    public init(host: ModelResidencyHost, busyRetry: Duration = .seconds(2)) {
        self.host = host
        self.busyRetry = busyRetry
    }

    /// Run `op` once every op queued before it has finished.
    @discardableResult
    public func serial(_ op: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous.value
            await op()
        }
        tail = task
        queued += 1
        return task
    }

    /// Wait until every op queued so far — and every op those queued — has
    /// finished. (A busy unload's retry is queued later, by a timer.)
    public func drain() async {
        while true {
            let seen = queued
            await tail.value
            if seen == queued { return }
        }
    }

    /// Latch teardown, then wait for the op in flight to finish.
    public func shutDown() async {
        isShuttingDown = true
        await drain()
    }

    /// Load the model if an installed one is out of memory: for a dictation
    /// or a command, which awaits it — behind anything queued before.
    public func ensureLoaded() async {
        await serial { await self.load(unlessRulesOnly: false) }.value
    }

    /// "Rules only" was flipped (`RulesOnlyMode.transition`). On: the unload
    /// is queued — always, behind a load still in flight. Off: the load is
    /// queued in the background, so the next dictation does not wait for it.
    public func rulesOnlyChanged(to on: Bool) {
        guard let host else { return }
        switch RulesOnlyMode.transition(toRulesOnly: on, modelInstalled: host.modelIsInstalled) {
        case .unloadModel: unloadForRulesOnly()
        case .loadModel: serial { await self.load(unlessRulesOnly: true) }
        case .none: break
        }
    }

    /// Free the model for rules-only — never under a dictation or a command
    /// that is using it: then ask again `busyRetry` later. Command Mode in
    /// rules-only calls it once its edit has landed.
    @discardableResult
    public func unloadForRulesOnly() -> Task<Void, Never> {
        serial {
            guard let host = self.host, !self.isShuttingDown, host.rulesOnly,
                  host.modelIsAvailable, !self.isUnloaded else { return }
            guard host.modelIsIdle else {
                let wait = self.busyRetry
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: wait)
                    self?.unloadForRulesOnly()
                }
                return
            }
            // Set before the await: an op queued behind this one sees the
            // model as out and loads it again if it needs it.
            self.isUnloaded = true
            await host.unloadModel()
            host.modelDidUnloadForRulesOnly()
        }
    }

    private func load(unlessRulesOnly: Bool) async {
        guard let host, !isShuttingDown, isUnloaded, host.modelIsInstalled else { return }
        // The background load for rules-only off: the switch is back on.
        if unlessRulesOnly, host.rulesOnly { return }
        do {
            try await host.loadModel()
            isUnloaded = false
            host.modelDidLoad(failure: nil)
        } catch {
            host.modelDidLoad(failure: error)
        }
    }
}
