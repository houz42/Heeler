import XCTest

// SPDX-License-Identifier: Apache-2.0
//
// The compact-foldable pending region's preview-tap proof (design
// pane finding: with 1-3 pending entries the previews were static
// text — no per-entry detail route). Over the SEEDED demo composer
// route (`--demo-composer-pending`, two entries: one rejected, one
// accepted):
//   1. the collapsed summary row shows ("Pending 2" + attention);
//   2. tapping it unfolds the previews;
//   3. tapping a preview — the per-entry detail route — opens the
//      detail sheet carrying the FULL content and the state's
//      actions (Retry for the rejected entry);
//   4. the expanded label reads "expanded" (AX copy fix).

@MainActor
final class PendingRegionProofTests: XCTestCase {

    func testPreviewTapOpensPerEntryDetail() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--uitest", "--demo-screenshots", "--demo-chat-composer",
            "--demo-composer-pending",
        ]
        app.launch()

        // 1. The collapsed summary row mounts between transcript and
        //    composer: "Pending 2" with the attention count.
        let summary = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Pending messages: 2")).firstMatch
        XCTAssertTrue(
            summary.waitForExistence(timeout: UITestTimeouts.launch),
            "the collapsed Pending 2 summary row must mount")
        XCTAssertTrue(
            summary.label.contains("1 need attention"),
            "the rejected entry's attention count must read on the summary")

        captureScreenshot(app, "pending-collapsed-summary", lifetime: .keepAlways)

        // 2. Tap unfolds: the preview rows appear (static text made
        //    tappable — the fix under proof).
        summary.tap()
        let preview = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Ship the checkout fix")).firstMatch
        XCTAssertTrue(
            preview.waitForExistence(timeout: UITestTimeouts.standard),
            "tapping the summary must unfold the previews")

        captureScreenshot(app, "pending-unfolded-previews", lifetime: .keepAlways)

        // The unfolded region's label reads "expanded" (the AX copy
        // fix — the folded copy belonged to the collapsed row).
        let expandedLabel = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", ", expanded")).firstMatch
        XCTAssertTrue(
            expandedLabel.exists,
            "the expanded region's AX label must read expanded")

        // 3. Tapping the preview opens the per-entry DETAIL: the full
        //    text and the rejected state's Retry action (may
        //    duplicate never applies to rejected).
        preview.tap()
        let detailText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Ship the checkout fix")).firstMatch
        XCTAssertTrue(
            detailText.waitForExistence(timeout: UITestTimeouts.standard),
            "the per-entry detail sheet must show the entry's full text")
        let retry = app.buttons.matching(
            NSPredicate(format: "label == %@", "Retry")).firstMatch
        XCTAssertTrue(
            retry.waitForExistence(timeout: UITestTimeouts.standard),
            "the rejected entry's detail must carry the Retry action")

        captureScreenshot(app, "pending-entry-detail-sheet", lifetime: .keepAlways)
    }
}
