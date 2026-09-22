import XCTest

/// Smoke: the Host form's typing bar — real keystrokes with focus
/// retention, per the user rule. This is the canonical example of a
/// FORM-INPUT PROOF: static screenshots are insufficient for form work.
/// Updated for the redesigned labeled form (handoff §E): the name field
/// is "Display name", the account field is "SSH username", and address
/// rows are tappable named-route rows (not inline text fields).
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

        // The primary route row is pre-populated with the multipath
        // Host's address (a named-route row now, whose label carries
        // the address).
        let primaryRoute = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'host-form-route-'"))
            .firstMatch
        waitToExist(primaryRoute)
        XCTAssertTrue(
            primaryRoute.label.contains(UITestFixtures.hostFormExistingAddress),
            "primary route row missing the multipath address: \(primaryRoute.label)")

        // Display-name field: clear the pre-populated value then type a
        // real one. Selection gestures are unreliable (no keyboard Select
        // All on this OS; tap-count gestures select a word only), so
        // clear by typing one delete per existing character —
        // deterministic.
        let name = app.textFields[UITestFixtures.hostFormNameField]
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

        // Move focus to the SSH-username field (also pre-populated):
        // clear, type, and prove the value sticks while the keyboard
        // stays up.
        let user = app.textFields[UITestFixtures.hostFormUserField]
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
        captureScreenshot(app, "host-form-typed", lifetime: .keepAlways)
    }
}
