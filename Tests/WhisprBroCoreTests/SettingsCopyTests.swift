import XCTest
@testable import WhisprBroCore

/// The words the Auto-Clean controls use, where they live in Core: the
/// level names (Settings, the menu bar and iOS print `displayName` alike),
/// what Settings says the self-repair rules fix and still get wrong (every
/// example held to what the pre-pass does), and what the AI-rewrite
/// controls say when the model is not usable.
final class SettingsCopyTests: XCTestCase {

    // MARK: - Level names

    func testTheMiddleLevelSaysWhatItRemoves() {
        // It strips fillers and, since the self-repair rules, repeated and
        // cut-off words too — "only" no longer described it.
        XCTAssertEqual(AppConfig.Cleanup.Level.fillers.displayName, "Fillers and repeats")
        XCTAssertEqual(AppConfig.Cleanup.Level.verbatim.displayName, "Off (verbatim)")
        XCTAssertEqual(AppConfig.Cleanup.Level.standard.displayName, "Standard (+ corrections)")
        for level in AppConfig.Cleanup.Level.allCases {
            XCTAssertFalse(level.displayName.contains("only"), "\(level)")
        }
    }

    func testTheSavedValuesDoNotMove() {
        // The menu's choice is saved by raw value (UserDefaults
        // "cleanupLevel"): renaming the label must not lose anyone's level.
        XCTAssertEqual(AppConfig.Cleanup.Level.allCases.map(\.rawValue), ["verbatim", "fillers", "standard"])
        XCTAssertEqual(AppConfig.Cleanup.Level(rawValue: "fillers"), .fillers)
    }

    func testTheConfigFilePointsAtTheNamesTheMenuShows() {
        let text = ConfigStore.emit(AppConfig())
        let names = AppConfig.Cleanup.Level.allCases.map(\.displayName).joined(separator: " / ")
        XCTAssertTrue(text.contains(names), "the [cleanup] comment lists the menu's own labels")
        XCTAssertFalse(text.contains("Fillers only"))
    }

    // MARK: - Self-corrections

    private let noDict = DictionaryEngine(rules: [])

    private func prePass(_ text: String, at level: AppConfig.Cleanup.Level, selfRepair: Bool = true) -> String {
        DictationPipeline.prePass(text, dictionary: noDict, stripper: FillerStripper(), level: level,
                                  verbatimRegister: false, language: .english, selfRepair: selfRepair)
    }

    func testEveryFixTheCaptionGivesIsWhatAutoCleanDoes() {
        for example in SelfRepairCopy.fixes {
            XCTAssertEqual(prePass(example.said, at: example.level), example.leaves, example.said)
            XCTAssertEqual(prePass(example.said, at: .standard), example.leaves, "Standard does it too: \(example.said)")
            if example.level == .standard {
                XCTAssertEqual(prePass(example.said, at: .fillers), example.said, "only Standard: \(example.said)")
            }
        }
    }

    func testEveryWordTheCaptionSaysTheRulesStillTakeIsTakenAtItsLevel() {
        for example in SelfRepairCopy.stillTaken {
            XCTAssertEqual(prePass(example.said, at: example.level), example.leaves, example.said)
            switch example.level {
            case .fillers:   // "at both levels"
                XCTAssertEqual(prePass(example.said, at: .standard), example.leaves, "both levels: \(example.said)")
            case .standard:  // "at Standard also"
                XCTAssertEqual(prePass(example.said, at: .fillers), example.said, "Standard only: \(example.said)")
            case .verbatim:
                XCTFail("the caption names no verbatim example")
            }
        }
    }

    func testTheOffSwitchTheCaptionPointsToKeepsThoseWords() {
        // "Fix self-corrections" off: the pre-pass is the filler strip alone,
        // which takes none of them.
        for example in SelfRepairCopy.stillTaken {
            for level in [AppConfig.Cleanup.Level.fillers, .standard] {
                XCTAssertEqual(prePass(example.said, at: level, selfRepair: false), example.said,
                               "\(level): \(example.said)")
            }
        }
    }

