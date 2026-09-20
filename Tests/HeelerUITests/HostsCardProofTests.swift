import XCTest

/// Handoff §E proofs, hosts-slice: the redesigned Host cards and their
/// per-route inspectors. Two user-visible behaviors:
///
/// 1. Tapping a named route on a Host card opens the route inspector
///    titled `HOST · ROUTE` with the exact address:port and user, and an
///    honest in-use/alternate state (an unknown alternate is never shown
///    connected).
/// 2. The route edit flow from the Host form targets the SELECTED route
///    row: typing a new label + address and saving updates exactly that
///    row.
///
/// Route rows carry `host-route-<address>` / `host-form-route-<uuid>`
/// accessibility identifiers; assertions on state use the visible chips.
@MainActor
final class HostsCardProofTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
    }

    // MARK: Route inspector from a card tap

    /// The Studio Mac card lists its NAMED routes with exact address and
    /// state; tapping the primary route opens the `Studio Mac · Primary`
    /// inspector showing the exact target and in-use status.
    func testRouteTapOpensInspectorForThatRoute() {
        app = UITestApp.launchDemo(.hostList)

        // The primary route row (identifier is stable), whose label
        // carries the route name + exact address + in-use state.
        let primaryRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'host-route-studio.demo.invalid'"))
            .firstMatch
        waitToExist(primaryRow)
        let primaryLabel = primaryRow.label
        XCTAssertTrue(
            primaryLabel.contains(UITestFixtures.studioMacPrimaryRoute),
            "primary route row label missing route name: \(primaryLabel)")
        XCTAssertTrue(
            primaryLabel.contains(UITestFixtures.studioMacPrimaryAddress),
            "primary route row label missing exact address: \(primaryLabel)")
        XCTAssertTrue(
            primaryLabel.contains("currently in use"),
            "dialed route must be presented in use: \(primaryLabel)")

        // Tap the route row: the inspector for THAT route opens, titled
        // HOST · ROUTE.
        primaryRow.tap()
        let inspectorTitle = app.navigationBars["Studio Mac · Primary"]
        XCTAssertTrue(
            inspectorTitle.waitForExistence(timeout: UITestTimeouts.standard),
            "route inspector titled 'HOST · ROUTE' never appeared")

        // The connection target shows the exact address:port and user.
        waitToExist(app.staticTexts[UITestFixtures.studioMacPrimaryAddress])
        waitToExist(app.staticTexts["developer"])

        // Route selection is honest: the primary route says it is in
        // use (identifier'd value; label carries the whole LabeledContent
        // row merged, so match by content).
        let selection = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'route-selection'")).firstMatch
        waitToExist(selection)
        XCTAssertTrue(
            selection.label.contains("Currently in use"),
            "route selection value wrong: \(selection.label)")
        captureScreenshot(app, "route-inspector-in-use")
    }

    /// The alternate route is honest: its card row says "Alternate" and
    /// the inspector never claims it is connected — reachability is
    /// "Not checked this session" until the user presses Check.
    func testAlternateRouteIsHonestAboutUnknownReachability() {
        app = UITestApp.launchDemo(.hostList)

        let lanRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'host-route-studio.lan.demo.invalid'"))
            .firstMatch
        waitToExist(lanRow)
        let lanLabel = lanRow.label
        XCTAssertTrue(
            lanLabel.contains("alternate route"),
            "non-dialed route must present as alternate: \(lanLabel)")
        XCTAssertTrue(
            lanLabel.contains("reachability unknown until checked"),
            "alternate reachability must be stated unknown: \(lanLabel)")
        // The card's state chip for the alternate route.
        waitToExist(app.staticTexts["Alternate"])

        lanRow.tap()
        let inspectorTitle = app.navigationBars["Studio Mac · Local network"]
        XCTAssertTrue(
            inspectorTitle.waitForExistence(timeout: UITestTimeouts.standard),
            "alternate route inspector never appeared")

        // Never falsely connected: the SSH-connection row says unknown
        // reachability, never "Connected" (identifier'd value; LabeledContent
        // merges the row, so match by content).
        let sshRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'route-ssh-connection'")).firstMatch
        waitToExist(sshRow)
        XCTAssertTrue(
            sshRow.label.contains("Not checked this session"),
            "alternate reachability must be unknown, got: \(sshRow.label)")
        XCTAssertFalse(
            sshRow.label.contains("Connected"),
            "unchecked alternate route must not be shown Connected")
        let selection = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'route-selection'")).firstMatch
        waitToExist(selection)
        XCTAssertTrue(
            selection.label.contains("Available alternative"),
            "alternate selection value wrong: \(selection.label)")
        captureScreenshot(app, "route-inspector-alternate")
    }

    // MARK: Route edit flow targets the selected row

    /// From the Host form: tapping a route row opens the route editor
    /// carrying that row's values; a typed label + address save back to
    /// exactly that row (typing bar: real keystrokes, focus retained).
    func testRouteEditFlowTargetsSelectedRow() {
        app = UITestApp.launchDemo(.hostForm)
        waitToExist(app.navigationBars[UITestFixtures.hostFormTitle])

        // The multipath demo Host's rows are UUID-keyed; find the VPN
        // row by its label content.
        let vpnRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'host-form-route-' AND label CONTAINS 'VPN'")
        ).firstMatch
        waitToExist(vpnRow)
        vpnRow.tap()

        // The route editor carries the selected row's values.
        let editor = app.navigationBars["Edit route"]
        XCTAssertTrue(
            editor.waitForExistence(timeout: UITestTimeouts.standard),
            "route editor never appeared")
        let labelField = app.textFields["Route label"]
        waitToExist(labelField)
        let addressField = app.textFields["Hostname or address"]
        waitToExist(addressField)

        // Type a new label with real keystrokes. (Same focus-retention
        // contract as the helper, but trimmed comparison: the sheet's
        // field can expose a trailing control character in .value.)
        labelField.tap()
        app.waitForKeyboard()
        labelField.typeText(
            String(
                repeating: XCUIKeyboardKey.delete.rawValue,
                count: (labelField.value as? String ?? "").count + 2))
        labelField.typeText("VPN tunnel")
        XCTAssertTrue(
            app.isKeyboardPresented,
            "keyboard dismissed while typing the route label — field lost focus")
        XCTAssertEqual(
            (labelField.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            "VPN tunnel",
            "typed route label not retained")

        // Type a new address; the earlier typed label must survive the
        // focus move.
        addressField.tap()
        app.waitForKeyboard()
        addressField.typeText(
            String(
                repeating: XCUIKeyboardKey.delete.rawValue,
                count: (addressField.value as? String ?? "").count + 2))
        addressField.typeText("vpn2.example.com")
        XCTAssertTrue(
            app.isKeyboardPresented,
            "keyboard dismissed while typing the route address — field lost focus")
        XCTAssertEqual(
            (addressField.value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            "vpn2.example.com",
            "typed route address not retained")
        XCTAssertEqual(
            (labelField.value as? String ?? "").trimmingCharacters(in: .whitespaces),
            "VPN tunnel",
            "typed route label not retained after focus moved")
        // Save: the editor closes and exactly THAT row shows the edited
        // label + address.
        // The editor's Save, identified: the form's own Save button stays in
        // the AX tree behind the sheet (XCUITest hittability is not
        // occlusion-aware), so the identifier is the only safe selector.
        let save = app.buttons["route-editor-save"]
        waitToExist(save)
        save.tap()
        let savedRow = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'host-form-route-' AND label CONTAINS 'VPN tunnel'"))
            .firstMatch
        XCTAssertTrue(
            savedRow.waitForExistence(timeout: UITestTimeouts.standard),
            "edited route row did not update to the typed label/address")
        XCTAssertTrue(
            savedRow.label.contains("vpn2.example.com"),
            "edited route row missing typed address: \(savedRow.label)")
        captureScreenshot(app, "route-edit-saved")
    }
}
