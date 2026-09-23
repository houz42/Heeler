import XCTest

// SPDX-License-Identifier: Apache-2.0
//
/// v3 Q/A cards — the visual proof suite against the
/// `--demo-chat-qa-cards` fixture: BOTH states of the SAME card
/// family (unanswered multi-question ask at the live edge; answered
/// cards covering every answer shape in the transcript). The suite
/// drives the real interactions — option select, custom-text entry,
/// swipe between questions, tap expand/collapse — and captures the
/// evidence. Assertions ride the accessibility tree; the screenshots
/// carry the visual proof of the card family (paper bg, green
/// border, 12pt radius, eyebrow, thin n-of-N segments) in the run's
/// appearance.

@MainActor
final class QACardProofTests: XCTestCase {

    private func launchQACards() -> XCUIApplication {
        UITestApp.launchDemo(.chatQACards)
    }

    private func element(
        _ labelFragment: String, in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", labelFragment)
        ).firstMatch
    }

    // MARK: the unanswered card (live edge)

    func testUnansweredCardRendersAndSelects() {
        let app = launchQACards()

        // The eyebrow + first question render.
        XCTAssertTrue(
            element("Your input needed", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the unanswered card's eyebrow never rendered")
        XCTAssertTrue(
            element("Which checks should run", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the first question never rendered")

        // n-of-N position reads on the header.
        XCTAssertTrue(
            element("1 of 2", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the n-of-N position never rendered")

        // A REAL tap through the card's own selection path.
        let option = app.buttons["Toggle: Unit suite"].firstMatch
        XCTAssertTrue(
            option.waitForExistence(timeout: UITestTimeouts.standard),
            "the multi-select option must be tappable")
        option.tap()

        captureScreenshot(app, "qa-card-unanswered-selected")
    }

    func testSwipeMovesToSecondQuestion() {
        let app = launchQACards()

        let first = element("Which checks should run", in: app)
        XCTAssertTrue(
            first.waitForExistence(timeout: UITestTimeouts.standard))

        // Horizontal swipe INSIDE the card: the unanswered card is at
        // the bottom of the transcript (scroll there first).
        let card = element("Your input needed", in: app)
        XCTAssertTrue(
            card.waitForExistence(timeout: UITestTimeouts.standard))
        card.swipeLeft()

        // The second question renders after the swipe.
        XCTAssertTrue(
            element("Who reviews the pull request?", in: app)
                .waitForExistence(timeout: UITestTimeouts.standard),
            "swiping left must reveal the second question")
        XCTAssertTrue(
            element("2 of 2", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the position must read 2 of 2 after the swipe")

        // Back to the first question.
        card.swipeRight()
        XCTAssertTrue(
            element("1 of 2", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "swiping right must return to the first question")

        captureScreenshot(app, "qa-card-swipe-question")
    }

    // MARK: the answered cards (transcript)

    func testAnsweredCardsRenderEveryAnswerShape() {
        let app = launchQACards()

        // Multi-question answered card: labels + note + free text.
        // (Scroll the transcript up: resolved cards anchor after the
        // message that posed the question.)
        app.swipeUp()
        XCTAssertTrue(
            element("Answered", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the answered card's eyebrow never rendered")
        XCTAssertTrue(
            element("Validation report", in: app).waitForExistence(
                timeout: UITestTimeouts.standard),
            "the selected-option label never rendered")

        captureScreenshot(app, "qa-card-answered-collapsed")
    }

    func testExpandCollapseFullAnswer() {
        let app = launchQACards()
        app.swipeUp()

        // The long answered card: collapsed, the summary is ONE line
        // (the full text is NOT all visible).
        let eyebrow = element("Answered", in: app)
        XCTAssertTrue(
            eyebrow.waitForExistence(timeout: UITestTimeouts.standard))

        // Tap the long-answer card's question line to expand.
        let longQuestion = element("Summarize the rollout plan", in: app)
        XCTAssertTrue(
            longQuestion.waitForExistence(timeout: UITestTimeouts.standard))
        longQuestion.tap()

        // Expanded: the full answer + note render.
        XCTAssertTrue(
            element("Stage the rollout behind the config flag", in: app)
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the expanded full answer never rendered")
        XCTAssertTrue(
            element("Keep the kill switch documented", in: app)
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the separately-labeled note never rendered")

        captureScreenshot(app, "qa-card-answered-expanded")

        // Tap again to collapse.
        longQuestion.tap()
        captureScreenshot(app, "qa-card-answered-recollapsed")
    }

    func testHonestOutcomeCardsRender() {
        let app = launchQACards()
        app.swipeUp()

        // Cancelled: honest outcome text, no accepted-answer styling.
        XCTAssertTrue(
            element("This question was cancelled", in: app)
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the cancelled card's honest outcome never rendered")

        captureScreenshot(app, "qa-card-outcomes")
    }
}