    func testTheLevelAndRulesOnlySubtitlesSayWhatThePrePassRemoves() {
        // Each subtitle is held to the pre-pass with "Fix self-corrections"
        // on and off: off, it is the filler strip alone, so repeated and
        // cut-off words stay and no spoken correction is resolved by rules.
        let doubled = "the garden hose hose is leaking"
        let cutOff = "sen sentences"
        let correction = "meet at 2, actually 3"
        for level in [AppConfig.Cleanup.Level.fillers, .standard] {
            for selfRepair in [true, false] {
                let tag = "\(level) self_repair=\(selfRepair)"
                XCTAssertEqual(prePass("um, I I I think so", at: level, selfRepair: selfRepair), "I think so", tag)
                let repeatsGo = prePass(doubled, at: level, selfRepair: selfRepair) != doubled
                let cutOffGo = prePass(cutOff, at: level, selfRepair: selfRepair) != cutOff
                let correctionsGo = prePass(correction, at: level, selfRepair: selfRepair) != correction
                XCTAssertEqual(repeatsGo, selfRepair, tag)
                XCTAssertEqual(cutOffGo, selfRepair, tag)
                XCTAssertEqual(correctionsGo, selfRepair && level == .standard, tag)

                // "Rules only — no AI rewrite": what the rules still remove.
                let rulesOnly = SelfRepairCopy.rulesOnlySubtitle(level, selfRepair: selfRepair)
                XCTAssertTrue(rulesOnly.hasPrefix("Fillers"), tag)
                XCTAssertEqual(rulesOnly.contains("cut-off"), cutOffGo, tag)
                XCTAssertEqual(rulesOnly.contains("repeat"), repeatsGo, tag)
                XCTAssertEqual(rulesOnly.contains("stutters"), !repeatsGo, tag)
                XCTAssertEqual(rulesOnly.contains("spoken corrections are still removed"), correctionsGo, tag)
                XCTAssertEqual(rulesOnly.contains("spoken corrections stay"),
                               level == .standard && !correctionsGo, tag)

                // The level row, with the AI rewrite running or not.
                for aiRewrite in [true, false] {
                    let row = SelfRepairCopy.levelSubtitle(level, selfRepair: selfRepair, aiRewrite: aiRewrite)
                    let rowTag = tag + " aiRewrite=\(aiRewrite)"
                    XCTAssertEqual(row.contains("Also resolves spoken corrections"), correctionsGo, rowTag)
                    if level == .fillers {
                        XCTAssertEqual(row.contains("repeated words and cut-off words"), repeatsGo && cutOffGo, rowTag)
                        XCTAssertEqual(row.contains("stutters"), !repeatsGo, rowTag)
                    } else if !selfRepair {
                        // Only the model can still resolve them, and only when it runs.
                        XCTAssertEqual(row.contains("lets the AI rewrite resolve"), aiRewrite, rowTag)
                        XCTAssertEqual(row.contains("stay"), !aiRewrite, rowTag)
                    }
                    // Off, both say why: the switch, by its name.
                    XCTAssertEqual(row.contains("“\(SelfRepairCopy.switchTitle)” is off"),
                                   !selfRepair && level == .standard, rowTag)
                }
                XCTAssertEqual(rulesOnly.contains("“\(SelfRepairCopy.switchTitle)” is off"),
                               !selfRepair && level == .standard, tag)
            }
        }
        for selfRepair in [true, false] {
            XCTAssertEqual(SelfRepairCopy.levelSubtitle(.verbatim, selfRepair: selfRepair, aiRewrite: true),
                           "Nothing removed — exactly what you said.")
            XCTAssertTrue(SelfRepairCopy.rulesOnlySubtitle(.verbatim, selfRepair: selfRepair).contains("Off"))
        }
    }

    func testTheCaptionGivesEveryExampleAndBothWaysBack() {
        let caption = SelfRepairCopy.howCorrectionsWork
        for example in SelfRepairCopy.fixes + SelfRepairCopy.stillTaken {
            XCTAssertTrue(caption.contains("“\(example.said)”"), example.said)
        }
        XCTAssertTrue(caption.contains("“meet at 3”"))
        XCTAssertTrue(caption.contains("“\(SelfRepairCopy.undoItem)” in the menu bar"))
        XCTAssertTrue(caption.contains("“\(SelfRepairCopy.switchTitle)” above turns the rules off"))
        XCTAssertTrue(SelfRepairCopy.switchCaption.contains("self_repair"))
        XCTAssertTrue(ConfigStore.emit(AppConfig()).contains("self_repair = true   # fix self-corrections"))
    }

    func testTheCaptionNamesACorrectionTheRulesMisread() {
        // The commonest damage left at Standard: a cued correction whose words the rules misread
        // (NLTagger reads "grab" as a noun, so "scratch that" finds no verb phrase and takes the
        // whole clause back, "Let's" with it). The caption names the class and gives the example.
        let caption = SelfRepairCopy.howCorrectionsWork
        XCTAssertTrue(caption.contains("a correction whose words they misread"))
        let misread = SelfRepairCopy.stillTaken.filter { $0.said.contains("scratch that") }
        XCTAssertEqual(misread.map(\.said), ["Let’s grab lunch, scratch that, get coffee"])
        XCTAssertEqual(misread.map(\.level), [.standard])
        XCTAssertTrue(caption.contains("leaves only “Get coffee”"))
        XCTAssertEqual(prePass("Let’s grab lunch, scratch that, get coffee", at: .standard), "Get coffee")
    }

