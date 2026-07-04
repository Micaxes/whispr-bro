import Foundation

/// Filesystem locations for whispr-bro state. Everything lives under
/// `~/Library/Application Support/whispr-bro/` (override with `WHISPR_BRO_HOME`
/// for tests and bench runs).
public enum Paths {
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["WHISPR_BRO_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whispr-bro", isDirectory: true)
    }

    /// Models are placed here by `scripts/fetch-models.sh` (install time only).
    /// The app never downloads at runtime.
    public static var modelsDir: URL {
        home.appendingPathComponent("models", isDirectory: true)
    }

    /// The Silero VAD CoreML bundle installed by `fetch-models.sh`.
    public static var vadModelFile: URL {
        modelsDir
            .appendingPathComponent("silero-vad", isDirectory: true)
            .appendingPathComponent("silero-vad-unified-256ms-v6.0.0.mlmodelc", isDirectory: true)
    }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    }
}
