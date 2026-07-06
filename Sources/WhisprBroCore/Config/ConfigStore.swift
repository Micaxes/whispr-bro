import Foundation

/// Reads/writes `config.toml` (spec §4 Config mirror). A minimal, dependency-
/// free TOML reader+writer for whispr-bro's fixed schema — three sections, all
/// string values:
///
///   [[dictionary]]         → AppConfig.dictionary   (from/to pairs)
///   [style]                → AppConfig.style        (category = "directive")
///   [categories]           → AppConfig.categories   ("bundle.id" = "category")
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
        var inBasic = false, inLiteral = false, escaped = false
        var end = line.endIndex
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if escaped { escaped = false }
            else if inBasic, c == "\\" { escaped = true }
            else if c == "\"", !inLiteral { inBasic.toggle() }
            else if c == "'", !inBasic { inLiteral.toggle() }
            else if c == "#", !inBasic, !inLiteral { end = i; break }
            i = line.index(after: i)
        }
        return String(line[line.startIndex..<end])
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
    /// aggressiveness LEVEL is a menu control (Off / Fillers / Standard), not a
    /// config key, so it is intentionally absent here.
    private static func emitCleanup(_ c: AppConfig.Cleanup) -> String {
        var out = "\n# Auto-Clean knobs. The on/off/aggressiveness level is the\n"
        out += "# menu control (Auto-Clean: Off / Fillers only / Standard).\n"
        out += "[cleanup]\n"
        out += "collapse_stutters = \(c.collapseStutters)   # collapse \"I I I\" → \"I\"\n"
        out += "fillers = \(emitStringArray(c.extraFillers))            # extra filler tokens to strip\n"
        out += "disable_fillers = \(emitStringArray(c.disabledFillers))    # built-in tokens to KEEP\n"
        out += "verbatim_categories = \(emitStringArray(c.verbatimCategories))   # apps where Auto-Clean is off\n"
        return out
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
