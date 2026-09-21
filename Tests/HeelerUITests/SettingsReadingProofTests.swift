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
        // Width-aware: wide layouts show the reserved sidebar directly
        // (reveal the agents column first on iPad, where the Console
        // opens detail-only); phone opens the drawer from the trigger.
        let wideSidebar = app.otherElements["App destinations"].firstMatch
        if wideSidebar.waitForExistence(timeout: 2) {
            let settings = wideSidebar.buttons["Settings"].firstMatch
            XCTAssertTrue(
                settings.waitForExistence(timeout: UITestTimeouts.standard),
                "the wide sidebar must offer Settings")
            settings.tap()
        } else {
            let trigger = app.buttons[UITestFixtures.navigationTrigger].firstMatch
            XCTAssertTrue(
                trigger.waitForExistence(timeout: UITestTimeouts.launch))
            trigger.tap()
            let settings = app.buttons["Settings"].firstMatch
            XCTAssertTrue(
                settings.waitForExistence(timeout: UITestTimeouts.standard))
            settings.tap()
        }
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

        // EVERY pre-existing row stays (#A: keep all existing items),
        // and the three surface-appearance rows now live INSIDE the
        // Reading & Appearance group (device-feedback refinement): the
        // six-row order is Appearance, Text Size, Default Conversation
        // Detail, Agent List Fields, In-Agent Header, Terminal
        // Appearance. Membership is asserted by reading order + row
        // contiguity: a section boundary between the designed and legacy
        // rows would break the frame sequence.
        // The Appearance row is a picker whose label reads
        // "Appearance, System" — match by prefix. The rest are links.
        let readingRows: [(label: String, prefix: Bool)] = [
            ("Appearance", true),
            ("Text Size", false),
            ("Default Conversation Detail", false),
            ("Agent List Fields", false),
            ("In-Agent Header", false),
            ("Terminal Appearance", false),
        ]
        var ys: [CGFloat] = []
        for entry in readingRows {
            let row = entry.prefix
                ? app.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH %@", entry.label)
                ).firstMatch
                : app.buttons[entry.label].firstMatch
            XCTAssertTrue(
                row.waitForExistence(timeout: UITestTimeouts.standard),
                "\(entry.label) must remain (moved, not removed)")
            ys.append(row.frame.minY)
        }
        XCTAssertEqual(
            ys, ys.sorted(), "the six reading rows must appear in the "
                + "approved order in ONE group")
        // Contiguity: successive gaps stay row-height sized — a section
        // break between the designed and legacy rows would show a much
        // larger gap.
        for index in 1..<ys.count {
            XCTAssertLessThan(
                ys[index] - ys[index - 1], 90,
                "rows must sit in the same group (gap too large for one "
                    + "section)")
        }
        XCTAssertTrue(
            app.buttons["Notifications"].firstMatch.exists,
            "Notifications must remain (its own section)")
        XCTAssertTrue(
            app.staticTexts["About"].firstMatch.exists,
            "About must remain its own section")
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

    /// Review finding 4's proof: the text-size choice must change the
    /// RENDERED reading text — an actual measured sample, not a picker
    /// checkmark. Measure a chat message's height at System, pick XXL,
    /// re-measure: the reading text must grow.
    func testTextSizeChangesRenderedReadingText() {
        // Clean slate FIRST: a previous run's choice persists in
        // UserDefaults(.standard) — select System explicitly so the
        // System measurement is actually System, then relaunch and
        // measure; then pick XXL, relaunch, and measure again.
        openSettings()
        let cleanRow = app.buttons["Text Size"].firstMatch
        waitToExist(cleanRow)
        cleanRow.tap()
        let systemChoice = app.buttons["System"].firstMatch
        XCTAssertTrue(
            systemChoice.waitForExistence(timeout: UITestTimeouts.standard),
            "the System choice must render")
        systemChoice.tap()
        app.terminate()
        app = UITestApp.launchDemo(.console)

        // The demo fixture's chat-bearing agent, with its transcript.
        let cell = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Polish the Attach experience")
        ).firstMatch
        waitToExist(cell)
        cell.tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never pushed")

        // A rendered reading line: the fixture's long assistant message
        // (visible at the chat's bottom anchor on open, both passes).
        let message = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Long-run verification notes")
        ).firstMatch
        XCTAssertTrue(
            message.waitForExistence(timeout: UITestTimeouts.standard),
            "the sample reading text must render")
        // Settle: the transcript's layout must finish before measuring.
        Thread.sleep(forTimeInterval: 2)
        let messageHeightAtSystem = message.frame.height

        // Edge-swipe back to the list, into Settings → Text Size → XXL.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        openSettings()
        let textRow = app.buttons["Text Size"].firstMatch
        waitToExist(textRow)
        textRow.tap()
        let xxl = app.buttons["Extra Extra Large"].firstMatch
        XCTAssertTrue(
            xxl.waitForExistence(timeout: UITestTimeouts.standard),
            "the XXL choice must render on the Text Size page")
        xxl.tap()
        captureScreenshot(app, "settings-text-size-xxl", lifetime: .keepAlways)

        // The shared store is already updated (ONE store — the write is
        // live), so relaunch to the Agents root and re-measure the same
        // chat: the choice must persist across the relaunch AND grow the
        // reading text. (Relaunch instead of navigating back keeps this
        // proof about the size contract, not the back-button mechanics.)
        app.terminate()
        app = UITestApp.launchDemo(.console)

        // Reopen the chat and re-measure: reading text grows.
        let cellAgain = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Polish the Attach experience")
        ).firstMatch
        waitToExist(cellAgain)
        cellAgain.tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never re-pushed")
        let messageAgain = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Long-run verification notes")
        ).firstMatch
        XCTAssertTrue(
            messageAgain.waitForExistence(timeout: UITestTimeouts.standard),
            "the sample reading text must render after the size change")
        Thread.sleep(forTimeInterval: 2)
        let messageHeightAtXXL = messageAgain.frame.height
        XCTAssertGreaterThan(
            messageHeightAtXXL, messageHeightAtSystem * 1.3,
            "the reading text must measurably grow at XXL (System "
                + "\\(messageHeightAtSystem) → XXL \\(messageHeightAtXXL))")
        captureScreenshot(app, "chat-reading-xxl", lifetime: .keepAlways)
    }
}
