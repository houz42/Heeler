import XCTest

// SPDX-License-Identifier: Apache-2.0

/// v2 special-sections proofs: a transcript carrying BOTH tags (a
/// harness-injected `<system-notice>` and a peer `<irc>` message)
/// renders them as collapsed summary chips at L1/L2, hides them
/// entirely at L0, and expands the full body on tap / at L3. The
/// assertions ride the accessibility tree (the chips' labels are
/// the kind label + one-line excerpt; the raw tag text never
/// appears); the screenshots carry the visual proof at all three
/// detail levels.
@MainActor
final class SpecialSectionsProofTests: XCTestCase {

    private func launchSpecialSectionsChat(detailLevel: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--demo-screenshots",
            "--demo-chat-special-sections",
            "--demo-detail-level=\(detailLevel)",
        ]
        app.launch()
        return app
    }

    /// The system-notice chip (accessibility: "System notice: <excerpt>").
    /// Matched by a stable prefix — the chip's excerpt is the body's
    /// whole first line, which the fixture makes longer than any
    /// exact string worth pinning.
    private func systemNoticeChip(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "System notice: Skill \"shell-qa\" is now active")
        ).firstMatch
    }

    /// The IRC chip (accessibility: "IRC message: <excerpt>").
    private func ircChip(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "IRC message: <Main> The retry fix looks good")
        ).firstMatch
    }

    // MARK: L0 — hidden entirely

    func testL0HidesSpecialSectionsEntirely() {
        let app = launchSpecialSectionsChat(detailLevel: 0)

        // The transcript itself must mount (the surrounding prose
        // renders as conversation at L0).
        XCTAssertTrue(
            app.staticTexts["All 18 targeted tests pass. Ready to commit when you are."]
                .waitForExistence(timeout: UITestTimeouts.launch),
            "the ordinary assistant prose must render at L0")

        // Hard asserts: NO chip of either kind, and no raw tag text
        // ever leaked into the prose.
        XCTAssertFalse(systemNoticeChip(app).exists, "L0 must hide the system notice entirely")
        XCTAssertFalse(ircChip(app).exists, "L0 must hide the IRC message entirely")
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "<system-notice>")).firstMatch.exists,
            "the raw <system-notice> tag must never render")
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "<irc>")).firstMatch.exists,
            "the raw <irc> tag must never render")

        captureScreenshot(app, "special-sections-l0-hidden", lifetime: .keepAlways)
    }

    // MARK: L1 — collapsed summary chips

    func testL1ShowsCollapsedSummaryChips() {
        let app = launchSpecialSectionsChat(detailLevel: 1)

        XCTAssertTrue(
            systemNoticeChip(app).waitForExistence(timeout: UITestTimeouts.standard),
            "the system-notice chip must render at L1")
        XCTAssertTrue(
            ircChip(app).exists,
            "the IRC chip must render at L1")

        // Collapsed: the chips' FULL bodies must not be on screen
        // (only the one-line excerpts ride the chip labels).
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Exit code semantics")).firstMatch.exists,
            "the collapsed chip must not show the full body")

        captureScreenshot(app, "special-sections-l1-chips", lifetime: .keepAlways)

        // Expansion: tap the IRC chip — the full body appears below it.
        ircChip(app).tap()
        let fullBody = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "go ahead and ship it when tests pass"))
            .firstMatch
        XCTAssertTrue(
            fullBody.waitForExistence(timeout: UITestTimeouts.standard),
            "tapping the chip must expand the full body")

        captureScreenshot(app, "special-sections-l1-expanded", lifetime: .keepAlways)
    }

    // MARK: L3 — highest detail starts expanded

    func testL3StartsSectionsExpanded() {
        let app = launchSpecialSectionsChat(detailLevel: 3)

        // The chip itself still renders (the summary row).
        XCTAssertTrue(
            systemNoticeChip(app).waitForExistence(timeout: UITestTimeouts.standard),
            "the system-notice chip must render at L3")

        // And its full body is ALREADY visible (L3 starts expanded).
        let fullBody = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Exit code semantics"))
            .firstMatch
        XCTAssertTrue(
            fullBody.waitForExistence(timeout: UITestTimeouts.standard),
            "L3 must start the section expanded (full body visible)")

        captureScreenshot(app, "special-sections-l3-expanded", lifetime: .keepAlways)
    }
}
