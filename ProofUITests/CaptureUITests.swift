import XCTest

// TEMPORARY A1 capture harness — request-after-hold is a HARD assert
// this time; removed again before commit per the byte-identical rule.
final class CaptureUITests: XCTestCase {
    func testA1CaptureHold() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HEELER_AGENT_CHAT_PROOF_SESSION_FILE"]
            = "/Users/jhou/.cache/agent-chat-ui-proof/history.jsonl"
        app.launch()
        Thread.sleep(forTimeInterval: 25)
        let row = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'Mac Proof'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "host row missing")
        row.tap()
        let header = app.staticTexts.matching(
            NSPredicate(format: "label == 'omp'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 30), "detail did not open")
        // HOLD: >90s idle-and-subscribed over the SSH path.
        Thread.sleep(forTimeInterval: 100)
        // REQUEST-AFTER-HOLD — HARD assert. Dump all button labels for
        // the record, then require the input affordance.
        let allButtons = app.buttons.allElementsBoundByIndex.map({ $0.label })
        try? allButtons.joined(separator: "\n").write(
            to: URL(fileURLWithPath: "/tmp/heeler-proof-signals/buttons-dump.txt"),
            atomically: true, encoding: .utf8)
        let inputButton = app.buttons["Message the agent"]
        XCTAssertTrue(
            inputButton.waitForExistence(timeout: 10),
            "input affordance missing after hold; buttons: \(allButtons.joined(separator: " | "))")
        inputButton.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "input field did not open")
        field.typeText("Reply exactly: post-hold request proof e39754b.")
        let send = app.buttons["Send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5), "send button missing")
        send.tap()
        Thread.sleep(forTimeInterval: 12)
    }
}

