import XCTest

/// Screenshot capture attached to the current test's record. XCUITest
/// runs sandboxed; XCTAttachment (collected into the .xcresult bundle)
/// is the canonical sink — call this for the record, and prefer
/// accessibility-tree assertions over pixel checks.
extension XCTestCase {
    /// Full-screen screenshot of `app` attached to the current test.
    /// `name` becomes the attachment's identifier in the result bundle.
    func captureScreenshot(
        _ app: XCUIApplication,
        _ name: String,
        lifetime: XCTAttachment.Lifetime = .deleteOnSuccess
    ) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = lifetime
        add(shot)
    }
}

/// One-line element existence waits with the shared timeout budget.
func waitToExist(
    _ element: XCUIElement,
    timeout: TimeInterval = UITestTimeouts.standard,
    file: StaticString = #filePath,
    line: UInt = #line
) -> XCUIElement {
    XCTAssertTrue(
        element.waitForExistence(timeout: timeout),
        "\(element) never appeared",
        file: file, line: line)
    return element
}
