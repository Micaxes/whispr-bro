import Foundation

/// `whispr-bench repairs`: `SelfRepair` alone over a set of rows, and the
/// row-for-row comparison with a reference run (docs/self-repair.md). The
/// port's contract is byte parity with the reference implementation, so the
/// comparison is exact: the same output bytes and the same fires (rule and
/// deleted token indices) on every row, and the per-rule fire counts that
/// summarise them.
///
/// Formats (one JSON object per line, or a set file):
///  - rows in: an eval set `{"rows": [{"id", "input", …}]}`, or JSONL lines
///    `{"id", "input"}`;
///  - records: `{"id", "output", "fires": [["R1", [3, 4]], …], "ms"}` — the
///    reference CLI's run format, so its file compares as written.
public enum RepairRun {
    public struct Row: Sendable, Equatable {
        public let id: String
        public let input: String
        public init(id: String, input: String) { self.id = id; self.input = input }
    }

    /// One fire as the reference writes it: `["R1", [3, 4]]`.
    public struct FireRecord: Codable, Sendable, Equatable {
        public let rule: String
        public let ids: [Int]

        public init(rule: String, ids: [Int]) { self.rule = rule; self.ids = ids }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            rule = try c.decode(String.self)
            ids = try c.decode([Int].self)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(rule)
            try c.encode(ids)
        }
    }

    public struct Record: Codable, Sendable, Equatable {
        public let id: String
        public let output: String
        public let fires: [FireRecord]
        public let ms: Double?

        public init(id: String, output: String, fires: [FireRecord], ms: Double?) {
            self.id = id
            self.output = output
            self.fires = fires
            self.ms = ms
        }
    }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case noRows
        case badLine(Int, String)
        case ambiguousVariant([String])

        public var description: String {
            switch self {
            case .unreadable(let why): return "not a set file or JSONL rows: \(why)"
            case .noRows: return "no rows"
            case .badLine(let n, let why): return "line \(n): \(why)"
            case .ambiguousVariant(let names):
                return "the file holds several variants (\(names.joined(separator: ", "))); pick one with --variant"
            }
        }
    }

    // MARK: Loading
    //
    // The shape is checked with JSONSerialization, but every string is read
    // with JSONDecoder: JSONSerialization drops a U+FEFF that opens a string
    // value, and a parity check compares strings byte for byte.

    private struct RowIn: Decodable { let id: String; let input: String }
    private struct SetIn: Decodable { let rows: [RowIn] }

    /// Every string-valued field of one JSON object, read exactly.
    private struct Strings: Decodable {
        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        let values: [String: String]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            var values: [String: String] = [:]
            for key in c.allKeys {
                if let value = try? c.decode(String.self, forKey: key) { values[key.stringValue] = value }
            }
            self.values = values
        }
    }

    /// Rows from an eval set (`{"rows": [...]}`) or JSONL (`{"id", "input"}`).
    public static func loadRows(_ data: Data) throws -> [Row] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rows = object["rows"] as? [[String: Any]] {
            for (n, row) in rows.enumerated() where !(row["id"] is String && row["input"] is String) {
                throw LoadError.badLine(n + 1, "a row needs a string id and input")
            }
            let out = try JSONDecoder().decode(SetIn.self, from: data).rows.map { Row(id: $0.id, input: $0.input) }
            guard !out.isEmpty else { throw LoadError.noRows }
            return out
        }
        var out: [Row] = []
        for (n, line) in lines(data).enumerated() where !line.isEmpty {
            let bytes = Data(line.utf8)
            guard let row = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw LoadError.badLine(n + 1, "not a JSON object")
            }
            guard row["id"] is String, row["input"] is String,
                  let exact = try? JSONDecoder().decode(RowIn.self, from: bytes) else {
                throw LoadError.badLine(n + 1, "needs a string id and input")
            }
            out.append(Row(id: exact.id, input: exact.input))
        }
        guard !out.isEmpty else { throw LoadError.noRows }
        return out
    }

    /// Records from a run JSONL. `field` names the output field (the
    /// reference CLI writes `output`); `variant` picks one of several in one
    /// file and is required when there are several.
    public static func loadRecords(_ data: Data, field: String = "output", variant: String? = nil) throws -> [Record] {
        var byVariant: [String: [Record]] = [:]
        var order: [String] = []
        for (n, line) in lines(data).enumerated() where !line.isEmpty {
            let bytes = Data(line.utf8)
            guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw LoadError.badLine(n + 1, "not a JSON object")
            }
            let strings = (try? JSONDecoder().decode(Strings.self, from: bytes))?.values ?? [:]
            guard let id = strings["id"], let output = strings[field] else {
                throw LoadError.badLine(n + 1, "needs a string id and \(field)")
            }
            var fires: [FireRecord] = []
            for case let fire as [Any] in (object["fires"] as? [Any]) ?? [] {
                guard fire.count == 2, let rule = fire[0] as? String, let ids = fire[1] as? [Int] else {
                    throw LoadError.badLine(n + 1, "a fire is [rule, [token ids]]")
                }
                fires.append(FireRecord(rule: rule, ids: ids))
            }
            let name = strings["variant"] ?? ""
            if byVariant[name] == nil { order.append(name) }
            byVariant[name, default: []].append(Record(id: id, output: output, fires: fires,
                                                       ms: object["ms"] as? Double))
        }
        if let variant {
            guard let records = byVariant[variant], !records.isEmpty else { throw LoadError.noRows }
            return records
        }
        guard order.count <= 1 else { throw LoadError.ambiguousVariant(order) }
        guard let only = order.first, let records = byVariant[only] else { throw LoadError.noRows }
        return records
    }

    private static func lines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Running

    /// "all" | "none" | "level:fillers" | "level:standard" | "R1,R3,…".
    public static func parseRules(_ spec: String) -> Set<SelfRepair.Rule>? {
        switch spec.lowercased() {
        case "", "all": return Set(SelfRepair.Rule.allCases)
        case "none": return []
        case "level:verbatim": return SelfRepair.rules(for: .verbatim)
        case "level:fillers": return SelfRepair.rules(for: .fillers)
        case "level:standard": return SelfRepair.rules(for: .standard)
        default:
            var out = Set<SelfRepair.Rule>()
            for name in spec.split(separator: ",") {
                guard let rule = SelfRepair.Rule(rawValue: name.trimmingCharacters(in: .whitespaces).uppercased())
                else { return nil }
                out.insert(rule)
            }
            return out
        }
    }

    /// Whether a `--rules` spec deletes R3a's non-words: a level decides
    /// (`SelfRepair.deletesNonWords(at:)` — not at `fillers`), a rule list
    /// keeps them, as the reference's `--rules` does (its `--level` and
    /// `--no-nonwords` switch them).
    public static func nonWords(forRules spec: String) -> Bool {
        switch spec.lowercased() {
        case "level:verbatim": return SelfRepair.deletesNonWords(at: .verbatim)
        case "level:fillers": return SelfRepair.deletesNonWords(at: .fillers)
        case "level:standard": return SelfRepair.deletesNonWords(at: .standard)
        default: return true
        }
    }

    /// Guard names ("T1,T5b"), matched case-insensitively; nil on an unknown one.
    public static func parseGuards(_ spec: String) -> Set<SelfRepair.Guard>? {
        var out = Set<SelfRepair.Guard>()
        for name in spec.split(separator: ",") {
            let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard let g = SelfRepair.Guard.allCases.first(where: { $0.rawValue.lowercased() == wanted }) else { return nil }
            out.insert(g)
        }
        return out
    }

    /// Run `repair` over `rows`, timing each apply.
    public static func run(_ rows: [Row], with repair: SelfRepair) -> [Record] {
        let clock = ContinuousClock()
        return rows.map { row in
            let start = clock.now
            let result = repair.apply(row.input)
            let elapsed = clock.now - start
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            return Record(id: row.id, output: result.text,
                          fires: result.fires.map { FireRecord(rule: $0.rule.rawValue, ids: $0.deleted) },
                          ms: (ms * 1000).rounded() / 1000)
        }
    }

    /// One JSON object per line, keys sorted, nothing escaped that need not be.
    public static func encode(_ records: [Record]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for record in records {
            out.append(try encoder.encode(record))
            out.append(0x0A)
        }
        return out
    }

    /// Fires per rule, in rule order.
    public static func fireCounts(_ records: [Record]) -> [(rule: String, count: Int)] {
        var counts: [String: Int] = [:]
        for record in records { for fire in record.fires { counts[fire.rule, default: 0] += 1 } }
        let known = SelfRepair.Rule.allCases.map(\.rawValue)
        let names = known + counts.keys.filter { !known.contains($0) }.sorted()
        return names.compactMap { name in counts[name].map { (name, $0) } }
    }

    // MARK: Comparing

    public struct Comparison: Sendable, Equatable {
        /// Rows present on both sides.
        public let compared: Int
        /// Rows whose output bytes are identical.
        public let identicalOutputs: Int
        /// Rows whose fires (rule + token ids, in order) are identical.
        public let identicalFires: Int
        /// Ids whose output or fires differ, in row order.
        public let differing: [String]
        /// Ids on one side only.
        public let missing: [String]
        public let extra: [String]
        public let ours: [String: Int]
        public let reference: [String: Int]

        public var isIdentical: Bool {
            missing.isEmpty && extra.isEmpty && differing.isEmpty
        }
    }

    /// Row-for-row: identical output bytes and identical fires, by id.
    public static func compare(_ ours: [Record], to reference: [Record]) -> Comparison {
        let theirs = Dictionary(reference.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mine = Set(ours.map(\.id))
        var compared = 0, sameOutput = 0, sameFires = 0
        var differing: [String] = [], missing: [String] = []
        for record in ours {
            guard let other = theirs[record.id] else { missing.append(record.id); continue }
            compared += 1
            let outputMatches = record.output.unicodeScalars.elementsEqual(other.output.unicodeScalars)
            let firesMatch = record.fires == other.fires
            if outputMatches { sameOutput += 1 }
            if firesMatch { sameFires += 1 }
            if !outputMatches || !firesMatch { differing.append(record.id) }
        }
        let extra = reference.map(\.id).filter { !mine.contains($0) }
        func counts(_ records: [Record]) -> [String: Int] {
            Dictionary(fireCounts(records).map { ($0.rule, $0.count) }, uniquingKeysWith: +)
        }
        return Comparison(compared: compared, identicalOutputs: sameOutput, identicalFires: sameFires,
                          differing: differing, missing: missing, extra: extra,
                          ours: counts(ours), reference: counts(reference.filter { mine.contains($0.id) }))
    }
}
