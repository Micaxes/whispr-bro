import Foundation
import os.log

/// The fallback ASR engine slot (spec §11.7, §12 risk table). Parakeet is the
/// primary engine — English-only and fast; whisper.cpp large-v3-turbo is the
/// honest escape hatch for multilingual / hard audio, at the cost of the 700ms
/// budget ("honest UI toggle: breaks 700ms").
///
/// The engine-agnostic `AsrEngine` protocol is the slot; this type fills it.
/// The whisper.cpp Metal xcframework + GGML model are NOT bundled by default
/// (they'd add a second native build and a ~1GB download to every install), so
/// unless a user has installed them this engine reports `isInstalled == false`
/// and `load()` throws a clear, actionable error — at which point the pipeline
/// stays on Parakeet. Wiring the real whisper.cpp C API in behind this seam is
/// a self-contained follow-up: build the framework (mirroring
/// build-llama-xcframework.sh), fetch the model, and implement `transcribe`.
public final class WhisperCppEngine: AsrEngine, @unchecked Sendable {
    private let modelFile: URL
    private let log = Logger(subsystem: "com.micaxes.whispr-bro", category: "asr.whisper")
    private var loaded = false

    public init(modelFile: URL = Paths.whisperModelFile) {
        self.modelFile = modelFile
    }

    /// whisper large-v3-turbo needs ~1s of audio to be worth invoking; matches
    /// Parakeet's floor so callers can swap engines without changing their guard.
    public nonisolated let minimumSamples = 16_000

    public var isLoaded: Bool { get async { loaded } }

    /// Whether this engine can actually run. FALSE in this build regardless of
    /// the model file, because the whisper.cpp framework is not linked yet —
    /// so `makeSelectedEngine` never selects a non-functional engine and bricks
    /// ASR. When the framework is wired in, gate this on the model file existing:
    ///   `whisperFrameworkLinked && FileManager.default.fileExists(atPath: modelFile.path)`
    public nonisolated var isInstalled: Bool { false }

    public func load() async throws {
        guard isInstalled else {
            // Not an error in normal operation — the pipeline treats a failed
            // fallback-engine load as "stay on Parakeet".
            log.info("whisper.cpp model not installed at \(self.modelFile.path, privacy: .public); staying on Parakeet")
            throw WhisprError.modelsNotFound(modelFile)
        }
        // The whisper.cpp framework is not linked in this build; even with the
        // model present the engine can't run yet. Fail loudly so it's never
        // silently selected as if functional.
        log.error("whisper.cpp engine selected but the whisper.cpp framework is not bundled in this build")
        throw WhisprError.modelLoadFailed(modelFile)
    }

    public func transcribe(_ samples: [Float]) async throws -> AsrResult {
        throw WhisprError.modelLoadFailed(modelFile)
    }
}

/// Which ASR engine the pipeline uses. Parakeet is the default and only fully
/// functional engine; `.whisperCpp` is the fallback slot (see WhisperCppEngine).
public enum AsrEngineKind: String, CaseIterable, Sendable {
    case parakeet
    case whisperCpp

    public var displayName: String {
        switch self {
        case .parakeet: "Parakeet (fast, English)"
        case .whisperCpp: "whisper.cpp large-v3-turbo (fallback — slower)"
        }
    }

    private static let key = "asrEngineKind"

    /// The persisted selection (defaults to Parakeet).
    public static var selected: AsrEngineKind {
        get { UserDefaults.standard.string(forKey: key).flatMap(AsrEngineKind.init) ?? .parakeet }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Build the engine for the selected kind, falling back to Parakeet when the
    /// chosen fallback engine isn't installed. Applied at startup (see
    /// PipelineController) — switching engines takes effect on next launch.
    @MainActor public static func makeSelectedEngine() -> AsrEngine {
        switch selected {
        case .parakeet:
            return ParakeetEngine(modelsDir: Paths.modelsDir)
        case .whisperCpp:
            let whisper = WhisperCppEngine()
            return whisper.isInstalled ? whisper : ParakeetEngine(modelsDir: Paths.modelsDir)
        }
    }
}
