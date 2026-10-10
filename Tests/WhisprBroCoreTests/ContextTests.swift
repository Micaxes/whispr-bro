import XCTest
@testable import WhisprBroCore

final class AppCategoryTests: XCTestCase {
    func testKnownBundleIdsMapToCategories() {
        XCTAssertEqual(AppCategoryResolver.category(bundleId: "com.tinyspeck.slackmacgap"), .messaging)
        XCTAssertEqual(AppCategoryResolver.category(bundleId: "com.apple.mail"), .mail)
        XCTAssertEqual(AppCategoryResolver.category(bundleId: "com.apple.Safari"), .browser)
        XCTAssertEqual(AppCategoryResolver.category(bundleId: "com.microsoft.VSCode"), .ide)
        XCTAssertEqual(AppCategoryResolver.category(bundleId: "com.apple.Terminal"), .terminal)
        // Every shell must resolve: since SpokenStructure, an unrecognised
        // terminal would accept a spoken line break, and a newline in a shell
        // is Return — it RUNS the half-typed command.
        for shell in ["com.mitchellh.ghostty", "dev.warp.Warp-Stable", "org.alacritty", "io.alacritty",
                      "co.zeit.hyper", "com.eugeny.tabby", "com.googlecode.iterm2",
                      "com.github.wez.wezterm", "net.kovidgoyal.kitty"] {
            XCTAssertEqual(AppCategoryResolver.category(bundleId: shell), .terminal, shell)
        }
        // …and an unrecognised editor would take bullets into source code.
        for editor in ["com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
                       "com.microsoft.VSCode", "dev.zed.Zed", "com.apple.dt.Xcode"] {
            XCTAssertEqual(AppCategoryResolver.category(bundleId: editor), .ide, editor)
        }
        XCTAssertEqual(AppCategoryResolver.category(bundleId: "md.obsidian"), .notes)
    }

    func testJetBrainsFamilyMatchesByPrefix() {
        XCTAssertEqual(AppCategoryResolver.category(bundleId: "com.jetbrains.pycharm"), .ide)
        XCTAssertEqual(AppCategoryResolver.category(bundleId: "com.jetbrains.intellij.ce"), .ide)
        XCTAssertEqual(AppCategoryResolver.category(bundleId: "com.jetbrains.WebStorm"), .ide)
    }

    func testUnknownOrNilBundleId() {
        XCTAssertEqual(AppCategoryResolver.category(bundleId: "com.some.random.app"), .unknown)
        XCTAssertEqual(AppCategoryResolver.category(bundleId: nil), .unknown)
    }
}

final class StyleRulesTests: XCTestCase {
    func testEveryCategoryHasADirective() {
        let rules = StyleRules()
        for category in AppCategory.allCases {
            XCTAssertFalse(rules.directive(for: category).isEmpty, "no directive for \(category)")
        }
    }

    func testDirectivesDifferAcrossRegisters() {
        let rules = StyleRules()
        XCTAssertNotEqual(rules.directive(for: .messaging), rules.directive(for: .mail))
        XCTAssertNotEqual(rules.directive(for: .terminal), rules.directive(for: .unknown))
    }

    func testEveryDirectiveKeepsTheAntiRewriteClause() {
        // The words-preserving clause is load-bearing for a small model.
        let rules = StyleRules()
        for category in AppCategory.allCases {
            let d = rules.directive(for: category).lowercased()
            XCTAssertTrue(d.contains("exact") || d.contains("verbatim") || d.contains("every word"),
                          "\(category) directive lacks an anti-rewrite clause")
        }
    }

    func testOverrideDirective() {
        var rules = StyleRules()
        rules.setDirective("custom", for: .mail)
        XCTAssertEqual(rules.directive(for: .mail), "custom")
        XCTAssertNotEqual(rules.directive(for: .messaging), "custom")
    }
}
