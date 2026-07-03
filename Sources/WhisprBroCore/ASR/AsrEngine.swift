import Foundation

public struct AsrResult: Sendable {
    public let text: String
    /// The engine's own measure of model inference time (FluidAudio's
    /// `processingTime`), excluding actor hops and buffer copies. Callers'
    /// wall-clock measurements should be cross-checked against this.
    public let modelProcessingSeconds: Double?

    public init(text: String, modelProcessingSeconds: Double? = nil) {
        self.text = text
        self.modelProcessingSeconds = modelProcessingSeconds
    }
}

/// Engine-agnostic ASR interface (spec §4 Transcriber). Parakeet via
/// FluidAudio is the primary implementation; whisper.cpp large-v3-turbo
/// arrives as a fallback slot in task-013.
public protocol AsrEngine: AnyObject, Sendable {
    /// Shortest input the engine accepts, in samples at 16kHz. Callers must
    /// silently drop (not error on) shorter utterances — different engines
    /// have different floors, and the constraint lives here, not in callers.
    var minimumSamples: Int { get }

    var isLoaded: Bool { get async }

    /// Load models from the local models directory. Never touches the network.
    func load() async throws

    /// Transcribe 16kHz mono Float32 samples.
    func transcribe(_ samples: [Float]) async throws -> AsrResult
}
