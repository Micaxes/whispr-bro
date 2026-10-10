import XCTest
@testable import WhisprBroCore

/// "Rules only — no AI rewrite" (`RulesOnlyMode`): off by default, saved
/// across launches, and every decision `PipelineController` acts on about
/// when the formatting model is in memory. Against an in-memory store: a
/// `UserDefaults` suite would leave its plist in ~/Library/Preferences.
final class RulesOnlyModeTests: XCTestCase {
    /// A defaults store that lives and dies with the test.
    private final class MemoryStore: RulesOnlyStore {
        var values: [String: Bool] = [:]
        func bool(forKey key: String) -> Bool { values[key] ?? false }
        func set(_ value: Bool, forKey key: String) { values[key] = value }
    }

    func testOffByDefault() {
        let store = MemoryStore()
        XCTAssertFalse(RulesOnlyMode(store: store).isOn)
        XCTAssertEqual(store.values, [:], "reading never writes")
    }

    func testTheChoiceIsSavedAcrossLaunches() {
        let store = MemoryStore()
        RulesOnlyMode(store: store).isOn = true
        XCTAssertTrue(RulesOnlyMode(store: store).isOn, "a fresh instance — a relaunch — reads it back")
        XCTAssertEqual(store.values, ["rulesOnly": true], "only its own key")
        RulesOnlyMode(store: store).isOn = false
        XCTAssertFalse(RulesOnlyMode(store: store).isOn)
    }

    func testTheAppsStoreIsItsDefaults() {
        // The app reads and writes UserDefaults under the same key (no
        // write here: the test must not touch a real domain).
        XCTAssertTrue((UserDefaults.standard as Any) is RulesOnlyStore)
        XCTAssertEqual(RulesOnlyMode.storageKey, "rulesOnly")
    }

    func testTheModelLoadsAtLaunchOnlyWithoutRulesOnly() {
        XCTAssertTrue(RulesOnlyMode.loadsModelAtLaunch(rulesOnly: false, modelInstalled: true))
        XCTAssertFalse(RulesOnlyMode.loadsModelAtLaunch(rulesOnly: true, modelInstalled: true))
        XCTAssertFalse(RulesOnlyMode.loadsModelAtLaunch(rulesOnly: false, modelInstalled: false))
        XCTAssertFalse(RulesOnlyMode.loadsModelAtLaunch(rulesOnly: true, modelInstalled: false))
    }

    func testWhatADictationNeeds() {
        XCTAssertTrue(RulesOnlyMode.dictationNeedsModel(rulesOnly: false, level: .fillers))
        XCTAssertTrue(RulesOnlyMode.dictationNeedsModel(rulesOnly: false, level: .standard))
        XCTAssertFalse(RulesOnlyMode.dictationNeedsModel(rulesOnly: false, level: .verbatim))
        for level in AppConfig.Cleanup.Level.allCases {
            XCTAssertFalse(RulesOnlyMode.dictationNeedsModel(rulesOnly: true, level: level))
        }
    }

    func testWhatCommandModeDoesWithTheModel() {
        // Rules-only on, a selection to edit: the model is loaded for the
        // edit and freed once it lands.
        XCTAssertEqual(RulesOnlyMode.command(hasSelection: true, rulesOnly: true), .editThenUnload)
        XCTAssertEqual(RulesOnlyMode.command(hasSelection: true, rulesOnly: false), .edit)
        // Nothing selected: a dictation, which in rules-only never loads it.
        XCTAssertEqual(RulesOnlyMode.command(hasSelection: false, rulesOnly: true), .dictation)
        XCTAssertEqual(RulesOnlyMode.command(hasSelection: false, rulesOnly: false), .dictation)
    }

    func testFlippingTheSwitch() {
        // on: the unload is queued every time — resident or not yet, the op
        // decides when it runs, behind any load in flight (ModelResidencyTests)
        XCTAssertEqual(RulesOnlyMode.transition(toRulesOnly: true, modelInstalled: true), .unloadModel)
        XCTAssertEqual(RulesOnlyMode.transition(toRulesOnly: true, modelInstalled: false), .unloadModel)
        // off: load an installed model in the background (a no-op if resident)
        XCTAssertEqual(RulesOnlyMode.transition(toRulesOnly: false, modelInstalled: true), .loadModel)
        XCTAssertEqual(RulesOnlyMode.transition(toRulesOnly: false, modelInstalled: false), .none)
    }
}
