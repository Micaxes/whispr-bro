import Foundation

/// What Settings says about the self-repair rules — Auto-Clean's
/// "Self-corrections" switch and the "How corrections work" caption — kept
/// in Core so the words cannot drift from the rules. Every example the
/// caption gives, the fixes and the words it still takes, is held to what
/// the app's pre-pass does with it today (`SettingsCopyTests`): a change to
/// the rules that fixes or breaks one fails that test until the caption
/// says so too.
public enum SelfRepairCopy {
    /// One example the caption gives: what was said, the level the caption
    /// names for it, and what Auto-Clean's pre-pass leaves of it there.
    public struct Example: Sendable, Equatable {
        public let said: String
        public let level: AppConfig.Cleanup.Level
        public let leaves: String

        public init(said: String, level: AppConfig.Cleanup.Level, leaves: String) {
            self.said = said
            self.level = level
            self.leaves = leaves
        }
    }

    // MARK: - The switch

    /// The "Fix self-corrections" toggle (`[cleanup] self_repair`).
    public static let switchTitle = "Fix self-corrections"
    public static let switchSubtitle = "Removes what you take back mid-sentence."
    public static let switchCaption = "Off, Auto-Clean removes only fillers (“um”, “uh”) and, while collapse_stutters is on (the default), stutters (“I I I”) — turn it off if it takes words you meant. At Standard with AI rewrite on, the model can still resolve some spoken corrections. Saved in config.toml (self_repair, collapse_stutters)."

    /// The menu bar item that pastes the last dictation as it was said.
    public static let undoItem = "Undo last Auto-Clean"

    // MARK: - What each level removes

    /// The Auto-Clean level's subtitle, as the switch leaves it: with
    /// "Fix self-corrections" off the pre-pass is the filler strip alone,
    /// so repeated and cut-off words stay, and spoken corrections are left
    /// to the AI rewrite when it runs (`aiRewrite`: the model is usable and
    /// "Rules only" is off) and kept when it does not.
    public static func levelSubtitle(_ level: AppConfig.Cleanup.Level, selfRepair: Bool, aiRewrite: Bool) -> String {
        switch level {
        case .verbatim:
            return "Nothing removed — exactly what you said."
        case .fillers:
            return selfRepair
                ? "Removes fillers (um, uh, er), repeated words and cut-off words. The default."
                : "Removes fillers (um, uh, er) and stutters (“I I I”). The default."
        case .standard:
            if selfRepair {
                return "Also resolves spoken corrections (“Friday, no wait, Saturday”). Opt-in."
            }
            return aiRewrite
                ? "Also lets the AI rewrite resolve spoken corrections (“Friday, no wait, Saturday”) — “\(switchTitle)” is off. Opt-in."
                : "Spoken corrections (“Friday, no wait, Saturday”) stay: “\(switchTitle)” is off and so is the AI rewrite. Opt-in."
        }
    }

    /// The "Rules only — no AI rewrite" toggle's subtitle: what still goes
    /// with the model out, as the switch leaves it.
    public static func rulesOnlySubtitle(_ level: AppConfig.Cleanup.Level, selfRepair: Bool) -> String {
        switch level {
        case .verbatim:
            return "Auto-Clean is Off, so dictations come out exactly as spoken."
        case .fillers:
            return selfRepair
                ? "Fillers, repeated and cut-off words are still removed — by rules."
                : "Fillers and stutters (“I I I”) are still removed — by rules."
        case .standard:
            return selfRepair
                ? "Fillers, repeated and cut-off words, and spoken corrections are still removed — by rules."
                : "Fillers and stutters (“I I I”) are still removed — by rules; spoken corrections stay, as “\(switchTitle)” is off."
        }
    }

    // MARK: - How corrections work

    /// What the rules remove: repeated and cut-off words at both levels
    /// that strip, what is corrected out loud at Standard only.
    public static let fixes: [Example] = [
        Example(said: "the the", level: .fillers, leaves: "the"),
        Example(said: "sen sentences", level: .fillers, leaves: "sentences"),
        Example(said: "meet at 2, actually 3", level: .standard, leaves: "meet at 3"),
    ]

    /// Words the speaker meant that the rules still take (docs/self-repair.md
    /// §7): a double that is meant, at both levels — an English one, or a
    /// word of another language T3 does not list (it lists everyday Italian,
    /// Spanish, Portuguese and French ones: "caldo caldo" stays); at Standard
    /// only, a lower-case abbreviation, a correction described rather than
    /// made that no frame shows (T17), a second true number, and a cued
    /// correction whose words the rules misread — NLTagger reads "grab" in
    /// "Let's grab lunch" as a noun, so "scratch that" finds no verb phrase
    /// and takes the whole clause back, "Let's" with it. (Since v7 R3 keeps
    /// the short words of those languages — since v8 every one the macOS
    /// spelling checkers accept as a word — so "drive safe, ve con cuidado" is
    /// no longer one.)
    public static let stillTaken: [Example] = [
        Example(said: "a great great idea", level: .fillers, leaves: "a great idea"),
        Example(said: "Thank you thank you!", level: .fillers, leaves: "Thank you!"),
        Example(said: "the sea was cristallino cristallino today", level: .fillers,
                leaves: "the sea was cristallino today"),
        Example(said: "the pr is ready", level: .standard, leaves: "the is ready"),
        Example(said: "check what happens with Monday, sorry, Tuesday", level: .standard,
                leaves: "check what happens with Tuesday"),
        Example(said: "I’m 34, actually 35 next week", level: .standard, leaves: "I’m 35 next week"),
        Example(said: "Let’s grab lunch, scratch that, get coffee", level: .standard, leaves: "Get coffee"),
    ]

    /// The "How corrections work" caption.
    public static let howCorrectionsWork = "Repeated words (“the the”) and cut-off words (“sen sentences”) are removed at both levels. “Standard” also takes back what you correct out loud: say “meet at 2, actually 3” and only “meet at 3” is kept. Rules do this, and they only ever delete — when unsure, they keep both. They can still take words you meant: at both levels, a word you doubled on purpose (“a great great idea”, “Thank you thank you!”, or a word of another language they don’t list: “the sea was cristallino cristallino today”); at Standard also a lower-case abbreviation (“the pr is ready”), a correction you describe rather than make (“check what happens with Monday, sorry, Tuesday”), a second true number (“I’m 34, actually 35 next week”), or a correction whose words they misread (“Let’s grab lunch, scratch that, get coffee” leaves only “Get coffee”). “\(undoItem)” in the menu bar pastes exactly what you said; “\(switchTitle)” above turns the rules off. English only. In the code editors, terminals and notes apps it recognizes, filler removal and self-correction are skipped; other apps — cmux, for one — get both."
}