    func testTheSwitchCaptionSaysStuttersGoOnlyWhileCollapseStuttersIsOn() {
        // "Fix self-corrections" off: fillers go, and stutters only while
        // [cleanup] collapse_stutters is on — the filler strip's own switch.
        let caption = SelfRepairCopy.switchCaption
        XCTAssertTrue(caption.contains("collapse_stutters"))
        XCTAssertTrue(caption.contains("can still resolve some spoken corrections"))
        for level in [AppConfig.Cleanup.Level.fillers, .standard] {
            for collapse in [true, false] {
                let stripper = FillerStripper(collapseStutters: collapse)
                let out = DictationPipeline.prePass("um, I I I think so", dictionary: noDict, stripper: stripper,
                                                    level: level, verbatimRegister: false, language: .english,
                                                    selfRepair: false)
                XCTAssertEqual(out, collapse ? "I think so" : "I I I think so", "\(level) collapse=\(collapse)")
            }
        }
    }

    func testTheCaptionSaysWhichAppsSkipTheRules() {
        // "In the code editors, terminals and notes apps it recognizes …
        // skipped; other apps — cmux, for one — get both": the skip is the
        // register's, so it holds only for an app the resolver maps to a
        // verbatim category (config.toml's verbatim_categories, by default
        // ide, terminal, notes). cmux resolves to .unknown on purpose
        // (HistoryExport.registerOverrides), so the rules run there in full.
        let caption = SelfRepairCopy.howCorrectionsWork
        XCTAssertTrue(caption.contains("terminals and notes apps it recognizes"))
        XCTAssertTrue(caption.contains("cmux, for one"))
        let verbatim = AppConfig.Cleanup().verbatimCategories
        XCTAssertEqual(verbatim, ["ide", "terminal", "notes"])
        for bundle in ["com.microsoft.VSCode", "com.apple.Terminal", "com.apple.Notes"] {
            XCTAssertTrue(verbatim.contains(AppCategoryResolver.category(bundleId: bundle).rawValue), bundle)
        }
        let cmux = AppCategoryResolver.category(bundleId: "com.cmuxterm.app")
        XCTAssertEqual(cmux, .unknown)
        XCTAssertFalse(verbatim.contains(cmux.rawValue))
        // …and an unrecognized app gets both: the rules and the filler strip.
        XCTAssertEqual(prePass("um, we went over over these", at: .fillers), "we went over these")
    }

    // MARK: - Without the model

    func testEachWayOfBeingWithoutTheModelReadsDifferently() {
        typealias Status = FormattingModelStatus
        XCTAssertEqual(Status(installed: false, available: false, loadFailed: false), .notInstalled)
        XCTAssertEqual(Status(installed: true, available: false, loadFailed: false), .notLoadedYet)
        XCTAssertEqual(Status(installed: true, available: false, loadFailed: true), .failedToLoad)
        XCTAssertEqual(Status(installed: true, available: true, loadFailed: false), .available)
        // In memory is usable, whatever the disk says now.
        XCTAssertEqual(Status(installed: false, available: true, loadFailed: false), .available)
        // A failed load of a file that is gone is a missing file.
        XCTAssertEqual(Status(installed: false, available: false, loadFailed: true), .notInstalled)

        let unusable: [Status] = [.notInstalled, .notLoadedYet, .failedToLoad]
        let settings = unusable.compactMap(\.settingsNote)
        let menu = unusable.compactMap(\.menuNote)
        XCTAssertEqual(Set(settings).count, 3)
        XCTAssertEqual(Set(menu).count, 3)
        XCTAssertNil(Status.available.settingsNote, "the switch shows instead")
        XCTAssertNil(Status.available.menuNote)
        // Only the missing file is called missing.
        XCTAssertTrue(Status.notInstalled.settingsNote!.contains("not installed"))
        XCTAssertTrue(Status.notInstalled.menuNote!.contains("not installed"))
        for status in [Status.notLoadedYet, .failedToLoad] {
            XCTAssertFalse(status.settingsNote!.contains("not installed"), "\(status)")
            XCTAssertFalse(status.menuNote!.contains("not installed"), "\(status)")
            XCTAssertTrue(status.settingsNote!.contains("installed but"), "\(status)")
        }
        XCTAssertTrue(Status.failedToLoad.settingsNote!.contains("failed to load"))
        XCTAssertTrue(Status.failedToLoad.menuNote!.contains("failed to load"))
        XCTAssertTrue(Status.notLoadedYet.settingsNote!.contains("not loaded yet"))
    }
}
