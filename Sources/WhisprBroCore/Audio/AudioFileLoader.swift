import FluidAudio
import Foundation

/// Loads any audio file (wav/aiff/m4a/…) as 16kHz mono Float32, for
/// whispr-bench fixtures and the future LatencyHarness.
///
/// Delegates to FluidAudio's `AudioConverter` — the same tested resample path
/// the ASR library uses itself (chunked reads, proper multi-channel downmix)
/// — rather than hand-rolling a second converter dance to drift out of sync.
public enum AudioFileLoader {
    public static func loadSamples16k(_ url: URL) throws -> [Float] {
        do {
            return try AudioConverter().resampleAudioFile(url)
        } catch {
            throw WhisprError.audioFileUnreadable(url)
        }
    }
}
