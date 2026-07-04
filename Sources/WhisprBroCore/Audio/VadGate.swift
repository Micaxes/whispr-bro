import CoreML
import FluidAudio
import Foundation

/// Silero VAD (spec §4 VadGate) via FluidAudio's `VadManager`, loaded fully
/// offline: we hand it a pre-loaded `MLModel`, so it never touches
/// DownloadUtils / the network — no `enforceOffline` dependency, no path quirk.
///
/// Two jobs in task-008:
///  - **Auto-stop** (`feed`): streaming end-of-speech detection for hands-free
///    locked mode — returns `true` once the user has gone quiet for
///    `minSilenceDuration`.
///  - **Silence trim** (`trim`): drops only *leading and trailing* silence from
///    a finished utterance (slices between the first and last detected speech),
///    so interior quiet words are never lost and long dictation is never
///    force-split.
///
/// Beta in FluidAudio; a load failure is non-fatal — the pipeline runs without
/// VAD (no auto-stop, no trim) rather than refusing to transcribe.
public actor VadGate {
    /// 256ms @ 16kHz — the unified model's fixed chunk.
    public static let chunkSize = VadManager.chunkSize
    private static let sampleRate = 16_000

    private let modelFile: URL
    private let segConfig: VadSegmentationConfig
    private var manager: VadManager?

    // Streaming state for auto-stop, reset per utterance.
    private var streamState: VadStreamState?
    private var pending: [Float] = []
    /// Guards against actor reentrancy: `feed` awaits mid-drain, so a second
    /// `feed` could otherwise read/write `streamState` concurrently.
    private var draining = false

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

    // MARK: - Streaming auto-stop (hands-free locked mode)

    /// Begin a fresh streaming utterance. Safe to call even if VAD failed to
    /// load (auto-stop is then simply unavailable).
    public func beginStream() async {
        guard let manager else { return }
        streamState = await manager.makeStreamState()
        pending.removeAll(keepingCapacity: true)
        draining = false
    }

    /// Feed 16kHz mono samples captured so far; returns `true` once
    /// end-of-speech is detected. No-op (returns false) if VAD isn't loaded.
    /// Reentrancy-safe: overlapping calls buffer into `pending` and let the
    /// in-flight drain consume them.
    public func feed(_ samples: [Float]) async -> Bool {
        guard let manager, streamState != nil else { return false }
        pending.append(contentsOf: samples)
        guard !draining else { return false }
        draining = true
        defer { draining = false }

        var ended = false
        while pending.count >= Self.chunkSize {
            let chunk = Array(pending.prefix(Self.chunkSize))
            pending.removeFirst(Self.chunkSize)
            do {
                let result = try await manager.processStreamingChunk(
                    chunk, state: streamState!, config: segConfig)
                streamState = result.state
                if result.event?.kind == .speechEnd { ended = true }
            } catch {
                return false // degrade gracefully; caller keeps recording
            }
        }
        return ended
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
