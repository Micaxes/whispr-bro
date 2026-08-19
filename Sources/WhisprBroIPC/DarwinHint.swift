import Foundation

/// Tiny post/observe wrappers over the Darwin notification center — the HINT
/// channel of the `KeyboardIPC` contract (names in `KeyboardIPC.*HintName`).
/// CFNotificationCenter's Darwin center is plain cross-process signaling on
/// this device, no payload, no network surface. Hints coalesce, drop, and
/// never wake a suspended process — every use MUST pair with the file-backed
/// recovery path documented on the contract; nothing here carries state.
public enum DarwinHint {
    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true)
    }

    /// Registers `handler` for `name`; delivery is on the main run loop.
    /// Observation lives as long as the returned token — hold it, and drop it
    /// (or call `cancel()`) to stop observing.
    public static func observe(_ name: String, handler: @escaping () -> Void) -> DarwinHintToken {
        DarwinHintToken(name: name, handler: handler)
    }
}

/// Registration token for one Darwin hint observation. The token object is
/// itself the CFNotificationCenter observer pointer (passUnretained — the
/// token owns the registration, not the other way round, so `deinit` can
/// deregister).
public final class DarwinHintToken {
    fileprivate let handler: () -> Void
    private let name: String
    private var cancelled = false

    fileprivate init(name: String, handler: @escaping () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinHintToken>.fromOpaque(observer).takeUnretainedValue().handler()
            },
            name as CFString,
            nil,
            .deliverImmediately)
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil)
    }

    deinit {
        cancel()
    }
}
