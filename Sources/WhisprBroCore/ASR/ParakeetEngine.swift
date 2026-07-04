import FluidAudio
import Foundation

/// Parakeet-tdt-0.6b-v2 via FluidAudio CoreML, ANE-pinned (spec §4, §6).
///
/// Models load strictly from `<modelsDir>/parakeet-tdt-0.6b-v2/` — the folder
/// name is load-bearing (FluidAudio resolves `parent/<repo.folderName>`), and
/// `DownloadUtils.enforceOffline` hard-blocks FluidAudio's fallback HF
/// download, so a missing file throws instead of touching the network.
///
/// v2 requires `TdtConfig(blankId: 1024)`; the library default is v3-tuned
/// (blankId 8192) and silently wrecks decoding if used with v2 models.
public actor ParakeetEngine: AsrEngine {
    public static let modelFolderName = "parakeet-tdt-0.6b-v2"

    /// FluidAudio hard-rejects audio under ~300ms (ASRConstants).
    public nonisolated let minimumSamples =
        ASRConstants.minimumRequiredSamples(forSampleRate: Int(AudioEngine.targetSampleRate))

    private let modelDir: URL
    private var manager: AsrManager?
    private var decoderLayers = 2

    public init(modelsDir: URL) {
        self.modelDir = modelsDir.appendingPathComponent(Self.modelFolderName, isDirectory: true)
    }

    public var isLoaded: Bool { manager != nil }

    public func load() async throws {
        guard manager == nil else { return }

        DownloadUtils.enforceOffline = true

        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw WhisprError.modelsNotFound(modelDir)
        }

        let models = try await AsrModels.load(from: modelDir, version: .v2)
        let config = ASRConfig(tdtConfig: TdtConfig(blankId: AsrModelVersion.v2.blankId))
        let manager = AsrManager(config: config, models: models)
        self.manager = manager
        self.decoderLayers = await manager.decoderLayerCount

        // Warm-up: the first inference after load pays CoreML/ANE kernel
        // setup; spend it on silence so the first real dictation is fast.
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let silence = [Float](repeating: 0, count: max(minimumSamples, 8_000))
        _ = try? await manager.transcribe(silence, decoderState: &state)
    }

    public func transcribe(_ samples: [Float]) async throws -> AsrResult {
        guard let manager else {
            throw WhisprError.modelsNotFound(modelDir)
        }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return AsrResult(
            text: result.text,
            modelProcessingSeconds: result.processingTime
        )
    }
}
