import Foundation

/// The human rating loop's data and state machine (plan §7.1–7.2): the
/// record `whispr-bench rate` appends to `ratings.jsonl`, the queue it
/// walks, the screen it draws for one row, and the key-to-record state
/// machine behind it. Everything but the terminal's raw mode and the
/// `$EDITOR` launch lives here, in Core, because the bench target is
/// invisible to XCTest — `Sources/whispr-bench/Rate.swift` reads keys,
/// prints what `RatingSession` hands it, and writes the lines it emits.
///
/// Ground truth is him: five seconds a row turns SHIP / FIX / WRONG into
/// golds (`GoldDerivation`) and into the κ the composite has to clear
/// before it is called valid (`Calibration`). So the record is the
/// contract, and it is deliberately small — a verdict, the tags he
/// picked, the spans he marked, and enough identity (`fixture_id`,
/// `run_key`, `formatter`, `output_sha`) to say exactly which text he was
/// looking at.
public enum RatingChips {
    /// The fixed chip list (§7.1). Free-text tags are not offered: a tag
    /// nobody aggregates is a tag nobody reads, and calibration check 3
    /// keys off these names.
    ///
    /// `negated` closes §7.1's list: §7.4 check 3 makes NEGATED recall a
    /// condition of VALID, and without a chip for it no rating could ever
    /// carry the label — the gate was unmeasurable by construction, so the
    /// check could never honestly pass. It is appended, so every key
    /// already in his fingers keeps its letter.
    public static let all = [
        "answered", "invented", "dropped-fact", "dropped-hedge", "reworded", "missed-filler",
        "missed-stutter", "missed-repair", "bad-fragment", "wrong-punct", "wrong-case", "asr-slip",
        "negated",
    ]

    /// `a` … `l`, in list order — the key that toggles each chip.
    public static func key(for chip: String) -> String? {
        guard let index = all.firstIndex(of: chip), let scalar = UnicodeScalar(97 + index) else { return nil }
        return String(Character(scalar))
    }

    public static func chip(forKey key: String) -> String? {
        guard key.count == 1, let scalar = key.unicodeScalars.first, scalar.value >= 97 else { return nil }
        let index = Int(scalar.value) - 97
        return index < all.count ? all[index] : nil
    }

    /// `a answered · b invented · …`, wrapped at `perLine` chips.
    public static func menu(selected: [String] = [], perLine: Int = 6) -> [String] {
        var lines: [String] = []
        for chunk in stride(from: 0, to: all.count, by: perLine) {
            let slice = all[chunk..<min(chunk + perLine, all.count)]
            lines.append(slice.map { chip in
                let mark = selected.contains(chip) ? "×" : " "
                return "[\(mark)] \(key(for: chip) ?? "?") \(chip)"
            }.joined(separator: "  "))
        }
        return lines
    }
}

// MARK: - The record

