import XCTest

/// Smoke: the Host form's typing bar — real keystrokes with focus
/// retention, per the user rule. This is the canonical example of a
/// FORM-INPUT PROOF: static screenshots are insufficient for form work.
@MainActor
final class HostFormTypingSmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        // The form route opens HostFormView editing the multipath demo
        // Host, so rows are pre-populated.
        app = UITestApp.launchDemo(.hostForm)
    }

    override func tearDown() {
        app.terminate()
    }

    /// Real keystrokes into the form's fields retain value, and moving
    /// focus between fields preserves earlier typed values — the typing
    /// bar in one test.
    func testTypingRetainsFocusAndValue() {
        // The form's title confirms the route before touching fields.
        waitToExist(app.navigationBars[UITestFixtures.hostFormTitle])

        // Pre-populated multipath address row must be visible.
        waitToExist(app.textFields[UITestFixtures.hostFormExistingAddress])

        // Name field: clear the pre-populated value then type a real one.
        // Selection gestures are unreliable (no keyboard Select All on
        // this OS; tap-count gestures select a word only), so clear by
        // typing one delete per existing character — deterministic.
        let name = app.textFields["Name (optional)"]
        waitToExist(name)
        name.tap()
        app.waitForKeyboard()
        let nameClear = (name.value as? String ?? "").count
        name.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: nameClear + 2))
        name.typeText("Studio Mac Pro")
        XCTAssertEqual(
            (name.value as? String ?? "").trimmingCharacters(in: .whitespaces),
            "Studio Mac Pro",
            "typed name not retained")

        // Move focus to the User field (also pre-populated): clear, type,
        // and prove the value sticks while the keyboard stays up.
        let user = app.textFields["User"]
        user.typeTextWithFocusAssertion(
            on: app,
            String(
                repeating: XCUIKeyboardKey.delete.rawValue,
                count: (user.value as? String ?? "").count + 2)
                + "builder",
            expecting: "builder")

        // The Name field still holds its typed value after focus moved.
        XCTAssertEqual(
            (name.value as? String ?? "").trimmingCharacters(in: .whitespaces),
            "Studio Mac Pro",
            "typed name not retained after focus moved")
        captureScreenshot(app, "host-form-typed")
    }
}
