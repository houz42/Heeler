import XCTest

// SPDX-License-Identifier: Apache-2.0

/// v3 Messages-style composer proofs over the interactive demo chat
/// (`.chatComposer`): the compact resting row (+ button, capsule,
/// inline Send), multiline growth bounded, and the + menu exposing the
/// four prefix modes then image/file. The attachment state rides the
/// SEEDED route (`--demo-composer-attachment`): the persisted-draft
/// restore (the real item-18 path) opens with the tile INSIDE the
/// upward-extended capsule, the + moved to the tile row's end, and
/// Send enabled. Assertions ride the accessibility tree; screenshots
/// carry the visual proof (the green-accent Send, the capsule shape).
@MainActor
final class ComposerProofTests: XCTestCase {

    // MARK: - Locators

    /// The circular + button on the composer's left.
    private func addButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Add"].firstMatch
    }

    /// The inline Send control inside the capsule's right edge.
    private func sendButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Send"].firstMatch
    }

    /// The composer's text field (its AX label is the placeholder).
    private func composerField(_ app: XCUIApplication) -> XCUIElement {
        app.chatInput
    }

    private func launchComposer() -> XCUIApplication {
        UITestApp.launchDemo(.chatComposer)
    }

    // MARK: - The compact resting row

    func testEmptyComposerIsOneCompactRow() {
        let app = launchComposer()

        // The transcript mounts first.
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Ship the composer slice")
            ).firstMatch.waitForExistence(timeout: UITestTimeouts.launch),
            "the demo transcript must mount")

        // The row's three controls: + on the left, the field, Send
        // inside the capsule's right edge.
        XCTAssertTrue(addButton(app).exists, "the + button must be present")
        XCTAssertTrue(sendButton(app).exists, "the inline Send must be present")
        XCTAssertTrue(composerField(app).exists, "the field must be present")

        // NO keyboard-dismiss chrome: the v2 chevron is removed (the
        // OS keyboard's own dismissal control is the only one).
        XCTAssertFalse(
            app.buttons["Collapse input"].exists,
            "the custom keyboard-dismiss chevron must be gone")

        // Empty draft: Send is disabled (the shared predicate).
        XCTAssertFalse(
            sendButton(app).isEnabled,
            "Send must be disabled for an empty draft")

        // And the field's placeholder is the plain v3 hint.
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Message")
            ).firstMatch.exists,
            "the placeholder must read Message")

        captureScreenshot(app, "composer-resting-compact-row", lifetime: .keepAlways)
    }

    // MARK: - Multiline growth, bounded

    func testMultilineGrowsAndSendEnables() {
        let app = launchComposer()

        let field = composerField(app)
        XCTAssertTrue(field.waitForExistence(timeout: UITestTimeouts.launch))

        field.tap()
        XCTAssertTrue(app.waitForKeyboard(), "the system keyboard must present")

        // A multiline draft (Return inserts a newline by default):
        // type a line, newline, another line.
        field.typeText("First line of the multiline draft")
        field.typeText("\n")
        field.typeText("Second line")

        // The row GREW (the multiline-grown capture): the field's
        // frame must be taller than the one-line resting height.
        let grownHeight = field.frame.height
        XCTAssertGreaterThan(
            grownHeight, 36,
            "a multiline draft must grow the capsule beyond one line")

        // Send enables with text (the shared predicate).
        XCTAssertTrue(
            sendButton(app).isEnabled,
            "Send must enable once the draft has text")

        // Sending clears the draft and lands the message in the
        // transcript (the demo deliver appends it live).
        sendButton(app).tap()
        let sent = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "Second line")
        ).firstMatch
        XCTAssertTrue(
            sent.waitForExistence(timeout: UITestTimeouts.standard),
            "the sent message must appear in the transcript")

        captureScreenshot(app, "composer-multiline-grown", lifetime: .keepAlways)
    }

    // MARK: - The + menu exposes the four prefix modes + attachments

    func testPlusMenuHoldsPrefixModesAndAttachments() {
        let app = launchComposer()

        XCTAssertTrue(
            addButton(app).waitForExistence(timeout: UITestTimeouts.launch))
        addButton(app).tap()

        // The menu must expose the four prefix functions (design-doc
        // order) ahead of the image/file actions.
        for item in [
            "Agent command (/)",
            "Filter / tag (#)",
            "Mention (@)",
            "Shell command (!)",
            "Add Image",
            "Add File",
        ] {
            XCTAssertTrue(
                app.buttons[item].firstMatch.exists,
                "the + menu must expose \(item)")
        }

        captureScreenshot(app, "composer-plus-menu-open", lifetime: .keepAlways)

        // Dismiss the menu without acting (tap elsewhere).
        app.staticTexts.firstMatch.tap()
    }

    // MARK: - The attachment tile rides inside the extended capsule

    /// The attachment capture runs the SEEDED demo route
    /// (`--demo-composer-attachment`): the persisted-draft restore
    /// (the real item-18 path) opens with the image tile INSIDE the
    /// upward-extended capsule, the + moved to the tile row's end,
    /// and Send enabled — deterministic, no OS-picker driving.
    func testAttachmentTileAppearsInsideExtendedCapsule() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--uitest", "--demo-screenshots", "--demo-chat-composer",
            "--demo-composer-attachment",
        ]
        app.launch()

        // The tile (the restored image item) renders inside the
        // capsule, above the field.
        let tile = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Pending image attachment")
        ).firstMatch
        XCTAssertTrue(
            tile.waitForExistence(timeout: UITestTimeouts.launch),
            "the restored attachment tile must appear inside the extended capsule")

        // The restored prose draft sits in the field.
        let field = composerField(app)
        XCTAssertTrue(
            field.waitForExistence(timeout: UITestTimeouts.standard))
        let value = field.value as? String ?? ""
        XCTAssertTrue(
            value.contains("Take a look at this screenshot"),
            "the seeded draft's prose must restore into the field")

        // Exactly ONE Add control remains on screen: with
        // attachments held the + moved into the capsule's tile row;
        // it did not duplicate.
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "label == %@", "Add")).count, 1,
            "only one + control must be visible with attachments held")

        // Send enables with the held attachment (the shared
        // predicate: items alone make the draft sendable).
        XCTAssertTrue(
            sendButton(app).isEnabled,
            "Send must enable with a held attachment tile")

        captureScreenshot(app, "composer-attachment-inside-capsule", lifetime: .keepAlways)
    }
}
