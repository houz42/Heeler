import XCTest

/// Smoke: the Chat surface renders its transcript from the demo fixture
/// and the composer input is reachable — the harness's proof that chat
/// flows are testable end-to-end without a real SSH session.
@MainActor
final class ChatSmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = UITestApp.launchDemo(.console)
    }

    override func tearDown() {
        app.terminate()
    }

    /// An agent with a `.path` session opens straight into Chat with the
    /// transcript rendered and the composer reachable.
    func testChatShowsTranscriptAndComposer() {
        // Tap through the row's enclosing cell (the NavigationLink's hit
        // target).
        let cell = app.cells.containing(
            NSPredicate(format: "label CONTAINS %@", "ios-polish")
        ).firstMatch
        waitToExist(cell)
        cell.tap()
        XCTAssertTrue(app.waitForPushedDetail(), "agent detail never pushed")

        // The fixture transcript's closing line is present in the chat pane.
        waitToExist(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "All 18 tests pass")
            ).firstMatch)
        // The composer's entry button is present (opens the input frame;
        // typing proofs extend from here).
        waitToExist(app.chatComposerButton)
        captureScreenshot(app, "chat-demo")
    }
}
