import Collections
import Foundation

/// Continuously-fed sample buffer with a bounded pre-roll (spec §4 AudioEngine).
///
/// While idle it keeps only the most recent `preRollSampleCount` samples, so
/// speech that starts just *before* the hotkey press is not lost. When an
/// utterance begins, the pre-roll is spliced onto the front of the utterance
/// and all subsequent samples accumulate until `endUtterance()`.
///
/// Thread-safe: `append` is called from the audio render thread; begin/end
/// from the main thread.
public final class PreRollBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var preRoll: Deque<Float>
    private var utterance: [Float] = []
    private var capturingUtterance = false
    /// How much of the current utterance has been handed to `drainNewSamples`,
    /// so streaming VAD can consume the tail incrementally without ending it.
    private var drainedCount = 0

    public let preRollSampleCount: Int

    public init(preRollSampleCount: Int) {
        self.preRollSampleCount = preRollSampleCount
        self.preRoll = Deque(minimumCapacity: preRollSampleCount)
    }

    public func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        if capturingUtterance {
            utterance.append(contentsOf: samples)
        } else {
            preRoll.append(contentsOf: samples)
            let overflow = preRoll.count - preRollSampleCount
            if overflow > 0 {
                preRoll.removeFirst(overflow)
            }
        }
    }

    /// Snapshot the pre-roll as the start of a new utterance and switch to
    /// accumulation mode.
    public func beginUtterance() {
        lock.lock()
        defer { lock.unlock() }
        utterance = Array(preRoll)
        preRoll.removeAll(keepingCapacity: true)
        capturingUtterance = true
        drainedCount = 0
    }

    /// Utterance samples appended since the last call (or since
    /// `beginUtterance`) — for feeding streaming VAD without ending the
    /// utterance. Empty when not capturing.
    public func drainNewSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard capturingUtterance, utterance.count > drainedCount else { return [] }
        let tail = Array(utterance[drainedCount...])
        drainedCount = utterance.count
        return tail
    }

    /// Stop accumulating and return the full utterance (pre-roll + held audio).
    public func endUtterance() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        capturingUtterance = false
        drainedCount = 0
        let result = utterance
        utterance = []
        return result
    }

    public var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return capturingUtterance
    }
}
