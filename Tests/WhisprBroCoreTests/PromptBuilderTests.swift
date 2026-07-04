import XCTest
@testable import WhisprBroCore

final class PromptBuilderTests: XCTestCase {
    func testLlama3UsesHeaderTokens() {
        let pb = PromptBuilder(family: .llama3, systemPrompt: "SYS")
        XCTAssertTrue(pb.prefix().hasPrefix("<|begin_of_text|>"))
        XCTAssertTrue(pb.prefix().contains("<|start_header_id|>system<|end_header_id|>"))
        let suffix = pb.suffix(transcript: "hello")
        XCTAssertTrue(suffix.contains("<|start_header_id|>user<|end_header_id|>"))
        XCTAssertTrue(suffix.contains("hello<|eot_id|>"))
        XCTAssertTrue(suffix.contains("<|start_header_id|>assistant<|end_header_id|>"))
    }

    func testQwen25UsesChatMLWithoutThinkBlock() {
        let pb = PromptBuilder(family: .qwen, systemPrompt: "SYS")
        XCTAssertTrue(pb.prefix().contains("<|im_start|>system"))
        let suffix = pb.suffix(transcript: "hello")
        XCTAssertTrue(suffix.contains("<|im_start|>user"))
        XCTAssertTrue(suffix.contains("<|im_start|>assistant"))
        // Qwen2.5 has no reasoning — the think block must NOT be prefilled
        // (else a stray </think> leaks into output).
        XCTAssertFalse(suffix.contains("<think>"))
    }

    func testQwen3PrefillsEmptyThinkBlock() {
        let pb = PromptBuilder(family: .qwen3, systemPrompt: "SYS")
        let suffix = pb.suffix(transcript: "hello")
        XCTAssertTrue(suffix.contains("<think>"))
        XCTAssertTrue(suffix.contains("</think>"))
    }

    func testTranscriptAppearsVerbatimInSuffix() {
        // The engine relies on finding the transcript intact to tokenize it as
        // literal (non-special) text.
        for family in PromptBuilder.Family.allCases {
            let pb = PromptBuilder(family: family, systemPrompt: "SYS")
            XCTAssertTrue(pb.suffix(transcript: "the quick brown fox").contains("the quick brown fox"))
        }
    }
}
