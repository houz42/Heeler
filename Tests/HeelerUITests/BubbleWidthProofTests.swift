import XCTest

// SPDX-License-Identifier: Apache-2.0
//
/// v3 content-sized own-message bubbles — the visual proof suite. The
/// `--demo-chat-bubbles` fixture transcript carries every sizing case
/// the design names: a one-word message, an emoji-only message, a
/// multiline (soft-break) message, a fenced code block, and long prose
/// that must WRAP at the cap. The assertions ride the accessibility
/// tree (the fixture texts render as reachable elements at their
/// content-sized frames); the screenshots carry the visual proof in
/// both appearances (light + dark) — the attached captures are the
/// evidence the bubbles HUG content: short bubbles visibly narrower
/// than the trailing-parked long-prose bubble, none stretched to the
/// full row.

@MainActor
final class BubbleWidthProofTests: XCTestCase {

    private func launchBubblesChat() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "--uitest",
            "--demo-screenshots",
            "--demo-chat-bubbles",
        ]
        app.launch()
        return app
    }

    // The fixture's own-message texts (DemoScreenshotMode's
    // chatBubblesSurface) — matched by CONTAINS; the markdown render
    // may split long prose across accessibility elements, so each
    // probe uses a stable fragment of one message.
    private func ownMessage(
        _ fragment: String, in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", fragment)
        ).firstMatch
    }

    // MARK: all sizing cases present + captured

    func testAllSizingCasesRenderAndCaptured() {
        let app = launchBubblesChat()

        // One-word message renders (content-sized, reachable).
        XCTAssertTrue(
            ownMessage("Ship it.", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the one-word own message never rendered")

        // Emoji-only message renders.
        XCTAssertTrue(
            ownMessage("🚀", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the emoji-only own message never rendered")

        // Multiline message: the soft-break render keeps the lines
        // reachable.
        XCTAssertTrue(
            ownMessage("line one", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the multiline own message never rendered")

        // Fenced code block renders (code stays monospace content in
        // the bubble).
        XCTAssertTrue(
            ownMessage("func greet()", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the fenced-code own message never rendered")

        // Long prose wraps (reachable — never clipped out of the
        // tree by a fixed-width trap).
        XCTAssertTrue(
            ownMessage("Before you commit the checkout fix", in: app)
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the long-prose own message never rendered")

        // The agent's turn renders too (unchanged article, for
        // contrast in the capture).
        XCTAssertTrue(
            ownMessage("All 18 targeted tests pass", in: app)
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the agent turn never rendered")

        // The visual proof: the transcript with every case
        // content-sized, in this run's appearance.
        captureScreenshot(app, "chat-bubbles-light")
    }

    // MARK: hug-content width evidence (a11y frames)

    /// The one-word own message's visible frame must be visibly
    /// NARROWER than the transcript width — the core v3 property
    /// (bubbles hug content; the old fixed-fraction render would have
    /// stretched even "Ship it." to ~78% of the row). Asserted on the
    /// element's frame vs the app's frame with generous margins: the
    /// one-word bubble (7 characters + 24pt padding) is far below the
    /// 0.85 cap.
    func testOneWordBubbleHugsContent() {
        let app = launchBubblesChat()
        let bubble = ownMessage("Ship it.", in: app)
        XCTAssertTrue(
            bubble.waitForExistence(timeout: UITestTimeouts.standard))

        let appWidth = app.frame.width
        let bubbleWidth = bubble.frame.width

        // A one-word own bubble must span well under half the
        // transcript width (the cap alone would allow ~85%; the old
        // fill behavior ~78% — both far above what "Ship it."
        // content needs).
        XCTAssertLessThan(
            bubbleWidth, appWidth * 0.5,
            "the one-word bubble spans \(bubbleWidth)pt of a "
                + "\(appWidth)pt transcript — it should hug its content, "
                + "not stretch to a fixed fraction")
    }

    // MARK: trailing alignment evidence

    /// Content-sized own bubbles park at the TRAILING edge: the
    /// one-word bubble's frame sits in the right half of the
    /// transcript (its minX is past the row's midpoint), and the
    /// long-prose bubble — which wraps to nearly the full cap —
    /// still leaves a visible leading gutter.
    func testOwnBubblesAreTrailingAligned() {
        let app = launchBubblesChat()
        let short = ownMessage("Ship it.", in: app)
        XCTAssertTrue(
            short.waitForExistence(timeout: UITestTimeouts.standard))
        let long = ownMessage("Before you commit the checkout fix", in: app)
        XCTAssertTrue(
            long.waitForExistence(timeout: UITestTimeouts.standard))

        // Short bubble in the trailing half of the transcript.
        XCTAssertGreaterThan(
            short.frame.minX, app.frame.midX,
            "the one-word bubble's leading edge (\(short.frame.minX)) "
                + "sits left of the transcript midpoint — own bubbles "
                + "must park trailing")

        // Long prose wraps at the cap, not the full row: a visible
        // leading gutter remains (the cap is 0.85 of the transcript,
        // and the fixture's prose fills it).
        XCTAssertGreaterThan(
            long.frame.minX, app.frame.minX + 8,
            "the long-prose bubble touches the row's leading edge — "
                + "it should respect the 0.85 cap and wrap")
    }
}
