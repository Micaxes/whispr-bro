import Foundation

/// A string compared code point by code point.
///
/// `SelfRepair` is a port of a reference written against Python's `str`, and
/// it has to agree with that reference byte for byte (docs/self-repair.md).
/// Swift's `String` compares by canonical equivalence — "é" written as one
/// scalar equals "e" + U+0301 — and Python compares code points. Every word
/// the rules compare, look up, or measure is one of these, so a word means
/// what it means in the reference: the same scalars, counted as scalars.
struct ScalarString: Hashable, ExpressibleByStringLiteral, CustomStringConvertible, Sendable {
    var scalars: [Unicode.Scalar]

    init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }
    init<S: Sequence>(_ scalars: S) where S.Element == Unicode.Scalar { self.scalars = Array(scalars) }
    init(stringLiteral value: String) { scalars = Array(value.unicodeScalars) }

    var count: Int { scalars.count }
    var isEmpty: Bool { scalars.isEmpty }
    var first: Unicode.Scalar? { scalars.first }
    var description: String { String(String.UnicodeScalarView(scalars)) }

    func hasPrefix(_ other: ScalarString) -> Bool {
        other.count <= count && scalars.starts(with: other.scalars)
    }

    func hasSuffix(_ other: ScalarString) -> Bool {
        other.count <= count && scalars.suffix(other.count).elementsEqual(other.scalars)
    }

    /// `s[:-1]` — everything but the last scalar.
    var droppingLast: ScalarString { ScalarString(scalars.dropLast()) }

    static func + (a: ScalarString, b: ScalarString) -> ScalarString {
        ScalarString(a.scalars + b.scalars)
    }
}

/// Python's `str` character classes and case mappings, which the reference's
/// token model is written in (`isalnum`, `isupper`, `lower`, `split`, …).
/// Each is the CPython definition, read off the same Unicode properties
/// CPython's database is generated from; the self-repair tests check the
/// ones the rules touch against the reference's own outputs.
enum PyText {
    // MARK: Character classes

    /// `str.isspace()` / the separators `str.split()` and the regex `\s`
    /// use: Zs, or bidi class WS, B or S. That includes U+001C…U+001F, which
    /// Unicode's White_Space (and so `Character.isWhitespace`) does not.
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// `str.isalpha()` for one character: a letter category (Lu Ll Lt Lm Lo)
    /// — not Unicode's Alphabetic property, which also takes marks and Nl.
    static func isAlpha(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    /// `str.isalnum()` for one character: alpha, or any numeric type
    /// (decimal, digit, numeric — "½" and "Ⅻ" count).
    static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        isAlpha(s) || s.properties.numericType != nil
    }

    /// The regex `\d` (CPython: `Py_UNICODE_ISDECIMAL`): a decimal digit, Nd.
    static func isDecimal(_ s: Unicode.Scalar) -> Bool {
        s.properties.numericType == .decimal
    }

    /// `str.isdigit()` for one character: numeric type decimal or digit.
    static func isDigit(_ s: Unicode.Scalar) -> Bool {
        let type = s.properties.numericType
        return type == .decimal || type == .digit
    }

    /// `str.isupper()` / `str.islower()` for ONE character: the Uppercase /
    /// Lowercase properties (CPython's single-character shortcut).
    static func isUpperChar(_ s: Unicode.Scalar) -> Bool { s.properties.isUppercase }
    static func isLowerChar(_ s: Unicode.Scalar) -> Bool { s.properties.isLowercase }
    private static func isTitleChar(_ s: Unicode.Scalar) -> Bool {
        s.properties.generalCategory == .titlecaseLetter
    }

    static func isASCII<C: Collection>(_ s: C) -> Bool where C.Element == Unicode.Scalar {
        s.allSatisfy(\.isASCII)
    }

    /// `str.isalpha()`: non-empty and every character a letter.
    static func isAlpha<C: Collection>(_ s: C) -> Bool where C.Element == Unicode.Scalar {
        !s.isEmpty && s.allSatisfy(isAlpha)
    }

    /// `str.isupper()`: at least one uppercase character and no lowercase or
    /// titlecase one. A single character takes the shortcut above.
    static func isUpper<C: Collection>(_ s: C) -> Bool where C.Element == Unicode.Scalar {
        if s.count == 1, let only = s.first { return isUpperChar(only) }
        var cased = false
        for ch in s {
            if isLowerChar(ch) || isTitleChar(ch) { return false }
            if isUpperChar(ch) { cased = true }
        }
        return cased
    }

    /// `str.islower()`: at least one lowercase character and no uppercase or
    /// titlecase one.
    static func isLower<C: Collection>(_ s: C) -> Bool where C.Element == Unicode.Scalar {
        if s.count == 1, let only = s.first { return isLowerChar(only) }
        var cased = false
        for ch in s {
            if isUpperChar(ch) || isTitleChar(ch) { return false }
            if isLowerChar(ch) { cased = true }
        }
        return cased
    }

    // MARK: Case mapping

    /// `str.lower()`: the full lowercase mapping of each character, plus the
    /// one contextual rule CPython applies — a capital sigma that ends a word
    /// becomes the final form "ς" (Unicode's Final_Sigma condition).
    static func lower<C: Collection>(_ s: C) -> [Unicode.Scalar]
    where C.Element == Unicode.Scalar, C.Index == Int {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.count)
        for i in s.indices {
            let ch = s[i]
            if ch.isASCII {
                let v = ch.value
                out.append((0x41...0x5A).contains(v) ? Unicode.Scalar(v + 0x20)! : ch)
            } else if ch.value == 0x3A3 {
                out.append(finalSigma(s, at: i) ? "\u{3C2}" : "\u{3C3}")
            } else {
                out.append(contentsOf: ch.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return out
    }

    /// `str.upper()`: the full uppercase mapping ("ß" → "SS").
    static func upper<C: Collection>(_ s: C) -> [Unicode.Scalar] where C.Element == Unicode.Scalar {
        var out: [Unicode.Scalar] = []
        for ch in s {
            if ch.isASCII {
                let v = ch.value
                out.append((0x61...0x7A).contains(v) ? Unicode.Scalar(v - 0x20)! : ch)
            } else {
                out.append(contentsOf: ch.properties.uppercaseMapping.unicodeScalars)
            }
        }
        return out
    }

    /// CPython's `handle_capital_sigma`: Σ is final when a cased character
    /// precedes it (skipping case-ignorable ones) and none follows.
    private static func finalSigma<C: Collection>(_ s: C, at i: Int) -> Bool
    where C.Element == Unicode.Scalar, C.Index == Int {
        var j = i - 1
        while j >= s.startIndex, s[j].properties.isCaseIgnorable { j -= 1 }
        guard j >= s.startIndex, s[j].properties.isCased else { return false }
        var k = i + 1
        while k < s.endIndex, s[k].properties.isCaseIgnorable { k += 1 }
        return k == s.endIndex || !s[k].properties.isCased
    }

    // MARK: Splitting

    /// `str.split()` with no separator, as scalar ranges (the regex `\S+`).
    static func tokenRanges(_ text: [Unicode.Scalar]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        let n = text.count
        while i < n {
            while i < n, isSpace(text[i]) { i += 1 }
            guard i < n else { break }
            var j = i
            while j < n, !isSpace(text[j]) { j += 1 }
            ranges.append(i..<j)
            i = j
        }
        return ranges
    }
}
