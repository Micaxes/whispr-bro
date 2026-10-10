import Foundation

/// Reads/writes `config.toml` (spec §4 Config mirror). A minimal, dependency-
/// free TOML reader+writer for whispr-bro's fixed schema — three sections, all
/// string values:
///
///   [[dictionary]]         → AppConfig.dictionary   (from/to pairs)
///   [style]                → AppConfig.style        (category = "directive")
///   [categories]           → AppConfig.categories   ("bundle.id" = "category")
///   [cleanup]              → AppConfig.cleanup      (Auto-Clean knobs: bools, string arrays)
///
/// The app never regenerates the file once it exists: a Settings switch
/// that lives here (`[cleanup] self_repair`) is written in place, that one
/// line, by `setCleanupSwitch`.
///
/// The parser is tolerant: comments, blank lines, basic ("…") and literal
/// ('…') strings, bare or quoted keys, trailing comments. Unknown tables/keys
/// are skipped rather than rejected, so a hand-edit never bricks startup.
public enum ConfigStore {
    public static var url: URL { Paths.home.appendingPathComponent("config.toml") }

    /// Load the config, or an empty one if the file is absent.
    public static func load() -> AppConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return AppConfig() }
        return parse(text)
    }

    /// Write the config as TOML (with a self-documenting header). Comments in a
    /// prior hand-edited file are not preserved — this is a regenerated mirror.
    public static func save(_ config: AppConfig) throws {
        try Paths.ensureDirectories()
        try emit(config).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Ensure a starter config exists (self-documenting, empty dictionary).
    public static func ensureDefault() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? save(AppConfig())
    }

    // MARK: - Parse

    private enum Section { case none, dictEntry, style, categories, cleanup }

    static func parse(_ text: String) -> AppConfig {
        var config = AppConfig()
        var section: Section = .none
        var entry: AppConfig.DictEntry?

        func flush() {
            if let e = entry, !e.from.isEmpty { config.dictionary.append(e) }
            entry = nil
        }

        // Normalize CRLF/CR to LF so a Windows-edited file isn't silently
        // wiped (a trailing \r on a header would fail the == checks below).
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            // Strip a trailing comment (quote-aware) so `[style] # note` and
            // `key = "v" # note` both work, then trim.
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line == "[[dictionary]]" {
                flush(); entry = AppConfig.DictEntry(from: "", to: ""); section = .dictEntry
            } else if line == "[style]" {
                flush(); section = .style
            } else if line == "[categories]" {
                flush(); section = .categories
            } else if line == "[cleanup]" {
                flush(); section = .cleanup
            } else if line.hasPrefix("[") {
                flush(); section = .none // unknown table — ignore its keys
            } else if section == .cleanup {
                parseCleanup(line, into: &config.cleanup)
            } else if let (key, value) = parseKeyValue(line) {
                switch section {
                case .dictEntry:
                    if key == "from" { entry?.from = value }
                    else if key == "to" { entry?.to = value }
                case .style: config.style[key] = value
                case .categories: config.categories[key] = value
                case .none, .cleanup: break
                }
            }
        }
        flush()
        return config
    }

    /// Remove a trailing `# comment`, but not a `#` inside a quoted string.
    private static func stripComment(_ line: String) -> String {
        String(line[line.startIndex..<commentStart(line)])
    }

    /// Where a trailing `# comment` starts (quote-aware), or the end.
    private static func commentStart(_ line: String) -> String.Index {
        var inBasic = false, inLiteral = false, escaped = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if escaped { escaped = false }
            else if inBasic, c == "\\" { escaped = true }
            else if c == "\"", !inLiteral { inBasic.toggle() }
            else if c == "'", !inBasic { inLiteral.toggle() }
            else if c == "#", !inBasic, !inLiteral { return i }
            i = line.index(after: i)
        }
        return line.endIndex
    }

    /// Parse `key = "value"` (quote-aware): key may be bare or quoted, value is
    /// a basic or literal string. Returns nil on a line we can't understand.
    private static func parseKeyValue(_ line: String) -> (key: String, value: String)? {
        var chars = Substring(line)
        guard let key = scanKey(&chars) else { return nil }
        chars = chars.drop { $0 == " " || $0 == "\t" }
        guard chars.first == "=" else { return nil }
        chars = chars.dropFirst().drop { $0 == " " || $0 == "\t" }
        guard let value = scanString(&chars) else { return nil }
        return (key, value)
    }

    /// Parse one `[cleanup]` line. Tolerant: an unknown key or an unparseable
    /// value for a known key is ignored (a hand-edit never bricks startup).
    static func parseCleanup(_ line: String, into c: inout AppConfig.Cleanup) {
        var chars = Substring(line)
        guard let key = scanKey(&chars) else { return }
        chars = chars.drop { $0 == " " || $0 == "\t" }
        guard chars.first == "=" else { return }
        chars = chars.dropFirst().drop { $0 == " " || $0 == "\t" }
        let rhs = String(chars).trimmingCharacters(in: .whitespaces)
        switch key {
        case "self_repair": if let b = scanBool(rhs) { c.selfRepair = b }
        case "collapse_stutters": if let b = scanBool(rhs) { c.collapseStutters = b }
        case "fillers": if let arr = scanStringArray(rhs) { c.extraFillers = arr }
        case "disable_fillers": if let arr = scanStringArray(rhs) { c.disabledFillers = arr }
        case "verbatim_categories": if let arr = scanStringArray(rhs) { c.verbatimCategories = arr }
        default: break // unknown / retired key (level lives in the menu) — ignore
        }
    }

    private static func scanBool(_ rhs: String) -> Bool? {
        switch rhs.lowercased() { case "true": return true; case "false": return false; default: return nil }
    }

    /// Parse a TOML array of strings `["a", "b"]`; nil if not a well-formed array.
    private static func scanStringArray(_ rhs: String) -> [String]? {
        guard rhs.first == "[", rhs.last == "]" else { return nil }
        var body = Substring(rhs.dropFirst().dropLast())
        var out: [String] = []
        while true {
            body = body.drop { $0 == " " || $0 == "\t" || $0 == "," }
            guard let first = body.first else { break }
            guard first == "\"" || first == "'" else { return nil } // only string elements
            guard let s = scanString(&body) else { return nil }
            out.append(s)
        }
        return out
    }

    private static func scanKey(_ s: inout Substring) -> String? {
        s = s.drop { $0 == " " || $0 == "\t" }
        if s.first == "\"" || s.first == "'" { return scanString(&s) }
        let key = s.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
        guard !key.isEmpty else { return nil }
        s = s.dropFirst(key.count)
        return String(key)
    }

    private static func scanString(_ s: inout Substring) -> String? {
        guard let quote = s.first, quote == "\"" || quote == "'" else { return nil }
        s = s.dropFirst()
        var out = ""
        let literal = quote == "'"
        while let c = s.first {
            s = s.dropFirst()
            if c == quote { return out }
            if !literal && c == "\\", let esc = s.first {
                s = s.dropFirst()
                switch esc {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(esc)
                }
            } else {
                out.append(c)
            }
        }
        return nil // unterminated
    }

    // MARK: - Emit

    static func emit(_ config: AppConfig) -> String {
        var out = """
        # whispr-bro config — hand-edit this file, then choose "Reload config"
        # from the menu bar (or relaunch). It is regenerated on export, so
        # comments you add here are not preserved.

        # Personal dictionary: a spoken phrase → its exact spelling. Multi-word
        # sources tolerate the punctuation/casing the transcriber inserts.
        #   [[dictionary]]
        #   from = "get user data"
        #   to   = "getUserData"

        """
        for e in config.dictionary {
            out += "\n[[dictionary]]\nfrom = \(quote(e.from))\nto = \(quote(e.to))\n"
        }
        if !config.style.isEmpty {
            out += "\n# Per-app style overrides. Categories: messaging, mail,\n"
            out += "# browser, ide, terminal, notes, unknown.\n[style]\n"
            for key in config.style.keys.sorted() {
                out += "\(emitKey(key)) = \(quote(config.style[key]!))\n"
            }
        }
        if !config.categories.isEmpty {
            out += "\n# Map an app's bundle id to a category (quote the bundle id).\n[categories]\n"
            for key in config.categories.keys.sorted() {
                out += "\(quote(key)) = \(quote(config.categories[key]!))\n"
            }
        }
        out += emitCleanup(config.cleanup)
        return out
    }

    /// Always emit the [cleanup] section so its knobs are discoverable. The
    /// aggressiveness LEVEL is a menu control (its labels: `Level.displayName`),
    /// not a config key, so it is intentionally absent here.
    private static func emitCleanup(_ c: AppConfig.Cleanup) -> String {
        let levels = AppConfig.Cleanup.Level.allCases.map(\.displayName).joined(separator: " / ")
        var out = "\n# Auto-Clean knobs. The on/off/aggressiveness level is the\n"
        out += "# menu control (Auto-Clean: \(levels)).\n"
        out += "[cleanup]\n"
        out += "self_repair = \(c.selfRepair)   # fix self-corrections: what you take back mid-sentence (false: the filler strip alone)\n"
        out += "collapse_stutters = \(c.collapseStutters)   # remove repeated words (\"I I I\" → \"I\", \"the the\" → \"the\")\n"
        out += "fillers = \(emitStringArray(c.extraFillers))            # extra filler tokens to strip\n"
        out += "disable_fillers = \(emitStringArray(c.disabledFillers))    # built-in tokens to KEEP\n"
        out += "verbatim_categories = \(emitStringArray(c.verbatimCategories))   # apps where Auto-Clean is off\n"
        return out
    }

    // MARK: - One switch, in place

    /// Why a switch could not be written to `config.toml`.
    public enum SwitchError: Error, Equatable, CustomStringConvertible {
        /// The edit would have changed more than the one key — a file this
        /// reader cannot follow line by line. Nothing was written.
        case unsafeEdit(key: String)

        public var description: String {
            switch self {
            case .unsafeEdit(let key):
                return "config.toml: setting [cleanup] \(key) in place would change more than that key; edit the file by hand"
            }
        }
    }

    /// Set one `[cleanup]` switch in the file and nothing else — what a
    /// Settings toggle writes. `save` regenerates the whole file (his
    /// comments and his layout go); this rewrites one line, or adds one.
    /// An absent file is first written as `ensureDefault` writes it, its
    /// permissions are kept, and a symlink is written through, not
    /// replaced. Throws, writing nothing, when the edit would change any
    /// other setting (`settingCleanupSwitch`).
    public static func setCleanupSwitch(_ key: String, to value: Bool, at url: URL = ConfigStore.url) throws {
        let target = url.resolvingSymlinksInPath()
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.path) {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try emit(AppConfig()).write(to: target, atomically: true, encoding: .utf8)
        }
        let text = try String(contentsOf: target, encoding: .utf8)
        guard let edited = settingCleanupSwitch(key, to: value, in: text) else {
            throw SwitchError.unsafeEdit(key: key)
        }
        guard edited != text else { return }
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try edited.write(to: target, atomically: true, encoding: .utf8)
        if let permissions {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
    }

    /// `text` with `[cleanup] key = value`, every other byte as it was:
    /// the key's line rewritten in place (its indentation, spacing and
    /// trailing comment kept; every copy of it, since the last one wins),
    /// or, with none, a line added under the `[cleanup]` header, or, with
    /// no `[cleanup]` table, the table appended. nil when the result would
    /// not parse to exactly `text`'s config with that one switch changed —
    /// the check that nothing else moved.
    static func settingCleanupSwitch(_ key: String, to value: Bool, in text: String) -> String? {
        let literal = value ? "true" : "false"
        var lines = text.components(separatedBy: "\n")
        var inCleanup = false
        var header: Int?
        var found = false
        for i in lines.indices {
            // A CRLF file keeps its \r on every line it ends.
            let line = lines[i]
            let cr = line.hasSuffix("\r")
            let body = cr ? String(line.dropLast()) : line
            let bare = stripComment(body).trimmingCharacters(in: .whitespaces)
            if bare.hasPrefix("[") {
                inCleanup = bare == "[cleanup]"
                if inCleanup, header == nil { header = i }
                continue
            }
            guard inCleanup, let valueRange = cleanupValueRange(of: key, in: body) else { continue }
            lines[i] = body.replacingCharacters(in: valueRange, with: literal) + (cr ? "\r" : "")
            found = true
        }
        if !found {
            if let header {
                let cr = lines[header].hasSuffix("\r") ? "\r" : ""
                lines.insert("\(key) = \(literal)" + cr, at: header + 1)
            } else {
                // Appended after a blank line; a file that ends without a
                // newline gets one first.
                if let last = lines.last, !last.isEmpty { lines.append("") }
                lines += ["[cleanup]", "\(key) = \(literal)", ""]
            }
        }
        let edited = lines.joined(separator: "\n")
        // Nothing but the switch may move: parse both and compare.
        var before = parse(text), after = parse(edited)
        guard let read = cleanupSwitch(key, of: after.cleanup), read == value else { return nil }
        setCleanupSwitch(key, to: value, of: &before.cleanup)
        setCleanupSwitch(key, to: value, of: &after.cleanup)
        return before == after ? edited : nil
    }

    /// The value of `key = …` on one `[cleanup]` line: from the first
    /// character after `=` and its spacing to the trailing comment (the
    /// spacing before it kept) or the end. nil for any other line.
    private static func cleanupValueRange(of key: String, in line: String) -> Range<String.Index>? {
        let comment = commentStart(line)
        var chars = line[line.startIndex..<comment]
        guard let found = scanKey(&chars), found == key else { return nil }
        chars = chars.drop { $0 == " " || $0 == "\t" }
        guard chars.first == "=" else { return nil }
        chars = chars.dropFirst().drop { $0 == " " || $0 == "\t" }
        // The value, without the spacing that sets off a trailing comment.
        var end = chars.endIndex
        while end > chars.startIndex {
            let before = chars.index(before: end)
            guard chars[before] == " " || chars[before] == "\t" else { break }
            end = before
        }
        return chars.startIndex..<end
    }

    /// The `[cleanup]` switches a Settings toggle may write.
    private static func cleanupSwitch(_ key: String, of c: AppConfig.Cleanup) -> Bool? {
        switch key {
        case "self_repair": return c.selfRepair
        case "collapse_stutters": return c.collapseStutters
        default: return nil
        }
    }

    private static func setCleanupSwitch(_ key: String, to value: Bool, of c: inout AppConfig.Cleanup) {
        switch key {
        case "self_repair": c.selfRepair = value
        case "collapse_stutters": c.collapseStutters = value
        default: break
        }
    }

    private static func emitStringArray(_ items: [String]) -> String {
        "[" + items.map { quote($0) }.joined(separator: ", ") + "]"
    }

    /// A bare key if simple, else a quoted key.
    private static func emitKey(_ key: String) -> String {
        let bareOK = !key.isEmpty && key.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
        }
        return bareOK ? key : quote(key)
    }

    private static func quote(_ value: String) -> String {
        var escaped = ""
        for c in value {
            switch c {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            default: escaped.append(c)
            }
        }
        return "\"\(escaped)\""
    }
}
