import XCTest

/// The eval docs are read as CommonMark (GitHub), where a table ends at
/// the first line that is not a row: a paragraph or list dropped between
/// two rows turns every row after it into lazy-continuation prose of
/// whatever came before (the §2.5 gate table lost its OVER_EDIT_FACT row
/// to NEGATED's departures list that way), and a blank line splits one
/// table into two, the second without a header. So: every `|` row follows
/// either another row or a blank line, and a row that opens a table is
/// followed by its delimiter row. Fenced code is skipped (the JSON
/// samples). The docs are found from `#filePath`, so the test reads the
/// checkout it was built from — model-free, no network.
final class EvalDocsTests: XCTestCase {
    private static let docs = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs", isDirectory: true)

    /// Every row (1-based line) that is not glued to a table.
    static func brokenTables(in markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: "\n")
        var fenced = false
        var problems: [String] = []
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); continue }
            guard !fenced, line.hasPrefix("|") else { continue }
            let previous = i > 0 ? lines[i - 1] : ""
            if previous.hasPrefix("|") { continue }
            if !previous.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("line \(i + 1): row follows prose")
            } else if i + 1 >= lines.count || !isDelimiterRow(lines[i + 1]) {
                problems.append("line \(i + 1): table opens without a delimiter row")
            }
        }
        return problems
    }

    /// `|---|:---:|---:|` and friends: every cell is ≥ 3 dashes with
    /// optional alignment colons.
    static func isDelimiterRow(_ line: String) -> Bool {
        let cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let inner = cells.dropFirst(cells.first == "" ? 1 : 0).dropLast(cells.last == "" ? 1 : 0)
        return !inner.isEmpty && inner.allSatisfy { cell in
            var body = Substring(cell)
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }
            return body.count >= 3 && body.allSatisfy { $0 == "-" }
        }
    }

    func testEveryTableInTheDocsIsContiguous() throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: Self.docs.path)
            .filter { $0.hasSuffix(".md") }.sorted()
        XCTAssertTrue(files.contains("eval-benchmark.md"), "docs not found at \(Self.docs.path)")
        for file in files {
            let text = try String(contentsOf: Self.docs.appendingPathComponent(file), encoding: .utf8)
            XCTAssertEqual(Self.brokenTables(in: text), [], file)
        }
    }

    func testTheCheckSeesARowSplitByProseOrByABlankLine() {
        // The §2.5 shape before the fix: a list between two rows, so the
        // last row reads as a lazy continuation of item 3.
        let split = """
        | Gate | Trigger |
        |---|---|
        | A | x |

        Three departures:

        3. the mirror.
        | B | y |
        """
        XCTAssertEqual(Self.brokenTables(in: split), ["line 8: row follows prose"])
        // A blank line between rows opens a headerless second table.
        let torn = """
        | Gate | Trigger |
        |---|---|
        | A | x |

        | B | y |
        """
        XCTAssertEqual(Self.brokenTables(in: torn), ["line 5: table opens without a delimiter row"])
        XCTAssertEqual(Self.brokenTables(in: "| Gate | Trigger |\n|---|---|\n| A | x |\n\nprose\n"), [])
        XCTAssertEqual(Self.brokenTables(in: "```\n| not | a table |\n```\n"), [])
        XCTAssertTrue(Self.isDelimiterRow("|---|:---:|---:|"))
        XCTAssertTrue(Self.isDelimiterRow("--- | ---"))
        XCTAssertFalse(Self.isDelimiterRow("| A | x |"))
        XCTAssertFalse(Self.isDelimiterRow("|--|--|"))
    }
}
