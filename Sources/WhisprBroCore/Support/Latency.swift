import Foundation

/// Per-stage timings for one dictation, in seconds (spec §5). Written to every
/// history row from task-012 on; printed by whispr-bench and the app log today.
public struct StageTimings: Sendable, CustomStringConvertible {
    public var audioFinalizeSeconds: Double = 0
    public var asrSeconds: Double = 0
    public var formatSeconds: Double = 0
    public var insertSeconds: Double = 0

    public var totalSeconds: Double {
        audioFinalizeSeconds + asrSeconds + formatSeconds + insertSeconds
    }

    public init() {}

    public var description: String {
        String(
            format: "audio %.1fms | asr %.1fms | format %.1fms | insert %.1fms | total %.1fms",
            audioFinalizeSeconds * 1000, asrSeconds * 1000, formatSeconds * 1000,
            insertSeconds * 1000, totalSeconds * 1000
        )
    }
}

extension Duration {
    /// The one place the attoseconds conversion lives — every timing path
    /// (async, sync, and callback-based) goes through this.
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Run `body` and return its result plus wall-clock duration in seconds.
public func measured<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
    let clock = ContinuousClock()
    let start = clock.now
    let result = try await body()
    return (result, (clock.now - start).seconds)
}

/// Synchronous variant of `measured`.
public func measuredSync<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let clock = ContinuousClock()
    let start = clock.now
    let result = try body()
    return (result, (clock.now - start).seconds)
}