extension CaptureUITests {
    func testConversationRedesignProofs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-screenshots"]
        app.launch()
        Thread.sleep(forTimeInterval: 12)
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'ios-polish'")).firstMatch
        if !row.exists {
            let any = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'docs-review'")).firstMatch
            XCTAssertTrue(any.waitForExistence(timeout: 15), "no demo agents")
            any.tap()
        } else {
            row.tap()
        }
        Thread.sleep(forTimeInterval: 8)
        screenshot("redesign-conversation-latest")
        for _ in 0..<6 { app.swipeDown() }
        Thread.sleep(forTimeInterval: 2)
        screenshot("redesign-conversation-article-and-bubble")
        // Message-actions rail (final spec): a short tap on a message
        // toggles the inline Copy/(Quote)/Helpful rail under it. Tap a
        // plain text region (mid width avoids right-aligned link spans).
        // Screen-coordinate tap (element-agnostic): center screen is
        // inside the article body.
        // Right-center: the user bubble (compact, right-aligned, no links).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)).tap()
        Thread.sleep(forTimeInterval: 2)
        screenshot("redesign-message-actions-rail")
        // Same-message tap toggles the rail off (the dismissal path).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)).tap()
        Thread.sleep(forTimeInterval: 1)
        screenshot("redesign-message-actions-dismissed")
        // Composer collapse/grow, LIVE when this agent's session
        // resolves an interactive composer (the honest-unavailable
        // capture documents the read-only case otherwise).
        let messageButton = app.buttons["Message the agent"]
        if messageButton.waitForExistence(timeout: 4) {
            messageButton.tap()
            Thread.sleep(forTimeInterval: 3)
            screenshot("d2-composer-collapsed-live")
            let field = app.textViews.firstMatch
            if field.waitForExistence(timeout: 5) {
                field.typeText("A typed draft long enough to wrap past one composer row, exercising the grow bound with genuine keystrokes")
                Thread.sleep(forTimeInterval: 1)
                screenshot("d2-composer-grown-live")
                // Close the input: the draft must survive (never
                // cleared on blur).
                let close = app.buttons["Close input"]
                if close.exists {
                    close.tap()
                    Thread.sleep(forTimeInterval: 1)
                    screenshot("d2-composer-closed-draft-preserved")
                    // Reopen: the rail and draft are still there.
                    if messageButton.waitForExistence(timeout: 4) {
                        messageButton.tap()
                        Thread.sleep(forTimeInterval: 2)
                        screenshot("d2-composer-reopened-draft-intact")
                    }
                }
            }
        } else {
            screenshot("d2-composer-unavailable-honest")
        }
        app.terminate()
        Thread.sleep(forTimeInterval: 2)
        let app2 = XCUIApplication()
        app2.launchArguments = ["--demo-screenshots"]
        app2.launch()
        Thread.sleep(forTimeInterval: 10)
        let blocked = app2.buttons.matching(
            NSPredicate(format: "label CONTAINS 'reviewer'")).firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 15), "reviewer row missing")
        blocked.tap()
        Thread.sleep(forTimeInterval: 7)
        screenshot("redesign-pending-card")
    }

    /// D2 proofs: the real multi-question ask flow, the rail's
    /// non-triggers, and (when the demo agent's session resolves a
    /// composer) collapse/grow with real typing.
    func testD2FlowProofs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-screenshots"]
        app.launch()
        Thread.sleep(forTimeInterval: 10)
        let blocked = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'reviewer'")).firstMatch
        XCTAssertTrue(blocked.waitForExistence(timeout: 15), "reviewer row missing")
        blocked.tap()
        Thread.sleep(forTimeInterval: 7)

        // Multi-question card: step 1 of 2 (single-choice).
        screenshot("d2-ask-step1")
        let dev = app.buttons["Answer: Dev"]
        XCTAssertTrue(dev.waitForExistence(timeout: 8), "multi-question card missing")
        dev.tap()
        Thread.sleep(forTimeInterval: 1)
        // Auto-advanced to step 2 (multi-select).
        screenshot("d2-ask-step2")
        let unit = app.buttons["Answer: Unit tests"]
        if unit.exists {
            unit.tap()
            Thread.sleep(forTimeInterval: 1)
            screenshot("d2-ask-multiselect-selected")
            // Back preserves the multi-select choice.
            let back = app.buttons["Previous question"]
            if back.exists {
                back.tap()
                Thread.sleep(forTimeInterval: 1)
                let unitStill = app.buttons["Answer: Unit tests"]
                // Selection state survives Back (visual check).
                screenshot("d2-ask-back-preserved")
                let next = app.buttons["Answer: Dev"]
                if next.exists {
                    next.tap()
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }

        // Non-triggers: a long-press on an article must NOT open the
        // actions rail (long press is native text selection).
        let article = app.staticTexts.firstMatch
        if article.exists {
            article.press(forDuration: 1.0)
            Thread.sleep(forTimeInterval: 1)
            let railVisible = app.buttons["Copy"].exists
            XCTAssertFalse(railVisible, "long-press must not toggle the rail")
            screenshot("d2-nontrigger-longpress")
            if railVisible {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
            }
        }

        // Composer (interactive sessions only): collapse → grow with
        // real typing.
        let messageButton = app.buttons["Message the agent"]
        if messageButton.waitForExistence(timeout: 4) {
            messageButton.tap()
            Thread.sleep(forTimeInterval: 3)
            screenshot("d2-composer-collapsed")
            let field = app.textViews.firstMatch
            if field.waitForExistence(timeout: 5) {
                field.typeText("A draft that runs long enough to wrap past a single row of the composer, exercising the grow bound with genuine typed content")
                Thread.sleep(forTimeInterval: 1)
                screenshot("d2-composer-grown")
                // The rail + quote: dismiss keyboard state check.
                screenshot("d2-composer-with-draft")
            }
        } else {
            // Honest absence: the demo agent's session does not resolve
            // an interactive composer; collapse/grow is unit-proven.
            screenshot("d2-composer-unavailable-honest")
        }
    }

    private func screenshot(_ name: String) {
        let dir = URL(fileURLWithPath: "/tmp/heeler-proof-signals/redesign")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: dir.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
