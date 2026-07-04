import Foundation

/// The reformatting-LLM candidates (spec §6, §13.1). The default is frozen from
/// the task-009 measurement gate; the others remain selectable presets.
public struct LlmModelSpec: Sendable, Equatable {
    public let key: String
    public let displayName: String
    public let family: PromptBuilder.Family
    /// Path under `Paths.llmDir`, matching scripts/fetch-llm-models.sh layout.
    public let relativePath: String

    public var fileURL: URL {
        Paths.llmDir.appendingPathComponent(relativePath)
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }
}

public enum LlmCatalog {
    public static let llama3_2_1b = LlmModelSpec(
        key: "llama3.2-1b", displayName: "Llama 3.2 1B Instruct", family: .llama3,
        relativePath: "llama3.2-1b/Llama-3.2-1B-Instruct-Q4_K_M.gguf")
    public static let qwen2_5_1_5b = LlmModelSpec(
        key: "qwen2.5-1.5b", displayName: "Qwen2.5 1.5B Instruct", family: .qwen,
        relativePath: "qwen2.5-1.5b/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf")
    public static let qwen3_1_7b = LlmModelSpec(
        key: "qwen3-1.7b", displayName: "Qwen3 1.7B (no-think)", family: .qwen3,
        relativePath: "qwen3-1.7b/Qwen_Qwen3-1.7B-Q4_K_M.gguf")

    public static let all = [llama3_2_1b, qwen2_5_1_5b, qwen3_1_7b]

    public static func spec(key: String) -> LlmModelSpec? {
        all.first { $0.key == key }
    }

    /// The measurement-gate default (frozen in task-009 from on-device data).
    public static var `default`: LlmModelSpec { qwen2_5_1_5b }
}
