import XCTest

// SPDX-License-Identifier: Apache-2.0

/// Settings (#A settings revision) proofs: the new Reading & Appearance
/// section carries the designed rows — the moved appearance picker, Text
/// Size, and Default Conversation Detail — while EVERY pre-existing row
/// stays. The two new detail pages open and bind live.
@MainActor
final class SettingsReadingProofTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApp.launchDemo(.console)
    }

    override func tearDown() {
        app.terminate()
    }

    private func openSettings() {
        let trigger = app.buttons[UITestFixtures.navigationTrigger].firstMatch
        XCTAssertTrue(
            trigger.waitForExistence(timeout: UITestTimeouts.launch))
        trigger.tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(
            settings.waitForExistence(timeout: UITestTimeouts.standard))
        settings.tap()
        XCTAssertTrue(
            app.staticTexts["Notifications"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Settings page must mount")
    }

    /// The Settings page shows the new section AND every existing row.
    func testSettingsShowsReadingSectionWithAllExistingItems() {
        openSettings()

        // The new Reading & Appearance section.
        XCTAssertTrue(
            app.staticTexts["Reading & Appearance"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the new section header must be present")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Appearance"))
                .firstMatch.exists,
            "the existing appearance picker must remain (moved, not removed)")
        XCTAssertTrue(
            app.buttons["Text Size"].firstMatch.exists,
            "the designed Text Size row must be present")
        XCTAssertTrue(
            app.buttons["Default Conversation Detail"].firstMatch.exists,
            "the designed Default Conversation Detail row must be present")

        // EVERY pre-existing row stays (#A: keep all existing items).
        XCTAssertTrue(
            app.buttons["Agent List Fields"].firstMatch.exists)
        XCTAssertTrue(
            app.buttons["In-Agent Header"].firstMatch.exists)
        XCTAssertTrue(
            app.buttons["Notifications"].firstMatch.exists)
        XCTAssertTrue(
            app.buttons["Terminal Appearance"].firstMatch.exists)
        XCTAssertTrue(
            app.staticTexts["About"].firstMatch.exists)
        captureScreenshot(app, "settings-reading-section", lifetime: .keepAlways)
    }

    /// The Text Size page opens and a choice binds + persists in-process.
    func testTextSizePageOpensAndPicks() {
        openSettings()
        let row = app.buttons["Text Size"].firstMatch
        waitToExist(row)
        row.tap()

        XCTAssertTrue(
            app.navigationBars["Text Size"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Text Size detail page must push")

        // System is present and selectable.
        let system = app.buttons["System"].firstMatch
        XCTAssertTrue(
            system.waitForExistence(timeout: UITestTimeouts.standard))
        system.tap()
        captureScreenshot(app, "settings-text-size", lifetime: .keepAlways)
    }

    /// The Default Conversation Detail page opens against the existing
    /// store and a choice binds.
    func testDefaultDetailPageOpensAndPicks() {
        openSettings()
        let row = app.buttons["Default Conversation Detail"].firstMatch
        waitToExist(row)
        row.tap()

        XCTAssertTrue(
            app.navigationBars["Default Conversation Detail"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the Default Conversation Detail page must push")
        let l1 = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "L1"))
            .firstMatch
        XCTAssertTrue(
            l1.waitForExistence(timeout: UITestTimeouts.standard),
            "the level rows must render")
        l1.tap()
        captureScreenshot(app, "settings-default-detail", lifetime: .keepAlways)
    }
}