/// One rating (§7.2), appended as a line of `ratings.jsonl` (0600).
///
/// Two fields extend the plan's list, both optional and both omitted
/// unless they apply, so a reader written against §7.2 is unaffected:
/// - `verdict` is absent on a **pairwise** record. A pick between two
///   outputs is not a SHIP/FIX/WRONG judgement of either, and writing a
///   fake one would poison the weighted-κ check that reads this file.
/// - `confirm: true` is the `y` key — "the draft annotations on this
///   fixture are right as they stand". §7.3 asks the derivation to flip
///   `annotations_status` on a confirm pass, and no §7.2 field carries it.
public struct Rating: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        /// Would paste it untouched.
        case ship
        /// Only punctuation or case needs a touch.
        case fix
        /// Meaning changed.
        case wrong

        /// SHIP 2 · FIX 1 · WRONG 0 — higher is better, the ordinal the
        /// weighted κ and Spearman ρ read.
        public var level: Int {
            switch self {
            case .ship: return 2
            case .fix: return 1
            case .wrong: return 0
            }
        }
    }

    /// A blind A/B pick (§7.1 pairwise). `slot` is where the **first**
    /// run's output was shown, so `pick == slot` means that run won; the
    /// randomisation is replayable from the session id alone. `rate`
    /// records `a_run` as the run it put in slot A, so its own records
    /// always read `"slot":"a"` — the field stays, both because a record
    /// written the other way round still reads correctly and because a
    /// second front-end may lay the screen out its own way.
    public struct Pair: Codable, Sendable, Equatable {
        public var aRun: String
        public var bRun: String
        /// `"a"` or `"b"` — the slot `aRun`'s output occupied on screen.
        public var slot: String
        /// `"a"`, `"b"` or `"="` — the SLOT he picked.
        public var pick: String

        enum CodingKeys: String, CodingKey {
            case aRun = "a_run"
            case bRun = "b_run"
            case slot, pick
        }

        public init(aRun: String, bRun: String, slot: String, pick: String) {
            self.aRun = aRun
            self.bRun = bRun
            self.slot = slot
            self.pick = pick
        }

        public var isTie: Bool { pick == "=" }
        /// The run he picked, nil on a tie.
        public var pickedRun: String? { isTie ? nil : (pick == slot ? aRun : bRun) }
        /// +1 `aRun` won · 0 tie · −1 `bRun` won.
        public var preference: Int { isTie ? 0 : (pick == slot ? 1 : -1) }
    }

    public var fixtureId: String
    public var runKey: String
    public var formatter: String
    /// First 12 hex of SHA-256 over the output he was shown — the record
    /// pins the TEXT, not the run: a re-run that produces the same output
    /// is already rated.
    public var outputSha: String
    /// Absent on a pairwise record.
    public var verdict: Verdict?
    public var tags: [String]
    /// Spans he marked with `k` (weight 2) / `K` (weight 5). Decodes from
    /// a bare string list too (weight 2), as `EvalCase.MustKeep` does.
    public var mustKeep: [EvalCase.MustKeep]
    /// Reserved by §7.2 for spans that should have been removed; no key
    /// writes it yet (the chips already say `missed-filler` /
    /// `missed-stutter`), so it is always encoded empty.
    public var shouldGo: [String]
    public var goldEdit: String?
    public var altGold: String?
    /// The `y` key: the fixture's draft annotations are right as they are.
    public var confirm: Bool?
    public var pair: Pair?
    public var msToRate: Int
    public var ratedAt: String
    public var session: String

    enum CodingKeys: String, CodingKey {
        case formatter, verdict, tags, pair, session, confirm
        case fixtureId = "fixture_id"
        case runKey = "run_key"
        case outputSha = "output_sha"
        case mustKeep = "must_keep"
        case shouldGo = "should_go"
        case goldEdit = "gold_edit"
        case altGold = "alt_gold"
        case msToRate = "ms_to_rate"
        case ratedAt = "rated_at"
    }

    public init(fixtureId: String, runKey: String, formatter: String, outputSha: String,
                verdict: Verdict?, tags: [String] = [], mustKeep: [EvalCase.MustKeep] = [],
                shouldGo: [String] = [], goldEdit: String? = nil, altGold: String? = nil,
                confirm: Bool? = nil, pair: Pair? = nil, msToRate: Int, ratedAt: String, session: String) {
        self.fixtureId = fixtureId
        self.runKey = runKey
        self.formatter = formatter
        self.outputSha = outputSha
        self.verdict = verdict
        self.tags = tags
        self.mustKeep = mustKeep
        self.shouldGo = shouldGo
        self.goldEdit = goldEdit
        self.altGold = altGold
        self.confirm = confirm
        self.pair = pair
        self.msToRate = msToRate
        self.ratedAt = ratedAt
        self.session = session
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fixtureId = try c.decode(String.self, forKey: .fixtureId)
        runKey = try c.decode(String.self, forKey: .runKey)
        formatter = try c.decode(String.self, forKey: .formatter)
        outputSha = try c.decode(String.self, forKey: .outputSha)
        verdict = try c.decodeIfPresent(Verdict.self, forKey: .verdict)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        mustKeep = try c.decodeIfPresent([EvalCase.MustKeep].self, forKey: .mustKeep) ?? []
        shouldGo = try c.decodeIfPresent([String].self, forKey: .shouldGo) ?? []
        goldEdit = try c.decodeIfPresent(String.self, forKey: .goldEdit)
        altGold = try c.decodeIfPresent(String.self, forKey: .altGold)
        confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm)
        pair = try c.decodeIfPresent(Pair.self, forKey: .pair)
        msToRate = try c.decodeIfPresent(Int.self, forKey: .msToRate) ?? 0
        ratedAt = try c.decode(String.self, forKey: .ratedAt)
        session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fixtureId, forKey: .fixtureId)
        try c.encode(runKey, forKey: .runKey)
        try c.encode(formatter, forKey: .formatter)
        try c.encode(outputSha, forKey: .outputSha)
        try c.encodeIfPresent(verdict, forKey: .verdict)
        try c.encode(tags, forKey: .tags)
        try c.encode(mustKeep, forKey: .mustKeep)
        try c.encode(shouldGo, forKey: .shouldGo)
        try c.encodeIfPresent(goldEdit, forKey: .goldEdit)
        try c.encodeIfPresent(altGold, forKey: .altGold)
        try c.encodeIfPresent(confirm, forKey: .confirm)
        try c.encodeIfPresent(pair, forKey: .pair)
        try c.encode(msToRate, forKey: .msToRate)
        try c.encode(ratedAt, forKey: .ratedAt)
        try c.encode(session, forKey: .session)
    }

    /// A triage record (a verdict on one output); the alternative is a
    /// pairwise pick.
    public var isTriage: Bool { pair == nil }
    public var isPairwise: Bool { pair != nil }
    /// A confirm pass (`y`) carries no verdict of its own beyond "the
    /// annotations are right".
    public var isConfirm: Bool { confirm == true }

    /// The record carries a GOLD, verdict or no verdict: one he typed
    /// (`e`) or an output he blessed as also-fine (`=`). `y` after an edit
    /// writes exactly such a record, and a queue that re-offered that row
    /// would ask him to type the same gold twice.
    ///
    /// Spans he marked (`k` / `K`) are deliberately NOT here. A mark is
    /// work the loop can ask for again — the span is in the log either
    /// way, `gold` drafts the `must_keep` from it either way — while a row
    /// he only marked still owes a verdict, and reading a mark as "rated"
    /// locked that row out of every future queue without one. §7.2's shape
    /// is untouched — the effect is read off the fields that already carry
    /// it.
    public var carriesAGold: Bool {
        isTriage && (!text(goldEdit).isEmpty || !text(altGold).isEmpty)
    }

    private func text(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The identity two ratings of the same text share (§7.1's
    /// skip-already-rated key).
    public struct Key: Hashable, Sendable {
        public let fixtureId: String
        public let outputSha: String
        public init(fixtureId: String, outputSha: String) {
            self.fixtureId = fixtureId
            self.outputSha = outputSha
        }
    }

    public var key: Key { Key(fixtureId: fixtureId, outputSha: outputSha) }

    /// First 12 hex of SHA-256 over the output's UTF-8 — as `run_key`,
    /// short enough to read in a JSONL line, wide enough that two of his
    /// outputs never collide.
    public static func outputSha(_ text: String) -> String {
        String(EvalRun.sha256Hex(text).prefix(12))
    }

    /// ISO-8601 UTC to the second, the one format `rated_at` takes.
    public static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    public static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    public var ratedAtDate: Date? { Rating.date(ratedAt) }
}

// MARK: - The log

/// `ratings.jsonl`: one record per line, append-only, 0600. Reading it is
/// how `rate` knows what is already rated, how `eval`'s banner counts, and
/// how `gold` and `calibrate` get their input.
public enum RatingLog {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case malformedLine(Int)

        public var description: String {
            switch self {
            case .malformedLine(let n): return "ratings line \(n) is not a record"
            }
        }
    }

    /// Parses JSONL; blank lines are skipped, a malformed line names its
    /// number (a half-written append must not read as a clean file).
    public static func load(_ data: Data) throws -> [Rating] {
        let decoder = JSONDecoder()
        var ratings: [Rating] = []
        for (index, line) in String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let rating = try? decoder.decode(Rating.self, from: Data(trimmed.utf8)) else {
                throw Error.malformedLine(index + 1)
            }
            ratings.append(rating)
        }
        return ratings
    }

    /// One compact line, keys sorted — the same encoder shape the
    /// leaderboard uses, so both files diff cleanly.
    public static func encode(_ rating: Rating) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(rating)
    }

    /// The (fixture, output) pairs `rate` skips without `--rerate`: the
    /// ones he JUDGED, plus the ones that already carry a gold. A bare `y`
    /// — a confirm of the fixture's annotations — is neither: it says
    /// nothing about the output and must not lock the row out, or the row
    /// could never acquire a SHIP / FIX / WRONG without re-opening the
    /// whole pass. A verdict-less record carrying a GOLD (one he typed and
    /// then confirmed) is a different thing: re-offering that row would
    /// ask him to type the same gold twice. A `k` / `K` mark is not enough
    /// — it can be made again next pass, and a row he only marked still
    /// owes its verdict. §7.4's `n` is unaffected — `ratedRows` and
    /// `ratedCount` still count verdicts, and only verdicts.
    public static func ratedKeys(_ ratings: [Rating]) -> Set<Rating.Key> {
        Set(ratings.filter { $0.isTriage && ($0.verdict != nil || $0.carriesAGold) }.map(\.key))
    }

    /// The pairs already judged, keyed by fixture and the two runs (order
    /// free: A vs B is the same comparison as B vs A).
    public static func pairKeys(_ ratings: [Rating]) -> Set<String> {
        Set(ratings.compactMap { rating in
            rating.pair.map { "\(rating.fixtureId)\n" + [$0.aRun, $0.bRun].sorted().joined(separator: "\n") }
        })
    }

    /// Fixtures of `cases` carrying at least one VERDICT — how much of the
    /// set he has been through. A confirm carries no verdict, so it does
    /// not make a fixture rated.
    public static func ratedCount(_ ratings: [Rating], in cases: [EvalCase]) -> Int {
        let ids = Set(ratings.filter { $0.isTriage && $0.verdict != nil }.map(\.fixtureId))
        return cases.filter { ids.contains($0.id) }.count
    }

    /// Rated ROWS: one per verdict he pressed, the unit §7.4's "≥ 100
    /// rated rows" gate counts and the unit `calibrate`'s own `n` uses.
    /// `ids` narrows to one fixture set; nil counts the whole log.
    public static func ratedRows(_ ratings: [Rating], ids: Set<String>? = nil) -> Int {
        ratings.filter { rating in
            guard rating.isTriage, rating.verdict != nil else { return false }
            return ids.map { $0.contains(rating.fixtureId) } ?? true
        }.count
    }

    /// SHIP / FIX / WRONG per column.
    public struct Counts: Sendable, Equatable {
        public var ship = 0
        public var fix = 0
        public var wrong = 0

        public var total: Int { ship + fix + wrong }
        /// The Wispr-style north star (§7.4): the share he would paste
        /// untouched. nil with nothing rated.
        public var zeroEditRate: Double? {
            total == 0 ? nil : 100 * Double(ship) / Double(total)
        }

        public mutating func add(_ verdict: Rating.Verdict) {
            switch verdict {
            case .ship: ship += 1
            case .fix: fix += 1
            case .wrong: wrong += 1
            }
        }
    }

    /// Per-formatter counts over triage records; `ids` narrows to one
    /// fixture set (a ratings file spans every set he has rated).
    public static func counts(_ ratings: [Rating], ids: Set<String>? = nil) -> [String: Counts] {
        var out: [String: Counts] = [:]
        for rating in ratings {
            guard let verdict = rating.verdict, rating.isTriage else { continue }
            if let ids, !ids.contains(rating.fixtureId) { continue }
            out[rating.formatter, default: Counts()].add(verdict)
        }
        return out
    }

    /// `zero_edit_rate` per column for the leaderboard row.
    public static func zeroEditRates(_ ratings: [Rating], ids: Set<String>? = nil) -> [String: Double] {
        counts(ratings, ids: ids).compactMapValues { $0.zeroEditRate.map { EvalRun.round($0, places: 1) } }
    }
}

