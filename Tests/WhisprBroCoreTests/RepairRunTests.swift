import XCTest
@testable import WhisprBroCore

/// `whispr-bench repairs`' Core half (`RepairRun`): the formats it reads
/// (an eval set, JSONL rows, the reference CLI's run file) and the
/// row-for-row comparison behind the byte-parity check.
final class RepairRunTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testRowsFromASetFileOrJSONL() throws {
        let set = #"{"name": "x", "rows": [{"id": "s1", "input": "the the cat", "tokens": []}, {"id": "s2", "input": "a"}]}"#
        XCTAssertEqual(try RepairRun.loadRows(data(set)),
                       [.init(id: "s1", input: "the the cat"), .init(id: "s2", input: "a")])
        let jsonl = "{\"id\": \"r1\", \"input\": \"we went over over it\"}\n\n{\"id\": \"r2\", \"input\": \"ok\"}\n"
        XCTAssertEqual(try RepairRun.loadRows(data(jsonl)).map(\.id), ["r1", "r2"])
        XCTAssertThrowsError(try RepairRun.loadRows(data(#"{"id": "r1"}"#)))
        XCTAssertThrowsError(try RepairRun.loadRows(data("")))
    }

    func testStringsAreReadExactly() throws {
        // JSONSerialization drops a U+FEFF that opens a string value; the
        // loaders read every string through JSONDecoder, so a parity check on
        // such a row compares what the reference compared.
        let bom = "\u{FEFF}the dog dog park"
        let line = "{\"id\": \"b1\", \"input\": \"\(bom)\"}"
        XCTAssertEqual(try RepairRun.loadRows(data(line)).first?.input.unicodeScalars.first, "\u{FEFF}")
        let set = "{\"rows\": [{\"id\": \"b1\", \"input\": \"\(bom)\"}]}"
        XCTAssertEqual(try RepairRun.loadRows(data(set)).first?.input.unicodeScalars.first, "\u{FEFF}")
        let record = "{\"id\": \"b1\", \"output\": \"\(bom)\", \"variant\": \"v\", \"fires\": []}"
        XCTAssertEqual(try RepairRun.loadRecords(data(record)).first?.output.unicodeScalars.first, "\u{FEFF}")
        let records = RepairRun.run(try RepairRun.loadRows(data(line)), with: SelfRepair(naturalLanguage: false))
        XCTAssertEqual(records.first?.output.unicodeScalars.first, "\u{FEFF}")
        XCTAssertEqual(try RepairRun.loadRecords(try RepairRun.encode(records)), records)
    }

    func testRecordsInTheReferenceRunFormat() throws {
        let line = #"{"id": "s1", "variant": "c1", "output": "the cat", "ms": 0.5, "source": "rules", "fires": [["R1", [0]], ["R3", [4, 5]]]}"#
        let records = try RepairRun.loadRecords(data(line))
        XCTAssertEqual(records, [.init(id: "s1", output: "the cat",
                                       fires: [.init(rule: "R1", ids: [0]), .init(rule: "R3", ids: [4, 5])], ms: 0.5)])
    }

    func testSeveralVariantsNeedAChoice() throws {
        let file = """
        {"id": "a", "variant": "rules", "output": "final", "c1_output": "c1 text", "fires": []}
        {"id": "a", "variant": "app-rules", "output": "other", "c1_output": "x", "fires": []}
        """
        XCTAssertThrowsError(try RepairRun.loadRecords(data(file))) { error in
            XCTAssertEqual(error as? RepairRun.LoadError, .ambiguousVariant(["rules", "app-rules"]))
        }
        XCTAssertEqual(try RepairRun.loadRecords(data(file), field: "c1_output", variant: "rules").map(\.output),
                       ["c1 text"])
    }

    func testRecordsRoundTrip() throws {
        let records = RepairRun.run([.init(id: "x", input: "we went over over these")],
                                    with: SelfRepair(naturalLanguage: false))
        XCTAssertEqual(records.first?.output, "we went over these")
        XCTAssertEqual(records.first?.fires, [.init(rule: "R1", ids: [2])])
        XCTAssertNotNil(records.first?.ms)
        let line = String(decoding: try RepairRun.encode(records), as: UTF8.self)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertTrue(line.contains(#""fires":[["R1",[2]]]"#), line)
        XCTAssertEqual(try RepairRun.loadRecords(data(line)), records)
    }

    func testComparisonIsExact() {
        let ours: [RepairRun.Record] = [
            .init(id: "1", output: "same", fires: [.init(rule: "R1", ids: [1])], ms: 1),
            .init(id: "2", output: "caf\u{E9}", fires: [], ms: 1),
            .init(id: "3", output: "x", fires: [.init(rule: "R4", ids: [1, 2])], ms: 1),
            .init(id: "4", output: "only ours", fires: [], ms: 1),
        ]
        let reference: [RepairRun.Record] = [
            .init(id: "1", output: "same", fires: [.init(rule: "R1", ids: [1])], ms: nil),
            // canonically equal, different bytes: a difference
            .init(id: "2", output: "cafe\u{301}", fires: [], ms: nil),
            .init(id: "3", output: "x", fires: [.init(rule: "R4", ids: [1])], ms: nil),
            .init(id: "5", output: "only theirs", fires: [], ms: nil),
        ]
        let c = RepairRun.compare(ours, to: reference)
        XCTAssertEqual(c.compared, 3)
        XCTAssertEqual(c.identicalOutputs, 2)
        XCTAssertEqual(c.identicalFires, 2)
        XCTAssertEqual(c.differing, ["2", "3"])
        XCTAssertEqual(c.missing, ["4"])
        XCTAssertEqual(c.extra, ["5"])
        XCTAssertEqual(c.ours, ["R1": 1, "R4": 1])
        XCTAssertEqual(c.reference, ["R1": 1, "R4": 1])
        XCTAssertFalse(c.isIdentical)
        XCTAssertTrue(RepairRun.compare(ours, to: ours).isIdentical)
    }

    func testRuleAndGuardSpecs() {
        XCTAssertEqual(RepairRun.parseRules("all"), Set(SelfRepair.Rule.allCases))
        XCTAssertEqual(RepairRun.parseRules("none"), [])
        XCTAssertEqual(RepairRun.parseRules("level:fillers"), [.r1, .r1b, .r3])
        XCTAssertFalse(RepairRun.nonWords(forRules: "level:fillers"), "the fillers level runs R3 without R3a")
        XCTAssertTrue(RepairRun.nonWords(forRules: "level:standard"))
        XCTAssertTrue(RepairRun.nonWords(forRules: "all"))
        XCTAssertTrue(RepairRun.nonWords(forRules: "R3"))
        XCTAssertEqual(RepairRun.parseRules("level:standard"), Set(SelfRepair.Rule.allCases))
        XCTAssertEqual(RepairRun.parseRules("r1, R4S"), [.r1, .r4s])
        XCTAssertNil(RepairRun.parseRules("R9"))
        XCTAssertEqual(RepairRun.parseGuards("t1,T5b"), [.t1, .t5b])
        XCTAssertEqual(RepairRun.parseGuards(""), [])
        XCTAssertNil(RepairRun.parseGuards("T12"), "T12 was measured and dropped; there is no such guard")
    }

    func testFireCountsInRuleOrder() {
        let records: [RepairRun.Record] = [
            .init(id: "1", output: "", fires: [.init(rule: "R4", ids: [1]), .init(rule: "R1", ids: [0])], ms: nil),
            .init(id: "2", output: "", fires: [.init(rule: "R1", ids: [3])], ms: nil),
        ]
        XCTAssertEqual(RepairRun.fireCounts(records).map(\.rule), ["R1", "R4"])
        XCTAssertEqual(RepairRun.fireCounts(records).map(\.count), [2, 1])
    }
}
