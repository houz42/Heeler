import XCTest

/// THE TYPING BAR: form-input proofs must type REAL keystrokes and assert
/// the field retained focus and the typed value, not just screenshot. This
/// helper is that contract, one line per call.
///
/// Why a helper: XCUITest `typeText` fails cryptically when the field
/// loses focus mid-type (hardware-keyboard routing on sim, first-responder
/// steals), and form rows that rebuild (UUID-keyed address rows) drop
/// state if identity broke. The keyboard-presence + value assertions
/// catch both. `XCUIElement` cannot reach its owning app in this SDK, so
/// the caller passes the app alongside the field.
extension XCUIElement {
    /// Taps the field, waits for the keyboard, types the text, and
    /// asserts the typed value was retained AND the keyboard stayed up
    /// (the observable form of focus retention).
    /// - Parameters:
    ///   - app: the owning application (for keyboard queries).
    ///   - text: keystrokes to send.
    ///   - expected: the value the field must read after typing; defaults
    ///     to `text` (pass a different value when typing into a
    ///     pre-populated field).
    func typeTextWithFocusAssertion(
        on app: XCUIApplication,
        _ text: String,
        expecting expected: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tap()
        guard app.waitForKeyboard(file: file, line: line) else { return }
        typeText(text)
        // THE assertion pair — a proof without both is not a typing proof.
        XCTAssertTrue(
            app.isKeyboardPresented,
            "keyboard dismissed while typing — field lost focus",
            file: file, line: line)
        let value = value as? String ?? ""
        XCTAssertEqual(
            value.replacingOccurrences(of: "\n", with: ""),
            expected ?? text,
            "typed text was not retained by the field",
            file: file, line: line)
    }
}

/// Keyboard-state helpers shared by typing and trust-alert code.
extension XCUIApplication {
    /// Waits for the system keyboard — the precondition for `typeText`.
    @discardableResult
    func waitForKeyboard(
        timeout: TimeInterval = UITestTimeouts.keyboard,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let appeared = keyboards.firstMatch.waitForExistence(timeout: timeout)
        if !appeared {
            XCTFail("keyboard never appeared", file: file, line: line)
        }
        return appeared
    }

    /// Dismisses the keyboard without leaving the screen (tap a far corner
    /// of the scroll area). Use between assertions when a raised keyboard
    /// would cover the element under test.
    func dismissKeyboardTolerantly() {
        if isKeyboardPresented {
            // The toolbar above the keyboard is the most reliable target;
            // fall back to a swipe on the content area.
            let bar = keyboards.toolbars.buttons.firstMatch
            if bar.exists { bar.tap() } else { swipeDown(velocity: .fast) }
        }
    }
}