// MARK: - The queue

/// What `rate` walks: one item per (fixture, column) of a run, flagged
/// rows first (§7.1), already-rated outputs skipped.
public enum RatingQueue {
    public struct Item: Sendable, Equatable {
        public let fixture: EvalCase
        public let formatter: String
        public let runKey: String
        public let row: EvalRun.Row
        /// Gated, or `dropped_content ≥ EvalThresholds.flaggedDroppedContent`.
        public let flagged: Bool
        /// The fixture has no gold yet.
        public let unrated: Bool
        /// Pairwise only: the other run's output and the blind slot.
        public let pair: PairCandidate?

        public var isPairwise: Bool { pair != nil }
    }

    public struct PairCandidate: Sendable, Equatable {
        public let otherRunKey: String
        public let otherFormatter: String
        public let otherOut: String
        /// `"a"` or `"b"` — the slot THIS item's output is shown in.
        public let slot: String

        /// What the screen shows in slot A / slot B.
        public func slots(_ out: String) -> (a: String, b: String) {
            slot == "a" ? (out, otherOut) : (otherOut, out)
        }
    }

    /// The blind slot for a fixture in a session: the low bit of
    /// sha256(fixture id ⊕ session). Blind — he cannot tell which run is
    /// which — and replayable: the same session id re-derives the same
    /// layout, so a stored pick can be re-read months later.
    ///
    /// The session is hashed WITH the id, not XOR-ed a byte at a time
    /// afterwards: folding one bit of the session digest into one bit of
    /// the id's leaves only two layouts in existence — the identity and
    /// its exact mirror — so a re-rate pass in a new session is never an
    /// independent blind. Here every session re-draws the whole layout.
    public static func slot(fixtureId: String, session: String) -> String {
        byte(EvalRun.sha256Hex(fixtureId + "\n" + session)) & 1 == 0 ? "a" : "b"
    }

