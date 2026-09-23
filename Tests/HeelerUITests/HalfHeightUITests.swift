// TEMP (throwaway): reproduce the device's half-height terminal — the
// user's flow: open agent (chat), raise the composer's keyboard, dismiss,
// tap the terminal icon, measure the surface's rendered geometry.
import XCTest

final class HalfHeightUITests: XCTestCase {
    private func capture(_ name: String) {
        let dir = URL(fileURLWithPath: "/tmp/heeler-proof-signals/half-height")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: dir.appendingPathComponent(name))
        try? XCUIApplication().debugDescription.write(
            to: dir.appendingPathComponent(name + "-ax.txt"),
            atomically: true, encoding: .utf8)
    }

    func testProvisionThenMeasureTerminalHeight() {
        let app = XCUIApplication()
        app.launch()
        sleep(10)

        // Provision (re-runnable).
        let addHost = app.buttons["Add Host"].firstMatch
        if addHost.waitForExistence(timeout: 8) {
            addHost.tap()
            sleep(4)
            var didOpenForm = false
            for button in app.buttons.matching(
                NSPredicate(format: "label == 'Add Manually'")).allElementsBoundByIndex
            {
                button.tap()
                sleep(4)
                if app.textFields.firstMatch.waitForExistence(timeout: 6) {
                    didOpenForm = true
                    break
                }
            }
            XCTAssertTrue(didOpenForm || app.textFields.firstMatch.exists, "manual form never opened")
            sleep(2)
            func field(_ prompt: String) -> XCUIElement {
                // v3's LabeledTextField: the AX placeholder carries the
                // PROMPT for titled fields (the title renders as a label).
                // Try the prompt first, then the title.
                let byPrompt = app.textFields.matching(
                    NSPredicate(format: "placeholderValue CONTAINS %@", prompt))
                if byPrompt.firstMatch.waitForExistence(timeout: 6) {
                    return byPrompt.firstMatch
                }
                let byTitle = app.textFields.matching(
                    NSPredicate(format: "placeholderValue CONTAINS %@", prompt == "Display name" ? "Optional" : prompt))
                XCTAssertTrue(
                    byTitle.firstMatch.waitForExistence(timeout: 6),
                    "field \(prompt) missing")
                return byTitle.firstMatch
            }
            let name = field("Display name")
            name.tap(); name.typeText("Local Mac")
            let user = field("user on the Host")
            user.tap(); user.typeText("jhou")
            let route = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'unnamed' OR label CONTAINS 'route'")).firstMatch
            XCTAssertTrue(route.waitForExistence(timeout: 10), "route row missing")
            route.tap()
            sleep(2)
            let address = field("host.example.com")
            address.tap(); address.typeText("127.0.0.1")
            let routeSave = app.buttons["Save"].firstMatch
            XCTAssertTrue(routeSave.waitForExistence(timeout: 10), "route Save missing")
            routeSave.tap()
            sleep(3)
            let save = app.buttons["Save"].firstMatch
            XCTAssertTrue(save.waitForExistence(timeout: 10), "form Save missing")
            save.tap()
            sleep(4)
            for _ in 0..<4 {
                if app.buttons["Open navigation"].firstMatch.exists { break }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)))
                sleep(3)
            }
        }

        // Hosts → trust (first run) → dump the device key for the shell.
        let nav = app.buttons["Open navigation"].firstMatch
        XCTAssertTrue(nav.waitForExistence(timeout: 15), "nav trigger missing")
        nav.tap(); sleep(2)
        let hosts = app.buttons["Hosts"].firstMatch
        XCTAssertTrue(hosts.waitForExistence(timeout: 10), "Hosts missing")
        hosts.tap(); sleep(4)
        let host = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Local Mac'")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 15), "host row missing")
        host.tap(); sleep(4)

        if !FileManager.default.fileExists(atPath: "/tmp/heeler-proof-signals/half-height/device-key-line.txt") {
            let trust = app.buttons["Trust"].firstMatch
            if trust.waitForExistence(timeout: 20) { trust.tap(); sleep(12) }
            let edit = app.buttons.matching(
                NSPredicate(format: "label CONTAINS 'Edit'")).firstMatch
            if edit.waitForExistence(timeout: 8) {
                edit.tap(); sleep(4)
                let disclosure = app.buttons.matching(
                    NSPredicate(format: "label CONTAINS 'authorized_keys'")).firstMatch
                if disclosure.waitForExistence(timeout: 8) { disclosure.tap(); sleep(2) }
                let dump = app.debugDescription
                if let range = dump.range(of: "ssh-ed25519 ") {
                    let tail = String(dump[range.lowerBound...])
                    let cleaned = tail.prefix(200).prefix(while: { $0 != "'" && $0 != "\n" })
                    try? String(cleaned).write(
                        to: URL(fileURLWithPath: "/tmp/heeler-proof-signals/half-height/device-key-line.txt"),
                        atomically: true, encoding: .utf8)
                }
                let cancel2 = app.buttons["Cancel"].firstMatch
                if cancel2.exists { cancel2.tap(); sleep(2) }
            } else {
                let trust2 = app.buttons["Trust"].firstMatch
                if trust2.waitForExistence(timeout: 15) { trust2.tap(); sleep(12) }
            }
        } else {
            let trust = app.buttons["Trust"].firstMatch
            if trust.waitForExistence(timeout: 15) { trust.tap(); sleep(12) }
        }
        capture("host-detail")

        // Back to Agents, open a real agent (chat default).
        let back = app.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 8) { back.tap(); sleep(2) }
        let nav2 = app.buttons["Open navigation"].firstMatch
        if nav2.waitForExistence(timeout: 8) {
            nav2.tap(); sleep(2)
            let agents = app.buttons["Agents"].firstMatch
            if agents.waitForExistence(timeout: 8) { agents.tap(); sleep(4) }
        }
        let agentRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'status'")).firstMatch
        XCTAssertTrue(agentRow.waitForExistence(timeout: 40), "no agent rows")
        agentRow.tap()
        sleep(8)
        capture("chat-default")

        // THE USER'S FLOW: raise the chat composer's keyboard, dismiss it.
        let composerField = app.textViews.firstMatch
        if composerField.waitForExistence(timeout: 10) {
            composerField.tap()
            sleep(3)
            capture("chat-keyboard-up")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
            sleep(3)
            capture("chat-keyboard-down")
        }

        // Tap the terminal icon.
        let showTerminal = app.buttons["Show Terminal"].firstMatch
        XCTAssertTrue(showTerminal.waitForExistence(timeout: 10), "Show Terminal missing")
        showTerminal.tap()
        sleep(14)
        capture("terminal-after-chat-keyboard")

        // Measure the terminal surface's frame from the AX tree.
        let dump = app.debugDescription
        try? dump.write(
            to: URL(fileURLWithPath: "/tmp/heeler-proof-signals/half-height/terminal-ax.txt"),
            atomically: true, encoding: .utf8)
    }
}
