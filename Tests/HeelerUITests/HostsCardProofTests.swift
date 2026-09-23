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

        // The card list itself: both named routes with their chips.
        captureScreenshot(app, "host-card-routes", lifetime: .keepAlways)

        // Tap the route CHEVRON: the inspector for THAT route opens,
        // titled HOST · ROUTE (the row itself is the switch now).
        let primaryChevron = app.buttons["route-chevron-studio.demo.invalid"]
        waitToExist(primaryChevron)
        primaryChevron.tap()
        let inspectorTitle = app.navigationBars["Studio Mac · Primary"]
        XCTAssertTrue(
            inspectorTitle.waitForExistence(timeout: UITestTimeouts.standard),
            "route inspector titled 'HOST · ROUTE' never appeared")

        // The compact connection-target block shows the exact
        // address:port and the user·state subline (one merged element).
        let target = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'route-connection-target'")).firstMatch
        waitToExist(target)
        XCTAssertTrue(
            target.label.contains(UITestFixtures.studioMacPrimaryAddress),
            "connection target missing the exact address: \(target.label)")
        XCTAssertTrue(
            target.label.contains("developer"),
            "connection target missing the user: \(target.label)")

        // Route selection is honest: the primary route says it is in
        // use (identifier'd value; label carries the whole LabeledContent
        // row merged, so match by content). Rows themselves are quiet:
        // the green dot is the in-use signal, no state text on the row.
        let selection = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'route-selection'")).firstMatch
        waitToExist(selection)
        XCTAssertTrue(
            selection.label.contains("Currently in use"),
            "route selection value wrong: \(selection.label)")
        captureScreenshot(app, "route-inspector-in-use", lifetime: .keepAlways)
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
            lanLabel.contains("alternate route"),
            "the row must present as an alternate: \(lanLabel)")
        XCTAssertTrue(
            lanLabel.contains("switch to this route"),
            "the row's AX label must offer the switch action: \(lanLabel)")
        // The row is quiet: no state TEXT may render on route rows (the
        // dot alone signals; the user's design decision).
        for word in ["In use", "Alternate"] {
            XCTAssertEqual(
                app.staticTexts[word].firstMatch.exists, false,
                "route rows must not render state text ('\(word)' found)")
        }

        let lanChevron = app.buttons["route-chevron-studio.lan.demo.invalid"]
        waitToExist(lanChevron)
        lanChevron.tap()
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
        captureScreenshot(app, "route-inspector-alternate", lifetime: .keepAlways)
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
        let editor = app.navigationBars["Edit route on Studio Mac"]
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
        captureScreenshot(app, "route-edit-saved", lifetime: .keepAlways)
    }

    // MARK: Card chrome is quiet (user directive)

    /// The card carries NO Edit button (user directive: the name line
    /// already leads to the detail page's own Edit). Asserts absence so
    /// the control does not creep back; the detail chevron stays.
    func testCardHasNoEditButtonButChevronLeadsToDetail() {
        app = UITestApp.launchDemo(.hostList)

        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "identifier == 'host-card-edit'")).firstMatch.exists,
            false,
            "the card-level Edit button must not exist (user directive)")
        let chevron = app.buttons["host-card-detail-chevron"].firstMatch
        waitToExist(chevron)
        chevron.tap()
        // The heading chevron opens the SAME detail the name does.
        let detail = app.navigationBars["Studio Mac"]
        XCTAssertTrue(
            detail.waitForExistence(timeout: UITestTimeouts.standard),
            "card chevron should open the Host detail")
    }

    // MARK: Row tap switches the route (user directive)

    /// Tapping a route ROW on the card switches the Host's active dial
    /// path (PreferredAddressStore semantics): observable on the DETAIL
    /// page's Routes section, where the switched route leads and carries
    /// the active mark (AX "active route"). Instant, no confirmation.
    func testRouteRowTapSwitchesThePreferredPath() {
        app = UITestApp.launchDemo(.hostList)

        // Tap the NON-active route row: Local network on Studio Mac.
        let lanRow = app.buttons["host-route-studio.lan.demo.invalid"]
        waitToExist(lanRow)
        lanRow.tap()

        // The row is a switch: the inspector must NOT open from the row.
        XCTAssertFalse(
            app.navigationBars["Studio Mac · Local network"]
                .waitForExistence(timeout: 2),
            "a row tap must switch the route, not open the inspector")

        // The preference is observable on the detail page's Routes
        // section: the switched route LEADS and its row reads as the
        // active route (identifier'd rows; the section lists route
        // names + exact address:port).
        let heading = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Open details for Studio Mac'")
        ).firstMatch
        waitToExist(heading)
        heading.tap()
        let lanDetailRow = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'host-detail-route-studio.lan.demo.invalid'"))
            .firstMatch
        waitToExist(lanDetailRow)
        XCTAssertTrue(
            lanDetailRow.label.contains("active route"),
            "the switched route must read as the active route: \(lanDetailRow.label)")
        captureScreenshot(app, "route-switched-active", lifetime: .keepAlways)
    }

    // MARK: Detail route rows: tap = switch, persists, honest marks

    /// The Host DETAIL's route rows (user directive): every route is a
    /// tappable row; tapping makes it the active route (green checkmark
    /// + "active route" AX state) — and only one row is ever active.
    /// Switching while the primary route is the live connection keeps
    /// the bolt on the live row: the tap never claims the live route
    /// moved, it only sets the next-connect path.
    func testDetailRouteTapSwitchesActiveRoute() {
        app = UITestApp.launchDemo(.hostList)

        let heading = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Open details for Studio Mac'")
        ).firstMatch
        waitToExist(heading)
        heading.tap()

        let primaryRow = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'host-detail-route-studio.demo.invalid'"))
            .firstMatch
        let lanRow = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'host-detail-route-studio.lan.demo.invalid'"))
            .firstMatch
        waitToExist(primaryRow)
        waitToExist(lanRow)

        // Tap the Local network route: it becomes the active route.
        lanRow.tap()
        let activePredicate = NSPredicate(format: "label CONTAINS 'active route'")
        expectation(for: activePredicate, evaluatedWith: lanRow)
        waitForExpectations(timeout: UITestTimeouts.standard)
        XCTAssertFalse(
            primaryRow.label.contains("active route"),
            "exactly one row may be active: \(primaryRow.label)")
        XCTAssertTrue(
            primaryRow.label.contains("currently in use"),
            "the live route keeps its honest in-use mark: \(primaryRow.label)")
        captureScreenshot(app, "detail-route-switched", lifetime: .keepAlways)

        // Switch back: the active mark returns to the primary row (a
        // switch is reversible; exactly one row active at a time).
        primaryRow.tap()
        expectation(for: activePredicate, evaluatedWith: primaryRow)
        waitForExpectations(timeout: UITestTimeouts.standard)
        XCTAssertFalse(
            lanRow.label.contains("active route"),
            "switching away must clear the previous active mark: \(lanRow.label)")
        captureScreenshot(app, "detail-route-switched-back", lifetime: .keepAlways)
    }

    /// The active-route selection PERSISTS: relaunch the app, open the
    /// same Host detail, and the route tapped before relaunch still
    /// reads as the active one (per-Host preference on disk).
    func testDetailActiveRoutePersistsAcrossRelaunch() {
        app = UITestApp.launchDemo(.hostList)
        let heading = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Open details for Studio Mac'")
        ).firstMatch
        waitToExist(heading)
        heading.tap()
        let lanRow = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'host-detail-route-studio.lan.demo.invalid'"))
            .firstMatch
        waitToExist(lanRow)
        lanRow.tap()
        let activePredicate = NSPredicate(format: "label CONTAINS 'active route'")
        expectation(for: activePredicate, evaluatedWith: lanRow)
        waitForExpectations(timeout: UITestTimeouts.standard)

        // Relaunch: the same Host detail must show the same active route.
        // (Re-resolve every element against the NEW app instance — the
        // old XCUIApplication object's queries die with the process.)
        app.terminate()
        app = UITestApp.launchDemo(.hostList)
        let relaunchedHeading = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Open details for Studio Mac'")
        ).firstMatch
        waitToExist(relaunchedHeading)
        relaunchedHeading.tap()
        let relaunchedLanRow = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'host-detail-route-studio.lan.demo.invalid'"))
            .firstMatch
        XCTAssertTrue(
            relaunchedLanRow.waitForExistence(timeout: UITestTimeouts.launch),
            "relaunched detail must list the Host's routes")
        XCTAssertTrue(
            relaunchedLanRow.label.contains("active route"),
            "the route tapped before relaunch must still be the active one: "
                + relaunchedLanRow.label)
        captureScreenshot(app, "detail-route-persisted-relaunch", lifetime: .keepAlways)
    }

    /// The route CHEVRON opens the inspector for THAT route (the row's
    /// second action).
    func testRouteChevronOpensTheInspector() {
        app = UITestApp.launchDemo(.hostList)

        let chevron = app.buttons["route-chevron-studio.lan.demo.invalid"]
        waitToExist(chevron)
        chevron.tap()
        let inspector = app.navigationBars["Studio Mac · Local network"]
        XCTAssertTrue(
            inspector.waitForExistence(timeout: UITestTimeouts.standard),
            "the route chevron must open the route inspector")
        captureScreenshot(app, "route-chevron-inspector", lifetime: .keepAlways)
    }

    // MARK: Route removal is deliberate and floor-guarded

    /// The editor's Remove deletes exactly that route; the last remaining
    /// route cannot be removed (the model's floor).
    func testRouteRemoveTargetsThatRowAndFloorSurvives() {
        app = UITestApp.launchDemo(.hostForm)
        waitToExist(app.navigationBars[UITestFixtures.hostFormTitle])

        // Edit the VPN route (3rd of 3): remove it; the other two survive.
        let vpnRow = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'host-form-route-' AND label CONTAINS 'VPN'")
        ).firstMatch
        waitToExist(vpnRow)
        vpnRow.tap()
        let editor = app.navigationBars["Edit route on Studio Mac"]
        XCTAssertTrue(
            editor.waitForExistence(timeout: UITestTimeouts.standard),
            "route editor never appeared")

        let remove = app.buttons["route-editor-remove"]
        waitToExist(remove)
        remove.tap()
        XCTAssertTrue(
            app.navigationBars[UITestFixtures.hostFormTitle]
                .waitForExistence(timeout: UITestTimeouts.standard),
            "editor did not close after removal")
        // VPN row is gone; the other two routes remain.
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH 'host-form-route-' AND label CONTAINS 'VPN'")
            ).firstMatch.exists,
            "removed route row still present")
        for kept in ["Local network", "Bonjour"] {
            XCTAssertTrue(
                app.buttons.matching(
                    NSPredicate(
                        format: "identifier BEGINSWITH 'host-form-route-' AND label CONTAINS %@", kept)
                ).firstMatch.exists,
                "route \(kept) should have survived the removal")
        }
        captureScreenshot(app, "route-removed", lifetime: .keepAlways)
    }

    // MARK: Dirty swipe-dismiss is blocked

    /// A dirty draft cannot be discarded by the swipe-down gesture:
    /// interactive dismiss is disabled while edits exist; the guarded
    /// Cancel is the only dirty exit (approved behavior contract).
    func testDirtySwipeDismissIsBlocked() {
        app = UITestApp.launchDemo(.hostForm)
        waitToExist(app.navigationBars[UITestFixtures.hostFormTitle])

        // Make the draft dirty with a real keystroke.
        let name = app.textFields[UITestFixtures.hostFormNameField]
        waitToExist(name)
        name.tap()
        app.waitForKeyboard()
        name.typeText("x")

        // Swipe down (the sheet-dismiss gesture): the form must stay.
        app.navigationBars[UITestFixtures.hostFormTitle].swipeDown(velocity: .fast)
        XCTAssertTrue(
            app.navigationBars[UITestFixtures.hostFormTitle]
                .waitForExistence(timeout: UITestTimeouts.standard),
            "swipe-down dismissed a dirty host form")

        // The guarded Cancel is the only dirty exit: it CONFIRMS.
        app.buttons["Cancel"].firstMatch.tap()
        let discard = app.buttons["Discard Changes"]
        XCTAssertTrue(
            discard.waitForExistence(timeout: UITestTimeouts.standard),
            "dirty Cancel must confirm before discarding")
        discard.tap()
    }

    // MARK: Final route: no successful-looking removal

    /// The LAST remaining route's editor offers no Remove at all — a
    /// removal-looking action must never exist for the floor route.
    func testFinalRouteEditorOffersNoRemove() {
        app = UITestApp.launchDemo(.hostForm)
        waitToExist(app.navigationBars[UITestFixtures.hostFormTitle])

        // Remove two of the three routes through the editor (each
        // removal leaves more than one, so Remove is offered).
        for routeLabel in ["VPN", "Bonjour"] {
            let row = app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH 'host-form-route-' AND label CONTAINS %@", routeLabel)
            ).firstMatch
            waitToExist(row)
            row.tap()
            let editor = app.navigationBars["Edit route on Studio Mac"]
            XCTAssertTrue(editor.waitForExistence(timeout: UITestTimeouts.standard))
            let remove = app.buttons["route-editor-remove"]
            waitToExist(remove)
            remove.tap()
            XCTAssertTrue(
                app.navigationBars[UITestFixtures.hostFormTitle]
                    .waitForExistence(timeout: UITestTimeouts.standard))
        }

        // One route remains (the primary). Its editor must offer NO
        // Remove — the floor route cannot look removable.
        let primary = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'host-form-route-' AND label CONTAINS '192.168.31.71'")
        ).firstMatch
        waitToExist(primary)
        primary.tap()
        let editor = app.navigationBars["Edit route on Studio Mac"]
        XCTAssertTrue(
            editor.waitForExistence(timeout: UITestTimeouts.standard),
            "primary route editor never appeared")
        XCTAssertEqual(
            app.buttons["route-editor-remove"].firstMatch.exists, false,
            "the last remaining route must not offer Remove")
        captureScreenshot(app, "final-route-editor", lifetime: .keepAlways)
    }

    // MARK: Naming reachable in-context (device finding)

    /// The inspector's Edit affordance opens the SAME route editor; a
    /// typed label saves to the catalog, and the LIST ROW plus the
    /// inspector both show the friendly name immediately.
    func testEditRouteFromInspectorNamesTheRoute() {
        app = UITestApp.launchDemo(.hostList)

        // The Build Server card's single route is unnamed (the demo
        // fixture gives it no label) — its inspector says "Name this
        // route" (the in-context hint).
        let chevron = app.buttons["route-chevron-build.demo.invalid"]
        waitToExist(chevron)
        chevron.tap()
        let inspector = app.navigationBars["Build Server · build.demo.invalid"]
        XCTAssertTrue(
            inspector.waitForExistence(timeout: UITestTimeouts.standard),
            "unnamed route inspector never appeared")

        // The compact sheet may need one scroll to reveal the action
        // rows on smaller content-height detents.
        let edit = app.buttons["route-inspector-edit"]
        if !edit.waitForExistence(timeout: 3) {
            app.swipeUp(velocity: .fast)
        }
        waitToExist(edit)
        XCTAssertTrue(edit.label.contains("Name this route"))
        edit.tap()

        // The SAME route editor, scoped to the host.
        let editor = app.navigationBars["Edit route on Build Server"]
        XCTAssertTrue(
            editor.waitForExistence(timeout: UITestTimeouts.standard),
            "in-inspector route editor never appeared")
        let labelField = app.textFields["Route label"]
        waitToExist(labelField)
        labelField.tap()
        app.waitForKeyboard()
        labelField.typeText("Datacenter")
        let save = app.buttons["route-editor-save"]
        waitToExist(save)
        save.tap()

        // The inspector (still open) now shows the friendly name in its
        // title; the list row shows it after Done.
        XCTAssertTrue(
            app.navigationBars["Build Server · Datacenter"]
                .waitForExistence(timeout: UITestTimeouts.standard),
            "inspector title did not pick up the saved friendly name")
        app.buttons["Done"].firstMatch.tap()
        let namedRow = app.buttons["host-route-build.demo.invalid"]
        waitToExist(namedRow)
        XCTAssertTrue(
            namedRow.label.contains("Datacenter"),
            "list row did not show the saved friendly name: \(namedRow.label)")
        captureScreenshot(app, "route-named-in-context", lifetime: .keepAlways)
    }

    // MARK: Check verdict sticks (device bug #5)

    /// The check verdict must STICK: parent status ticks rebuild the
    /// sheet's content while it is open, and a store owned by the content
    /// was reset mid-probe — the verdict intermittently reverted to
    /// 'Not checked this session'. One presentation owns one store, so
    /// re-rendering (here: opening and dismissing the nested edit sheet,
    /// which forces full content re-evaluation) must not lose the
    /// verdict.
    func testCheckVerdictSticksAcrossRerenders() {
        app = UITestApp.launchDemo(.hostList)

        // The Build Server's route: a real dial to a demo-unreachable
        // address — the check must produce a verdict, and the verdict
        // must survive re-renders of the open inspector.
        let chevron = app.buttons["route-chevron-build.demo.invalid"]
        waitToExist(chevron)
        chevron.tap()
        let inspector = app.navigationBars["Build Server · build.demo.invalid"]
        XCTAssertTrue(inspector.waitForExistence(timeout: UITestTimeouts.standard))

        // Check: the row goes 'Checking…' then a verdict lands.
        let check = app.buttons["Check this route"]
        waitToExist(check)
        check.tap()
        let sshRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'route-ssh-connection'")).firstMatch
        waitToExist(sshRow)
        let verdictLanded = NSPredicate(format: "label CONTAINS 'Reachable' OR label CONTAINS 'Unreachable'")
        expectation(for: verdictLanded, evaluatedWith: sshRow)
        waitForExpectations(timeout: UITestTimeouts.launch)
        let verdictLabel = sshRow.label

        // Force content re-evaluation while the sheet stays open: the
        // nested route-editor sheet opens and cancels (a full presentation
        // pass over the inspector's own identity).
        let edit = app.buttons["route-inspector-edit"]
        waitToExist(edit)
        edit.tap()
        let editor = app.navigationBars["Edit route on Build Server"]
        XCTAssertTrue(editor.waitForExistence(timeout: UITestTimeouts.standard))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(
            inspector.waitForExistence(timeout: UITestTimeouts.standard),
            "inspector closed after the nested editor cancelled")

        // THE assertion: the verdict is still the verdict — not reset to
        // 'Not checked this session'. (Case-sensitive: 'Unreachable' does
        // not contain capital-'Reachable', so assert the actual stuck
        // verdict text.)
        XCTAssertEqual(
            sshRow.label, verdictLabel,
            "check verdict lost across re-renders")
        captureScreenshot(app, "route-check-verdict-stuck", lifetime: .keepAlways)
    }

    // MARK: Unified route state (single source of truth)

    /// The list and the detail read the SAME active-route source: tap a
    /// route on the LIST, and the open DETAIL page (pushed from that
    /// list) shows exactly that route as active — the marks can never
    /// disagree. Runs against the real demo Console (live statuses,
    /// shared active-route store, route tap = persist + reconnect).
    func testListAndDetailAgreeOnTheActiveRoute() {
        app = UITestApp.launchDemo(.hostListConsole)

        // The Field Laptop card (never connects in the demo): its two
        // routes are listed. Tap the VPN tunnel route.
        let vpnRow = app.buttons["host-route-field.vpn.demo.invalid"]
        waitToExist(vpnRow)
        vpnRow.tap()

        // Open the detail: the VPN route must read as the ACTIVE route
        // there — same source, same answer.
        let heading = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Open details for Field Laptop'")
        ).firstMatch
        waitToExist(heading)
        heading.tap()
        let detailVpnRow = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'host-detail-route-field.vpn.demo.invalid'"))
            .firstMatch
        waitToExist(detailVpnRow)
        XCTAssertTrue(
            detailVpnRow.label.contains("active route"),
            "the detail must show the route the LIST tapped as active: "
                + detailVpnRow.label)
        captureScreenshot(app, "list-detail-active-agree", lifetime: .keepAlways)

        // Review round 2: a route tap on the DETAIL — opened from this
        // list, the root-style entry point — must run the SAME
        // persist + redial action the list's rows run, never a
        // preference-only no-op. Tap the Home LAN row on the detail;
        // the Console redials through it (~2.5 s fixture window).
        let detailLanRow = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'host-detail-route-field.lan.demo.invalid'"))
            .firstMatch
        waitToExist(detailLanRow)
        detailLanRow.tap()

        // Back on the list: the DETAIL's tap launched the dial — the
        // Home LAN row (now active) shows the connecting spinner, the
        // same in-flight signal a list-card tap produces.
        let back = app.navigationBars.buttons.firstMatch
        waitToExist(back)
        back.tap()
        let lanSpinner = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'host-route-connecting-field.lan.demo.invalid'"))
            .firstMatch
        XCTAssertTrue(
            lanSpinner.waitForExistence(timeout: UITestTimeouts.standard),
            "the DETAIL's route tap must drive the Console redial — the "
                + "tapped row's connecting spinner never appeared on the list")
        captureScreenshot(app, "detail-tap-redial-connecting", lifetime: .keepAlways)

        // The dial fails honestly (no demo profile): the spinner yields
        // to the failed dot — the detail tap's connect lifecycle is
        // identical to a list tap's.
        let spinnerGone = NSPredicate(format: "exists == 0")
        expectation(for: spinnerGone, evaluatedWith: lanSpinner)
        waitForExpectations(timeout: UITestTimeouts.standard)
        let fieldHeading = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Open details for Field Laptop'")
        ).firstMatch
        waitToExist(fieldHeading)
        let unavailable = NSPredicate(format: "label CONTAINS 'Unavailable'")
        expectation(for: unavailable, evaluatedWith: fieldHeading)
        waitForExpectations(timeout: UITestTimeouts.standard)
        captureScreenshot(app, "detail-tap-redial-failed", lifetime: .keepAlways)
    }

    /// The route-switch connect lifecycle, driven through the real
    /// Console: tapping a route that cannot answer shows the connecting
    /// animation first (the active row's spinner), then the honest
    /// FAILED dot — the status tracks the switch, never the stale prior
    /// state. The Field Laptop has no demo profile, so its dial fails.
    func testRouteSwitchFailureShowsConnectingThenFailedDot() {
        app = UITestApp.launchDemo(.hostListConsole)

        // The Field Laptop starts failed (never connected, unreachable).
        // Tap its VPN tunnel route: the switch persists AND reconnects.
        let vpnRow = app.buttons["host-route-field.vpn.demo.invalid"]
        waitToExist(vpnRow)

        // The tap drives the Console lifecycle: the active row shows the
        // connecting spinner while the dial runs (the fixture bounds the
        // dial window at ~2.5 s), then the dial fails and the status dot
        // honestly reads Unavailable (failed) — never the stale prior
        // state.
        vpnRow.tap()

        // CONNECTING: the tapped (now active) row replaces its dot with
        // the connecting spinner while the dial runs — the route-switch
        // connect is visibly in flight (the fixture bounds the dial
        // window at ~2.5 s).
        let connectingSpinner = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == 'host-route-connecting-field.vpn.demo.invalid'"))
            .firstMatch
        XCTAssertTrue(
            connectingSpinner.waitForExistence(timeout: 3),
            "a route-switch tap must show the connecting spinner on the tapped row")
        captureScreenshot(app, "route-switch-connecting", lifetime: .keepAlways)


        // FAILED: the dial could not answer; the card's dot settles on
        // the honest failure (Unavailable), and the active mark stays on
        // the tapped route — the switch is recorded, the next connect
        // (Reconnect) tries the VPN route first.
        let heading = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Open details for Field Laptop'")
        ).firstMatch
        waitToExist(heading)
        let notConnecting = NSPredicate(format: "label CONTAINS 'Unavailable'")
        expectation(for: notConnecting, evaluatedWith: heading)
        waitForExpectations(timeout: UITestTimeouts.standard)
        XCTAssertFalse(
            heading.label.contains("Currently in use"),
            "a failed route switch must never read as connected: \(heading.label)")
        captureScreenshot(app, "route-switch-failed", lifetime: .keepAlways)
    }
}
