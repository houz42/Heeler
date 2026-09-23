import XCTest

/// Remote-pairing paste-path proofs: a user who cannot see the Host's
/// screen must be able to pair from a code sent to them, without the
/// camera ever being a prerequisite. Three user-visible behaviors:
///
/// 1. The paste entry ("Paste Pairing Code") is mounted and reachable
///    on the camera-AUTHORIZED scanning layout — the default state a
///    real phone lands in after granting camera permission — not only
///    in the camera-denied/unsupported fallbacks.
/// 2. Opening it gives a working paste surface: the type/paste field
///    accepts a real-format `HERDR-PAIR:1:…` code (the shared test
///    vector, exactly what the herdr plugin emits), and pairing
///    proceeds into the ceremony.
/// 3. Honest feedback for a non-code: typing junk shows the parse
///    error instead of silently doing nothing.
///
/// The demo surface mounts the REAL production PairingScanView with a
/// scripted connector (no SSH): the paste → decode → ceremony → Host
/// persisted pipeline is the production code path end to end.
@MainActor
final class PairingPasteProofTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        app?.terminate()
    }

    /// A real-format v1 code (same shape as the shared bootstrap vector:
    /// same addresses/port/user/fingerprint/seed) with a far-future
    /// expiry so the ceremony's locally-detected TTL check passes on
    /// any test-run date. The vector's fixed 1753305600 expiry is in the
    /// past, which would exercise the honest expired path instead of
    /// the success path this test proves.
    private static let realFormatCode =
        "HERDR-PAIR:1:eyJhZGRycyI6WyIxMC4wLjAuNyJdLCJwb3J0IjoyMiwidXNlciI6ImxpbiIsImZwIjoiU0hBMjU2OjYram5jTmRpYnNHMmNxdmZvTEFwR3JPOEN2SXdBRU16c0IrSWlsT3M4dGciLCJzZWVkIjoiQUFFQ0F3UUZCZ2NJQ1FvTERBME9EeEFSRWhNVUZSWVhHQmthR3h3ZEhoOCIsImV4cCI6NDEwMjQ0NDgwMH0"

    func testPasteEntryIsReachableOnTheCameraAuthorizedLayout() {
        app = UITestApp.launchDemo(.pairingPaste)

        // The scanner mounted in the camera-authorized state (forced by
        // the launch argument; the same layout a real phone shows
        // after granting camera access).
        let pasteEntry = app.buttons["Paste Pairing Code"].firstMatch
        XCTAssertTrue(
            pasteEntry.waitForExistence(timeout: UITestTimeouts.launch),
            "the paste entry must be mounted on the camera-authorized scanning layout")
        XCTAssertTrue(
            pasteEntry.isHittable,
            "the paste entry must be hittable, not buried under the scanner")

        captureScreenshot(app, "pairing-paste-entry-reachable", lifetime: .keepAlways)
    }

    func testPastedRealFormatCodeRunsTheCeremony() {
        app = UITestApp.launchDemo(.pairingPaste)

        // Open the paste surface from the always-mounted entry.
        let pasteEntry = app.buttons["Paste Pairing Code"].firstMatch
        XCTAssertTrue(
            pasteEntry.waitForExistence(timeout: UITestTimeouts.launch))
        pasteEntry.tap()
        let pasteSheet = app.navigationBars["Paste Pairing Code"]
        XCTAssertTrue(
            pasteSheet.waitForExistence(timeout: UITestTimeouts.standard),
            "the paste sheet never opened from the entry button")

        // Type the real-format code into the field (the remote user's
        // channel is the clipboard; the field exercises the same
        // submit path). "Pair with This Code" is disabled until the
        // field carries content.
        let pairButton = app.buttons["Pair with This Code"].firstMatch
        XCTAssertTrue(pairButton.waitForExistence(timeout: UITestTimeouts.standard))
        XCTAssertFalse(pairButton.isEnabled, "pair must be disabled on an empty field")

        let field = app.textFields["HERDR-PAIR:1:…"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: UITestTimeouts.standard))
        field.typeText(Self.realFormatCode)
        XCTAssertTrue(
            pairButton.isEnabled,
            "pair must enable once the field carries a code")
        captureScreenshot(app, "pairing-paste-code-entered", lifetime: .keepAlways)
        pairButton.tap()

        // The code parsed: the sheet closes and the REAL ceremony runs
        // behind it (the production store, scripted connector). The
        // ceremony view shows the Host section — the persisted host's
        // coordinates from the vector.
        XCTAssertTrue(
            app.waitForKeyboardDismissal(timeout: UITestTimeouts.keyboard),
            "keyboard stayed up after pairing started")
        let hostSection = app.staticTexts["lin@10.0.0.7"].firstMatch
        var paired = false
        for _ in 0..<40 where !paired {
            paired = hostSection.exists
            if !paired { Thread.sleep(forTimeInterval: 0.25) }
        }
        XCTAssertTrue(
            paired || app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'lin'")).firstMatch.exists,
            "the ceremony never showed the parsed Host (lin@10.0.0.7)")
        captureScreenshot(app, "pairing-paste-ceremony", lifetime: .keepAlways)
    }

    func testMalformedCodeShowsHonestParseFeedback() {
        app = UITestApp.launchDemo(.pairingPaste)

        let pasteEntry = app.buttons["Paste Pairing Code"].firstMatch
        XCTAssertTrue(
            pasteEntry.waitForExistence(timeout: UITestTimeouts.launch))
        pasteEntry.tap()

        let field = app.textFields["HERDR-PAIR:1:…"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: UITestTimeouts.standard))
        field.typeText("definitely not a pairing code")
        app.buttons["Pair with This Code"].firstMatch.tap()

        // Honest parse feedback from the same submit path a scan uses —
        // the sheet STAYS open so the user can correct the code.
        let feedback = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'not a herdr Pairing Code'")).firstMatch
        XCTAssertTrue(
            feedback.waitForExistence(timeout: UITestTimeouts.standard),
            "a malformed pasted code must show the honest parse error")
        captureScreenshot(app, "pairing-paste-malformed-feedback", lifetime: .keepAlways)
    }
}
