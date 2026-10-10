import CoreML
import FluidAudio
import Foundation

/// Silero VAD (spec §4 VadGate) via FluidAudio's `VadManager`, loaded fully
/// offline: we hand it a pre-loaded `MLModel`, so it never touches
/// DownloadUtils / the network — no `enforceOffline` dependency, no path quirk.
///
/// One job: **silence trim** (`trim`) — drop only *leading and trailing*
/// silence from a finished utterance (slice between the first and last
/// detected speech), so interior quiet words are never lost and long dictation
/// is never force-split.
///
/// It deliberately does NOT decide when a dictation is over. The streaming
/// end-of-speech detector that used to auto-stop hands-free mode was removed
/// (see git history): a pause is not evidence that the speaker is done, and
/// hands-free now ends only when he presses the key again.
///
/// Beta in FluidAudio; a load failure is non-fatal — the pipeline runs without
/// VAD (no trim) rather than refusing to transcribe.
public actor VadGate {
    private static let sampleRate = 16_000

    private let modelFile: URL
    private let segConfig: VadSegmentationConfig
    private var manager: VadManager?

    public init(modelFile: URL, minSilenceDuration: Double = 0.8) {
        self.modelFile = modelFile
        // maxSpeechDuration = .infinity: never force-split continuous dictation
        // (the default 14s split would drop speech at the boundary).
        self.segConfig = VadSegmentationConfig(
            minSilenceDuration: minSilenceDuration,
            maxSpeechDuration: .infinity
        )
    }

    public var isLoaded: Bool { manager != nil }

    public func load() throws {
        guard manager == nil else { return }
        guard FileManager.default.fileExists(atPath: modelFile.path) else {
            throw WhisprError.modelsNotFound(modelFile)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: modelFile, configuration: config)
        // 0.6 catches soft dictation onset better than the 0.85 default.
        manager = VadManager(config: VadConfig(defaultThreshold: 0.6), vadModel: model)
    }

    // MARK: - Silence trim (finished utterance)

    /// Slice off leading/trailing silence: keep everything between the first
    /// detected speech onset and the last speech offset, so no interior audio
    /// is ever dropped. Returns the input unchanged if VAD is unavailable,
    /// errors, or finds no speech.
    public func trim(_ samples: [Float]) async -> [Float] {
        guard let manager, !samples.isEmpty else { return samples }
        do {
            let segments = try await manager.segmentSpeech(samples, config: segConfig)
            guard let first = segments.first, let last = segments.last else { return samples }
            let start = max(0, first.startSample(sampleRate: Self.sampleRate))
            let end = min(samples.count, last.endSample(sampleRate: Self.sampleRate))
            guard end > start else { return samples }
            return Array(samples[start..<end])
        } catch {
            return samples
        }
    }
}
