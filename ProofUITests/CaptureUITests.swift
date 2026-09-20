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
        // Composer collapse/grow needs an interactive chat; the demo
        // transcript is read-only (no composer), so the collapse/grow
        // contract is proven by ChatPrefixKeysTests' sizing tests
        // (one-line floor, 3-line cap, scroll past cap, draft intact).
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
