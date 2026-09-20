import XCTest

/// Tolerant TOFU/trust-alert confirmation. A sibling worker hit the case
/// where the first-connect "Trust this Host?" alert's Trust button was not
/// found across view states (alert raced the connecting sheet; buttons
/// re-homed between alerts and sheets between OS releases). Never assert
/// directly on a freshly-appeared alert — go through here.
extension XCUIApplication {
    /// Waits for a trust-class alert ("Trust this Host?", "Replace the
    /// trusted Host key?") and taps the affirmative button, tolerantly:
    /// re-finds the button each iteration and accepts either the app-owned
    /// alert or a Springboard-hosted one. No-op (returns false) if no
    /// alert appears within the timeout — callers decide whether that is
    /// a failure for their flow.
    @discardableResult
    func confirmTrustAlert(
        affirmButton: String = "Trust",
        timeout: TimeInterval = UITestTimeouts.trustAlert,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // The alert may be hosted by the app or by Springboard
            // (notification-permission-class). Probe both each iteration.
            for host in [self, springboard] {
                let alert = host.alerts.firstMatch
                guard alert.waitForExistence(timeout: 1) else { continue }
                let button = alert.buttons[affirmButton]
                if button.exists {
                    button.tap()
                    // The alert may present a second confirmation
                    // (replace-key flow); absorb one follow-up.
                    if let followUp = followUpConfirmation(in: host) {
                        followUp.tap()
                    }
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    /// The replace-key flow's second button, when present.
    private func followUpConfirmation(in host: XCUIApplication) -> XCUIElement? {
        let replace = host.buttons["Trust New Key"].firstMatch
        return replace.exists ? replace : nil
    }
}
