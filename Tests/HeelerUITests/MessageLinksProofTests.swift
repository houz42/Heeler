import XCTest

// SPDX-License-Identifier: Apache-2.0

/// v3 message-links proofs (design doc: "V3 link UX"). External links
/// in the transcript are tappable and follow the normal browse policy;
/// a localhost/loopback link NEVER opens the browser — it presents the
/// honest "Local address unavailable" sheet naming the ORIGINATING
/// agent host (not the phone), with the selectable URL, host identity,
/// Copy address / Close, and the reachable-URL suggestion. No Forward,
/// no gateway, no Retry, no "Open on phone" anywhere.
///
/// The demo route mounts the real ChatScreen with one external link
/// ("https://build.studio.example/runs/9412") and one localhost link
/// ("http://localhost:4173/preview"), so a real tap drives the real
/// LinkifiedChatRow → OpenRouterCore path. MarkdownUI renders links as
/// SwiftUI `Text` link runs, which the accessibility tree exposes as
/// Link elements identified by the URL — that's the locator. Assertions
/// ride the accessibility tree; the captures carry the visual proof.
@MainActor
final class MessageLinksProofTests: XCTestCase {

    func testLocalhostLinkPresentsHonestSheetNotBrowser() {
        let app = UITestApp.launchDemo(.chatMessageLinks)

        // Tap the localhost link in the transcript (a real tap through
        // the real linkified text).
        let localhostLink = app.links["http://localhost:4173/preview"].firstMatch
        XCTAssertTrue(
            localhostLink.waitForExistence(timeout: UITestTimeouts.standard),
            "the localhost link must be tappable in the transcript")
        localhostLink.tap()

        // The honest sheet — never a browser surface.
        let sheet = app.staticTexts["Local address unavailable"].firstMatch
        XCTAssertTrue(
            sheet.waitForExistence(timeout: UITestTimeouts.standard),
            "tapping a localhost link must present the honest sheet")
        captureScreenshot(
            app, "message-links-localhost-sheet", lifetime: .keepAlways)

        // Host identity: the demo surface wired "Studio Mac" — the
        // ORIGINATING host, never the phone.
        XCTAssertTrue(
            app.staticTexts["Studio Mac"].firstMatch.exists,
            "the sheet must name the originating agent host")

        // The selectable URL, verbatim.
        XCTAssertTrue(
            app.staticTexts["http://localhost:4173/preview"].firstMatch.exists,
            "the sheet must show the full URL selectable")

        // Exactly the two affordances the design names: Copy address
        // and Close — nothing else (no Forward/gateway/Retry/Open).
        XCTAssertTrue(app.buttons["Copy address"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Close"].firstMatch.exists)
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "forward")
            ).firstMatch.exists)
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "retry")
            ).firstMatch.exists)
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "gateway")
            ).firstMatch.exists)

        // Close dismisses; the transcript stays where it was (the
        // link is still there — reading position preserved).
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(
            app.links["http://localhost:4173/preview"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "Close must dismiss back to the transcript, position intact")
        XCTAssertFalse(
            app.staticTexts["Local address unavailable"].firstMatch.exists)

        // Review finding 2: dismissal clears the router state, so the
        // IDENTICAL URL re-triggers the sheet (no stale notice).
        app.links["http://localhost:4173/preview"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Local address unavailable"].firstMatch
                .waitForExistence(timeout: UITestTimeouts.standard),
            "the same localhost link must re-open the sheet after dismissal")
        app.buttons["Close"].firstMatch.tap()
    }

    func testExternalLinkFollowsBrowsePolicyNotLocalSheet() {
        let app = UITestApp.launchDemo(.chatMessageLinks)

        // The external link is tappable in the transcript.
        let externalLink =
            app.links["https://build.studio.example/runs/9412"].firstMatch
        XCTAssertTrue(
            externalLink.waitForExistence(timeout: UITestTimeouts.standard),
            "the external link must be tappable in the transcript")
        captureScreenshot(
            app, "message-links-transcript", lifetime: .keepAlways)
        externalLink.tap()

        // A first-seen domain asks embedded-vs-default (the ask sheet),
        // NEVER the local-address sheet.
        let ask = app.staticTexts["How should links to this site open?"]
            .firstMatch
        XCTAssertTrue(
            ask.waitForExistence(timeout: UITestTimeouts.standard),
            "an external first-seen domain must present the browse-ask sheet")
        XCTAssertFalse(
            app.staticTexts["Local address unavailable"].firstMatch.exists,
            "an external link must never trigger the localhost sheet")

        // "Default Browser" hands off through the pane's openURL: the
        // sheet goes away and the transcript returns (on the simulator
        // Safari opens outside the app's accessibility tree).
        app.buttons["Default Browser"].firstMatch.tap()
        XCTAssertTrue(
            ask.waitForNonExistence(timeout: UITestTimeouts.standard),
            "the ask sheet must dismiss after the choice")
    }
}

/// One-off helper: waits until the element stops existing.
extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !exists { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !exists
    }
}
