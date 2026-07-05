import XCTest
@testable import WhisprBroCore

final class ConfigStoreTests: XCTestCase {
    func testParsesAllThreeSections() {
        let toml = """
        # a comment
        [[dictionary]]
        from = "get user data"
        to = "getUserData"

        [[dictionary]]
        from = "github"
        to = "GitHub"

        [style]
        mail = "very formal"

        [categories]
        "com.example.Chatty" = "messaging"
        """
        let c = ConfigStore.parse(toml)
        XCTAssertEqual(c.dictionary.count, 2)
        XCTAssertEqual(c.dictionary[0], .init(from: "get user data", to: "getUserData"))
        XCTAssertEqual(c.dictionary[1], .init(from: "github", to: "GitHub"))
        XCTAssertEqual(c.style["mail"], "very formal")
        XCTAssertEqual(c.categories["com.example.Chatty"], "messaging")
    }

    func testRoundTripPreservesValues() {
        var c = AppConfig()
        c.dictionary = [.init(from: "acme corp", to: "AcmeCorp"),
                        .init(from: "get user data", to: "getUserData")]
        c.style = ["mail": "formal", "terminal": "verbatim"]
        c.categories = ["com.foo.Bar": "ide"]
        let reparsed = ConfigStore.parse(ConfigStore.emit(c))
        XCTAssertEqual(reparsed, c)
    }

    func testValueWithSpecialCharsRoundTrips() {
        var c = AppConfig()
        // Values containing quotes, backslashes, '#', '=' must survive.
        c.dictionary = [.init(from: "hash tag", to: "#tag"),
                        .init(from: "quote", to: "he said \"hi\""),
                        .init(from: "path", to: "C:\\Users")]
        c.style = ["ide": "use = and # freely"]
        let reparsed = ConfigStore.parse(ConfigStore.emit(c))
        XCTAssertEqual(reparsed, c)
    }

    func testLiteralStringsAndTrailingComments() {
        let toml = """
        [[dictionary]]
        from = 'raw \\n not escaped'
        to = "GitHub" # trailing comment
        """
        let c = ConfigStore.parse(toml)
        XCTAssertEqual(c.dictionary.first?.from, "raw \\n not escaped") // literal: backslash-n kept
        XCTAssertEqual(c.dictionary.first?.to, "GitHub")
    }

    func testHashInsideQuotedValueIsNotAComment() {
        let c = ConfigStore.parse(#"""
        [style]
        chat = "use #hashtags casually"
        """#)
        XCTAssertEqual(c.style["chat"], "use #hashtags casually")
    }

    func testUnknownTablesAndBlankLinesTolerated() {
        let toml = """

        [mystery]
        ignored = "yes"

        [[dictionary]]
        from = "x"
        to = "Y"
        """
        let c = ConfigStore.parse(toml)
        XCTAssertEqual(c.dictionary.count, 1)
        XCTAssertEqual(c.dictionary[0].to, "Y")
    }

    func testEmptyInputIsEmptyConfig() {
        XCTAssertEqual(ConfigStore.parse(""), AppConfig())
    }

    func testCRLFLineEndingsDoNotWipeConfig() {
        let toml = "[[dictionary]]\r\nfrom = \"x\"\r\nto = \"Y\"\r\n[style]\r\nmail = \"formal\"\r\n"
        let c = ConfigStore.parse(toml)
        XCTAssertEqual(c.dictionary.first, .init(from: "x", to: "Y"))
        XCTAssertEqual(c.style["mail"], "formal")
    }

    func testTrailingCommentOnTableHeader() {
        let toml = """
        [[dictionary]] # john's terms
        from = "x"
        to = "Y"

        [style]   # per-app overrides
        mail = "formal"
        """
        let c = ConfigStore.parse(toml)
        XCTAssertEqual(c.dictionary.count, 1)
        XCTAssertEqual(c.style["mail"], "formal")
    }

    func testCommentInsideQuotedValueStillNotAComment() {
        let c = ConfigStore.parse("[[dictionary]]\nfrom = \"a # b\"\nto = \"c # d\"")
        XCTAssertEqual(c.dictionary.first, .init(from: "a # b", to: "c # d"))
    }
}