    private static func byte(_ hex: String) -> UInt8 {
        UInt8(hex.prefix(2), radix: 16) ?? 0
    }

    /// Builds the queue.
    /// - `only`: `flagged` (gated ∨ dropped ≥ 3) · `gated` · `unrated` ·
    ///   `all`. Whatever the filter, the ORDER is flagged rows first, then
    ///   gold-free ones, then the rest — the five minutes he actually
    ///   spends go to the rows that are probably wrong.
    /// - `column`: one formatter, else every column of the run in run order.
    /// - `pairwise`: a second run; items become blind A/B pairs over the
    ///   fixtures and formatters both runs measured, and nothing else.
    /// - `ratings` / `rerate`: an output already rated is skipped unless
    ///   `--rerate` (the ≥ 7-day re-rate pass of calibration check 1).
    public static func build(run: EvalRun, fixtures: [EvalCase], only: EvalPlan.Only = .all,
                             column: String? = nil, pairwise: EvalRun? = nil,
                             ratings: [Rating] = [], rerate: Bool = false,
                             session: String) -> [Item] {
        let byId = Dictionary(fixtures.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rated = RatingLog.ratedKeys(ratings)
        let pairs = RatingLog.pairKeys(ratings)
        var ranked: [(bucket: Int, order: Int, item: Item)] = []
        var order = 0
        for col in run.columns {
            if let column, col.formatter != column { continue }
            let other = pairwise?.columns.first { $0.formatter == col.formatter }
                ?? (pairwise?.columns.count == 1 ? pairwise?.columns.first : nil)
            let otherRows = Dictionary((other?.rows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for row in col.rows {
                order += 1
                guard let fixture = byId[row.id] else { continue }
                let flagged = isFlagged(row)
                let unrated = fixture.isGoldFree
                switch only {
                case .all: break
                case .gated: guard EvalVerdict(rawValue: row.verdict)?.isGated == true else { continue }
                case .flagged: guard flagged else { continue }
                case .unrated: guard unrated else { continue }
                }
                var candidate: PairCandidate?
                if let pairwise, let other {
                    // A pair needs the same fixture measured by both runs;
                    // an output identical in both says nothing and is
                    // dropped rather than shown as a fake choice.
                    guard let otherRow = otherRows[row.id], otherRow.out != row.out else { continue }
                    let key = "\(row.id)\n" + [col.runKey, other.runKey].sorted().joined(separator: "\n")
                    if !rerate, pairs.contains(key) { continue }
                    candidate = PairCandidate(otherRunKey: other.runKey, otherFormatter: other.formatter,
                                              otherOut: otherRow.out,
                                              slot: slot(fixtureId: row.id, session: session))
                } else if pairwise != nil {
                    continue
                } else if !rerate,
                          rated.contains(Rating.Key(fixtureId: row.id, outputSha: Rating.outputSha(row.out))) {
                    continue
                }
                let item = Item(fixture: fixture, formatter: col.formatter, runKey: col.runKey, row: row,
                                flagged: flagged, unrated: unrated, pair: candidate)
                ranked.append((bucket: flagged ? 0 : unrated ? 1 : 2, order: order, item: item))
            }
        }
        return ranked.sorted { ($0.bucket, $0.order) < ($1.bucket, $1.order) }.map(\.item)
    }

    /// §7.1's queue head: a gated verdict, or enough dropped content that
    /// it is probably an over-edit (`EvalThresholds.flaggedDroppedContent`).
    public static func isFlagged(_ row: EvalRun.Row) -> Bool {
        EvalVerdict(rawValue: row.verdict)?.isGated == true
            || row.droppedContent >= EvalThresholds.flaggedDroppedContent
    }
}

// MARK: - The screen

/// One row as he sees it (§7.1): raw, the column's output, the inline word
/// diff off the scorer's own alignment, the fixture's draft annotations,
/// and the progress line. Rendered here so a test can pin every line.
public struct RatingScreen: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable { case triage, pairwise }

    public var mode: Mode
    public var index: Int
    public var total: Int
    public var elapsedSeconds: Int
    public var fixtureId: String
    public var formatter: String
    public var register: String
    public var flagged: Bool
    public var raw: String
    public var out: String
    public var slotA: String
    public var slotB: String
    /// `[-dropped-]{+added+}` off `Align`'s ops, against the gold when the
    /// fixture has one, else against raw.
    public var diff: String
    /// The contiguous dropped spans `k` can mark as `must_keep`.
    public var droppedSpans: [String]
    /// The fixture's own annotations (gold, status, must_keep, repairs).
    public var annotations: [String]
    /// The metric's own verdict line — printed so the two can be compared,
    /// never as a suggestion of what to press.
    public var metric: String
    /// What this row has pending (marks, an edit, an alternate gold).
    public var pending: [String]
    /// The key line for the state he is in.
    public var keys: [String]

    public func render() -> String {
        var lines: [String] = []
        let progress = "[\(index)/\(total)]  \(fixtureId) · \(formatter) · \(register)"
            + (flagged ? " · FLAGGED" : "") + "  (\(RatingScreen.clock(elapsedSeconds)))"
        lines.append(progress)
        lines.append("  raw   " + flat(raw))
        switch mode {
        case .triage:
            lines.append("  out   " + flat(out))
            lines.append("  diff  " + flat(diff))
        case .pairwise:
            lines.append("  A     " + flat(slotA))
            lines.append("  B     " + flat(slotB))
        }
        if !droppedSpans.isEmpty {
            lines.append("  drop  " + droppedSpans.enumerated()
                .map { "\($0.offset + 1)) \($0.element)" }.joined(separator: "  "))
        }
        for annotation in annotations { lines.append("  note  " + annotation) }
        if !metric.isEmpty { lines.append("  metric " + metric) }
        for line in pending { lines.append("  ✎     " + line) }
        lines += keys.map { "  " + $0 }
        return lines.joined(separator: "\n")
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func flat(_ text: String) -> String {
        text.isEmpty ? "(empty)" : text.replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    /// The dropped spans of a reference↔output alignment: maximal runs of
    /// reference words the output does not carry, surfaced as he said
    /// them. These are what `k` marks — a `must_keep` is a contiguous
    /// span, never a scattered word list.
    public static func droppedSpans(reference: String, out: String) -> [String] {
        let a = Align.canonicalTokens(reference)
        let b = Align.canonicalTokens(out)
        var spans: [String] = []
        var current: [String] = []
        for op in Align.align(a, b).ops {
            switch op {
            case .del(let i):
                current.append(a[i].cased)
            case .sub(let i, let j) where a[i].canonical != b[j].canonical:
                current.append(a[i].cased)
            default:
                if !current.isEmpty { spans.append(current.joined(separator: " ")); current = [] }
            }
        }
        if !current.isEmpty { spans.append(current.joined(separator: " ")) }
        return spans
    }

    /// The fixture's annotations as lines: what a `y` confirms and what an
    /// `e` edit starts from.
    public static func annotations(_ c: EvalCase) -> [String] {
        var lines: [String] = []
        if c.isGoldFree {
            lines.append("gold  (none yet — \(c.goldSource))")
        } else {
            lines.append("gold  \(c.gold.isEmpty ? "(empty — paste nothing)" : c.gold)"
                         + "  [\(c.goldSource) · \(c.annotationsStatus.rawValue)]")
        }
        for alt in c.golds { lines.append("also  \(alt)") }
        if !c.mustKeep.isEmpty {
            lines.append("keep  " + c.mustKeep.map { "\"\($0.span)\" (w\($0.weight))" }.joined(separator: " · "))
        }
        for repair in c.repairs {
            lines.append("fix   \"\(repair.reparandum)\" → \"\(repair.repair)\" @\(repair.resolveAt.rawValue)")
        }
        if !c.tags.isEmpty { lines.append("tags  " + c.tags.joined(separator: ", ")) }
        return lines
    }

    /// The metric's own line for a row, so his verdict and the scorer's
    /// sit side by side (calibration check 2 measures the gap).
    public static func metric(_ row: EvalRun.Row) -> String {
        EvalReport.rowSummary(row)
    }
}

// MARK: - The state machine

/// Keys in, records out (§7.1). The bench reads one keystroke (raw mode)
/// or one line (scripted mode) and hands it here; every side effect it
/// must perform comes back as an `Effect`, so the loop itself holds no
/// policy and XCTest drives the whole thing with a string array.
public struct RatingSession: Sendable {
    public enum Effect: Sendable, Equatable {
        /// Append this record to `ratings.jsonl`.
        case write(Rating)
        /// Open `$EDITOR` on `text` (a 0600 temp file, deleted after) and
        /// call `applyEdit` with the result.
        case openEditor(text: String, fixtureId: String)
        /// A line to print (feedback, help, a refusal).
        case note(String)
        /// The queue is done (or he pressed `q`).
        case finished(Summary)
    }

    public struct Summary: Sendable, Equatable {
        public var queued: Int
        public var rated: Int
        public var skipped: Int
        public var pairs: Int
        public var quit: Bool
        public var counts: [String: RatingLog.Counts]
        public var elapsedSeconds: Int

        public func render() -> String {
            var lines = ["rated \(rated) of \(queued)" + (skipped > 0 ? " · skipped \(skipped)" : "")
                         + (pairs > 0 ? " · pairs \(pairs)" : "")
                         + " · \(RatingScreen.clock(elapsedSeconds))" + (quit ? " · quit" : "")]
            for formatter in counts.keys.sorted() {
                let c = counts[formatter]!
                let zero = c.zeroEditRate.map { String(format: "%.1f%%", $0) } ?? "—"
                lines.append("  " + formatter.padding(toLength: max(10, formatter.count), withPad: " ", startingAt: 0)
                             + " ship \(c.ship) fix \(c.fix) wrong \(c.wrong) · zero-edit \(zero)")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Which keys the current state takes.
    enum State: Equatable {
        case verdict
        case tags(Rating.Verdict)
        case mark(weight: Int)
        case editing
        case pair
        case done
    }

    public let items: [RatingQueue.Item]
    public let session: String
    private let now: @Sendable () -> Date
    private let startedAt: Date

    private var index = 0
    private var state: State = .verdict
    private var shownAt: Date
    private var pendingTags: [String] = []
    private var pendingMustKeep: [EvalCase.MustKeep] = []
    private var pendingGoldEdit: String?
    private var pendingAltGold: String?
    private var rated = 0
    private var skipped = 0
    private var pairs = 0
    private var quit = false
    private var counts: [String: RatingLog.Counts] = [:]

    public init(items: [RatingQueue.Item], session: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.items = items
        self.session = session
        self.now = now
        startedAt = now()
        shownAt = startedAt
        state = items.first?.isPairwise == true ? .pair : .verdict
        if items.isEmpty { state = .done }
    }

    public var isFinished: Bool { state == .done }
    public var current: RatingQueue.Item? { index < items.count ? items[index] : nil }

    /// The screen for the row he is on, nil when the queue is done.
    public var screen: RatingScreen? {
        guard let item = current else { return nil }
        let reference = item.fixture.isGoldFree ? item.fixture.raw : item.fixture.gold
        var pending: [String] = []
        if !pendingMustKeep.isEmpty {
            pending.append("must_keep " + pendingMustKeep.map { "\"\($0.span)\" (w\($0.weight))" }
                .joined(separator: " · "))
        }
        if let edit = pendingGoldEdit { pending.append("gold edit → \(edit)") }
        if let alt = pendingAltGold { pending.append("also fine → \(alt)") }
        if case .tags(let verdict) = state {
            pending.append("verdict \(verdict.rawValue) · tags "
                           + (pendingTags.isEmpty ? "(none yet)" : pendingTags.joined(separator: ", ")))
        }
        let slots = item.pair?.slots(item.row.out) ?? (a: "", b: "")
        return RatingScreen(
            mode: item.isPairwise ? .pairwise : .triage,
            index: index + 1, total: items.count,
            elapsedSeconds: Int(now().timeIntervalSince(startedAt)),
            fixtureId: item.fixture.id, formatter: item.formatter,
            register: item.fixture.register.rawValue, flagged: item.flagged,
            raw: item.fixture.raw, out: item.row.out, slotA: slots.a, slotB: slots.b,
            diff: EvalReport.wordDiff(gold: reference, out: item.row.out),
            droppedSpans: item.isPairwise ? [] : RatingScreen.droppedSpans(reference: reference, out: item.row.out),
            annotations: RatingScreen.annotations(item.fixture),
            metric: RatingScreen.metric(item.row),
            pending: pending,
            keys: keyLines)
    }

    /// The screen plus its key line — what the bench prints before reading.
    public var prompt: String { screen?.render() ?? "" }

    var keyLines: [String] {
        switch state {
        case .verdict:
            return ["1 ship · 2 fix · 3 wrong · k/K mark must_keep (w2/w5) · e edit gold · = also fine · s skip · y confirm · q quit"]
        case .tags(let verdict):
            return RatingChips.menu(selected: pendingTags)
                + ["enter = record \(verdict.rawValue) · s skip · q quit"]
        case .mark(let weight):
            return ["number = mark that span must_keep (w\(weight)) · enter = back · q quit"]
        case .editing:
            return ["(editor open)"]
        case .pair:
            return ["a = A better · b = B better · = equal · s skip · q quit"]
        case .done:
            return []
        }
    }

    /// The help `?` prints — the same text the usage line carries.
    public static let help = """
    triage    1 SHIP (paste it untouched) · 2 FIX (punctuation or case only) · 3 WRONG (meaning changed)
              on 2/3 a tag picker opens: a..m toggle a chip, enter records
    marks     k mark a dropped span must_keep (weight 2) · K the same at weight 5 (a fact)
    gold      e edit the gold in $EDITOR · = this output is also fine (alternate gold)
    pass      s skip this row · y confirm the fixture's draft annotations as they stand
    pairwise  a / b pick a blind slot · = equally good
    quit      q — records already written stay
    """

    /// One key (raw mode) or one line (scripted mode).
    public mutating func handle(_ key: String) -> [Effect] {
        guard !isFinished else { return [] }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key == "?" || key == "h" { return [.note(Self.help)] }
        switch state {
        case .verdict: return handleVerdict(key)
        case .tags(let verdict): return handleTags(key, verdict: verdict)
        case .mark(let weight): return handleMark(key, weight: weight)
        case .pair: return handlePair(key)
        case .editing: return [.note("waiting for the editor")]
        case .done: return []
        }
    }

    /// Standard input ran out (scripted mode, or a closed pipe): finish
    /// cleanly with what was written rather than blocking on EOF.
    public mutating func endOfInput() -> [Effect] {
        guard !isFinished else { return [] }
        return finish(quit: true)
    }

    /// The `$EDITOR` came back: nil (or unchanged text) leaves the row
    /// alone, anything else becomes this row's `gold_edit`.
    public mutating func applyEdit(_ text: String?) -> [Effect] {
        guard state == .editing else { return [] }
        state = current?.isPairwise == true ? .pair : .verdict
        guard let item = current else { return [] }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return [.note("gold unchanged")] }
        guard trimmed != editorSeed(item) else { return [.note("gold unchanged")] }
        pendingGoldEdit = trimmed
        return [.note("gold edit staged — press 1/2/3 to record it")]
    }

    // MARK: State handlers

    private mutating func handleVerdict(_ key: String) -> [Effect] {
        switch key {
        case "1": return record(verdict: .ship)
        case "2", "3":
            state = .tags(key == "2" ? .fix : .wrong)
            return [.note("tags — a..m toggle, enter records")]
        case "k", "K":
            let weight = key == "k" ? EvalCase.MustKeep.hedgeWeight : EvalCase.MustKeep.factWeight
            guard let item = current, !droppedSpans(item).isEmpty else {
                return [.note("nothing dropped on this row to mark")]
            }
            state = .mark(weight: weight)
            return [.note("mark a span must_keep at weight \(weight)")]
        case "e":
            guard let item = current else { return [] }
            state = .editing
            return [.openEditor(text: editorSeed(item), fixtureId: item.fixture.id)]
        case "=":
            guard let item = current else { return [] }
            pendingAltGold = item.row.out
            return [.note("marked also-fine — press 1/2/3 to record it")]
        case "s": return skip()
        case "y": return confirmAnnotations()
        case "q": return finish(quit: true)
        case "": return []
        default:
            return [.note("unknown key '\(key)' — 1 ship · 2 fix · 3 wrong · ? for help")]
        }
    }

    private mutating func handleTags(_ key: String, verdict: Rating.Verdict) -> [Effect] {
        switch key {
        case "":
            return record(verdict: verdict)
        case "s":
            return skip()
        case "q":
            return finish(quit: true)
        default:
            guard let chip = RatingChips.chip(forKey: key) else {
                return [.note("unknown chip key '\(key)' — a..m, enter to record")]
            }
            if let at = pendingTags.firstIndex(of: chip) {
                pendingTags.remove(at: at)
                return [.note("− \(chip)")]
            }
            pendingTags.append(chip)
            return [.note("+ \(chip)")]
        }
    }

    private mutating func handleMark(_ key: String, weight: Int) -> [Effect] {
        switch key {
        case "":
            state = .verdict
            return []
        case "q":
            return finish(quit: true)
        default:
            guard let item = current, let n = Int(key), n >= 1 else {
                return [.note("a span number, or enter to go back")]
            }
            let spans = droppedSpans(item)
            guard n <= spans.count else { return [.note("no span \(n) — \(spans.count) dropped")] }
            let span = spans[n - 1]
            if let at = pendingMustKeep.firstIndex(where: { $0.span == span }) {
                pendingMustKeep.remove(at: at)
                return [.note("− must_keep \"\(span)\"")]
            }
            pendingMustKeep.append(EvalCase.MustKeep(span: span, weight: weight))
            return [.note("+ must_keep \"\(span)\" (w\(weight))")]
        }
    }

    private mutating func handlePair(_ key: String) -> [Effect] {
        switch key {
        case "a", "b", "=":
            guard let item = current, let candidate = item.pair else { return [] }
            // `a_run` is the run shown in SLOT A, not this item's own run.
            // With the primary run always on the `a_run` side, `preference`
            // is +1 every time he prefers it, and τ_b's y column goes
            // constant exactly when he agrees with the metric most —
            // undefined where the signal is strongest (§7.4 check 5). The
            // blind slot already randomises which run sits in A, so
            // recording by slot costs nothing and keeps y varying.
            let mineInA = candidate.slot == "a"
            let pair = Rating.Pair(aRun: mineInA ? item.runKey : candidate.otherRunKey,
                                   bRun: mineInA ? candidate.otherRunKey : item.runKey,
                                   slot: "a", pick: key)
            let rating = Rating(fixtureId: item.fixture.id, runKey: item.runKey, formatter: item.formatter,
                                outputSha: Rating.outputSha(item.row.out), verdict: nil,
                                pair: pair, msToRate: elapsedMs(), ratedAt: Rating.timestamp(now()),
                                session: session)
            pairs += 1
            return [.write(rating)] + advance()
        case "s": return skip()
        case "q": return finish(quit: true)
        case "": return []
        default:
            return [.note("unknown key '\(key)' — a · b · = · s · q")]
        }
    }

    // MARK: Records

    private mutating func record(verdict: Rating.Verdict) -> [Effect] {
        guard let item = current else { return [] }
        let rating = Rating(fixtureId: item.fixture.id, runKey: item.runKey, formatter: item.formatter,
                            outputSha: Rating.outputSha(item.row.out), verdict: verdict,
                            tags: pendingTags, mustKeep: pendingMustKeep, shouldGo: [],
                            goldEdit: pendingGoldEdit, altGold: pendingAltGold,
                            msToRate: elapsedMs(), ratedAt: Rating.timestamp(now()), session: session)
        rated += 1
        counts[item.formatter, default: RatingLog.Counts()].add(verdict)
        return [.write(rating)] + advance()
    }

    /// `y`: the fixture's own annotations are right as they stand. No
    /// verdict on the output — `gold` reads this record to flip
    /// `annotations_status` to confirmed and drop the `unrated` tag. What
    /// he staged first (an edit, an also-fine, marked spans) rides along.
    /// A staged GOLD is why such a record counts as rated
    /// (`carriesAGold`): it is recorded, and the row must not come back
    /// asking him to type it a second time. A mark alone does not — that
    /// row still owes a verdict and comes back for it.
    private mutating func confirmAnnotations() -> [Effect] {
        guard let item = current else { return [] }
        let rating = Rating(fixtureId: item.fixture.id, runKey: item.runKey, formatter: item.formatter,
                            outputSha: Rating.outputSha(item.row.out), verdict: nil,
                            tags: pendingTags, mustKeep: pendingMustKeep, shouldGo: [],
                            goldEdit: pendingGoldEdit, altGold: pendingAltGold, confirm: true,
                            msToRate: elapsedMs(), ratedAt: Rating.timestamp(now()), session: session)
        rated += 1
        return [.write(rating), .note("annotations confirmed")] + advance()
    }

    private mutating func skip() -> [Effect] {
        skipped += 1
        return [.note("skipped")] + advance()
    }

    private mutating func advance() -> [Effect] {
        index += 1
        pendingTags = []
        pendingMustKeep = []
        pendingGoldEdit = nil
        pendingAltGold = nil
        shownAt = now()
        guard let item = current else { return finish(quit: false) }
        state = item.isPairwise ? .pair : .verdict
        return []
    }

    private mutating func finish(quit: Bool) -> [Effect] {
        guard state != .done else { return [] }
        self.quit = quit && index < items.count
        state = .done
        return [.finished(summary)]
    }

    public var summary: Summary {
        Summary(queued: items.count, rated: rated, skipped: skipped, pairs: pairs, quit: quit,
                counts: counts, elapsedSeconds: Int(now().timeIntervalSince(startedAt)))
    }

    // MARK: Helpers

    private func droppedSpans(_ item: RatingQueue.Item) -> [String] {
        RatingScreen.droppedSpans(reference: item.fixture.isGoldFree ? item.fixture.raw : item.fixture.gold,
                                  out: item.row.out)
    }

    /// What `$EDITOR` opens on: the fixture's gold when it has one, else
    /// the output he is looking at (a gold-free row is usually one edit
    /// away from its gold).
    private func editorSeed(_ item: RatingQueue.Item) -> String {
        item.fixture.isGoldFree || item.fixture.gold.isEmpty ? item.row.out : item.fixture.gold
    }

    private func elapsedMs() -> Int {
        max(0, Int((now().timeIntervalSince(shownAt) * 1000).rounded()))
    }
}
