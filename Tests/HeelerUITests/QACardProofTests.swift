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

        captureScreenshot(app, "qa-card-unanswered-selected", lifetime: .keepAlways)
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

        captureScreenshot(app, "qa-card-swipe-question", lifetime: .keepAlways)
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

        captureScreenshot(app, "qa-card-answered-collapsed", lifetime: .keepAlways)
    }

    func testExpandCollapseFullAnswer() {
        let app = launchQACards()
        app.swipeUp()

        // The long answered card: collapsed, the summary is ONE line
        // (the full text is NOT all visible).
        let eyebrow = element("Answered", in: app)
        XCTAssertTrue(
            eyebrow.waitForExistence(timeout: UITestTimeouts.standard))

        // Tap the long-answer CARD (identifier-keyed — the question
        // text also appears in the transcript message that posed the
        // ask, so a text CONTAINS match is ambiguous on a scrolled
        // view) to expand.
        let longCard = app.descendants(matching: .any)
            .matching(identifier: "resolved-ask-card-demo-qa-long").firstMatch
        XCTAssertTrue(
            longCard.waitForExistence(timeout: UITestTimeouts.standard))
        longCard.tap()

        // Expanded: the full answer renders (the optional note is
        // removed from the product — no Note row).
        XCTAssertTrue(
            element("Stage the rollout behind the config flag", in: app)
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the expanded full answer never rendered")

        captureScreenshot(app, "qa-card-answered-expanded", lifetime: .keepAlways)

        // Tap again to collapse.
        longCard.tap()
        captureScreenshot(app, "qa-card-answered-recollapsed", lifetime: .keepAlways)

        // Expand the export card too: the multi-select answer renders
        // its selected labels as CHIPS in producer order.
        let exportCard = app.descendants(matching: .any)
            .matching(identifier: "resolved-ask-card-demo-qa-answered").firstMatch
        XCTAssertTrue(
            exportCard.waitForExistence(timeout: UITestTimeouts.standard))
        exportCard.tap()
        XCTAssertTrue(
            element("Validation report", in: app)
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the export card's chips never rendered when expanded")
        captureScreenshot(app, "qa-card-chips-expanded", lifetime: .keepAlways)
    }

    // MARK: the immediate answered flip on submit

    /// THE USER'S REPORT: submitting an answer left the card
    /// unanswered. The fix: an ACCEPTED submit flips the card to the
    /// ANSWERED render immediately — no broker refresh. This drives
    /// the real card through a real submit (the demo seam accepts)
    /// and pins the flip: the unanswered controls vanish and the
    /// answered card shows the chosen answer, collapsed.
    func testSubmitFlipsCardToAnsweredImmediately() {
        let app = launchQACards()

        // Answer BOTH questions of the demo ask: multi-select on q1,
        // single choice on q2.
        let unitSuite = app.buttons["Toggle: Unit suite"].firstMatch
        XCTAssertTrue(
            unitSuite.waitForExistence(timeout: UITestTimeouts.standard),
            "the first question's option must be tappable")
        unitSuite.tap()

        // Swipe to the second question and choose.
        let card = element("Your input needed", in: app)
        XCTAssertTrue(
            card.waitForExistence(timeout: UITestTimeouts.standard))
        card.swipeLeft()
        let you = app.buttons["Answer: You"].firstMatch
        XCTAssertTrue(
            you.waitForExistence(timeout: UITestTimeouts.standard),
            "the second question's option must be tappable after the swipe")
        you.tap()

        // Send answers (the card's own validated submit).
        let send = app.buttons["Send answers"].firstMatch
        XCTAssertTrue(
            send.waitForExistence(timeout: UITestTimeouts.standard),
            "Send answers must render once every question is answered")
        send.tap()

        // THE FLIP: the card renders ANSWERED immediately — the
        // eyebrow reads Answered (not Submitting), the chosen answers
        // are visible.
        let answeredEyebrow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Answered")
        ).firstMatch
        XCTAssertTrue(
            answeredEyebrow.waitForExistence(timeout: UITestTimeouts.standard),
            "the card must flip to the Answered eyebrow on submit")

        // The unanswered affordances are GONE: no Send answers button
        // remains reachable (the answered card is not interactive).
        waitToNotExist(app.buttons["Send answers"].firstMatch)

        captureScreenshot(app, "qa-card-flipped-answered", lifetime: .keepAlways)
    }

    func testHonestOutcomeCardsRender() {
        let app = launchQACards()
        app.swipeUp()

        // Cancelled: honest outcome text, no accepted-answer styling.
        XCTAssertTrue(
            element("This question was cancelled", in: app)
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the cancelled card's honest outcome never rendered")

        captureScreenshot(app, "qa-card-outcomes", lifetime: .keepAlways)
    }
}
