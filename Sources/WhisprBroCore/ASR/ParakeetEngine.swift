import FluidAudio
import Foundation

/// Parakeet-tdt via FluidAudio CoreML, ANE-pinned (spec §4, §6).
///
/// Two model versions: **v2** (English-only, fast) is the default; **v3**
/// (25 European languages incl. Italian/Spanish, auto-detecting) serves the
/// non-English languages. Models load strictly from
/// `<modelsDir>/parakeet-tdt-0.6b-v{2,3}/` — the folder name is load-bearing
/// (FluidAudio resolves `parent/<repo.folderName>`, stripping the `-coreml`
/// suffix), and `DownloadUtils.enforceOffline` hard-blocks FluidAudio's fallback
/// HF download, so a missing file throws instead of touching the network.
///
/// The blankId is version-specific and load-bearing: v2 requires 1024, v3
/// requires 8192 (the library default). Mixing them silently wrecks decoding.
public actor ParakeetEngine: AsrEngine {
    /// Selectable Parakeet model version. Maps to a local folder + FluidAudio
    /// model version + blankId (all three must agree, per the header warning).
    public enum Version: Sendable {
        case v2   // English-only, ~0.19s
        case v3   // 25 European languages, auto-detecting

        public var folderName: String {
            switch self {
            case .v2: return "parakeet-tdt-0.6b-v2"
            case .v3: return "parakeet-tdt-0.6b-v3"
            }
        }
        var fluid: AsrModelVersion {
            switch self {
            case .v2: return .v2
            case .v3: return .v3
            }
        }
    }

    /// Back-compat: the English v2 folder name (callers that predate the
    /// multilingual selection, e.g. the bench harness).
    public static let modelFolderName = Version.v2.folderName
    public static func folderName(for version: Version) -> String { version.folderName }

    /// FluidAudio hard-rejects audio under ~300ms (ASRConstants).
    public nonisolated let minimumSamples =
        ASRConstants.minimumRequiredSamples(forSampleRate: Int(AudioEngine.targetSampleRate))

    private let version: Version
    private let modelDir: URL
    private var manager: AsrManager?
    private var decoderLayers = 2

    public init(modelsDir: URL, version: Version = .v2) {
        self.version = version
        self.modelDir = modelsDir.appendingPathComponent(version.folderName, isDirectory: true)
    }

    public var isLoaded: Bool { manager != nil }

    public func load() async throws {
        guard manager == nil else { return }

        DownloadUtils.enforceOffline = true

        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw WhisprError.modelsNotFound(modelDir)
        }

        // v3 auto-detects language per utterance (no `language:` param needed)
        // and uses the int8 encoder + JointDecisionv3 by default.
        let models = try await AsrModels.load(from: modelDir, version: version.fluid)
        let config = ASRConfig(tdtConfig: TdtConfig(blankId: version.fluid.blankId))
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
