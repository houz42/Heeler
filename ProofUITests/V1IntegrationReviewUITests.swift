// TEMP (integration review harness — reverts at port time with the family):
// walks the integrated app's main surfaces and dumps each page's AX tree
// to /tmp/v1-review/<page>.txt for Main's design-verification pass.
import XCTest

final class V1IntegrationReviewUITests: XCTestCase {
    private func dump(_ app: XCUIApplication, _ name: String) {
        let tree = app.debugDescription
        try? tree.write(
            to: URL(fileURLWithPath: "/tmp/v1-review/\(name).txt"),
            atomically: true, encoding: .utf8)
    }

    func testWalkAndDumpSurfaces() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-screenshots"]
        app.launch()
        sleep(5)

        // Agents (landing)
        dump(app, "ax-agents")

        // Drawer (open; dump; close via scrim coordinate)
        app.buttons["Open navigation"].firstMatch.tap()
        sleep(2)
        dump(app, "ax-drawer")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        sleep(1)

        // Hosts page via drawer
        app.buttons["Open navigation"].firstMatch.tap()
        sleep(1)
        app.buttons["Hosts"].firstMatch.tap()
        sleep(3)
        dump(app, "ax-hosts")

        // Settings page via drawer
        app.buttons["Open navigation"].firstMatch.tap()
        sleep(1)
        app.buttons["Settings"].firstMatch.tap()
        sleep(3)
        dump(app, "ax-settings")

        // Back to Agents, tap a row into the chat detail
        app.buttons["Open navigation"].firstMatch.tap()
        sleep(1)
        app.buttons["Agents"].firstMatch.tap()
        sleep(2)
        let row = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@",
                "Polish the Attach experience")).firstMatch
        if row.waitForExistence(timeout: 10) { row.tap(); sleep(4) }
        dump(app, "ax-chat-detail")
    }
}
