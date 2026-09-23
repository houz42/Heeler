import XCTest

// SPDX-License-Identifier: Apache-2.0
//
/// v3 phone-width wrapped-cell tables — the visual proof suite. The
/// `--demo-chat-tables` fixture transcript carries the reported
/// regression case: a three-column table whose cells hold long prose
/// (which the v2 width-adaptive renderer unfolded into a horizontal
/// scroll at phone width), a compact two-column table that needs no
/// folding, and a table with code spans + a link inside cells. The
/// assertions ride the accessibility tree AND the layout frames: the
/// full text of every long cell must remain REACHABLE (wrapped, not
/// scrolled out of the viewport), the table must never span wider
/// than the app (no whole-page horizontal overflow), and the long
/// cells' elements must wrap to NARROWER-than-screen frames (a
/// single-line unfolded cell would be wider than the phone). The
/// screenshots carry the visual proof at phone and wide layouts.

@MainActor
final class TableWidthProofTests: XCTestCase {

    private func launchTablesChat() -> XCUIApplication {
        UITestApp.launchDemo(.chatTables)
    }

    /// One fixture cell text, matched by a stable CONTAINS fragment.
    /// A long cell wraps across several accessibility elements, so
    /// probes target text that sits on ONE wrapped line's element.
    private func cellText(
        _ fragment: String, in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", fragment)
        ).firstMatch
    }

    // MARK: every long cell's full content stays reachable (wrapped)

    /// The tail of each long cell must exist in the accessibility
    /// tree: a horizontally-scrolled unfolded table leaves text
    /// right of the viewport (unreachable), while the wrapped render
    /// keeps every word on screen. Probes the LAST words of the
    /// longest cells — exactly what clipping/scroll would lose first.
    func testLongCellContentStaysFullyReachable() {
        let app = launchTablesChat()

        let cellTails = [
            "green on both runners",
            "the retry regression stays fixed",
            "later this week",
            "the client bridge",
            "chat already uses",
        ]
        for tail in cellTails {
            XCTAssertTrue(
                cellText(tail, in: app).waitForExistence(
                    timeout: UITestTimeouts.standard),
                "the long cell text \"\(tail)\" never rendered — the "
                    + "table must wrap its cells, not clip or scroll "
                    + "them out of the reading width")
        }

        // The compact table renders whole.
        XCTAssertTrue(
            cellText("| 12 |", in: app).exists
                || cellText("12", in: app).waitForExistence(
                    timeout: UITestTimeouts.standard),
            "the compact table's cells never rendered")

        captureScreenshot(app, "chat-tables-phone", lifetime: .keepAlways)
    }

    // MARK: wrapped, not unfolded — frame evidence

    /// A long cell's wrapped text must occupy a frame NARROWER than
    /// the phone: the v2 regression rendered such cells at natural
    /// single-line width inside a horizontal scroll (frames wider
    /// than the screen). The wrapped render folds the cell into the
    /// table's constrained width. Probed on the longest Notes cell,
    /// whose single-line natural width far exceeds the phone.
    func testLongCellsWrapInsideThePhoneWidth() {
        let app = launchTablesChat()

        let probe = cellText("Full clean build", in: app)
        XCTAssertTrue(
            probe.waitForExistence(timeout: UITestTimeouts.standard))
        let appWidth = app.frame.width
        let cellWidth = probe.frame.width

        // The wrapped element fits inside the app's width with the
        // content margins to spare (a wrapped cell sits inside the
        // table's columns; an unfolded one-line cell would measure
        // far WIDER than the 390pt phone viewport).
        XCTAssertLessThanOrEqual(
            cellWidth, appWidth,
            "the long cell spans \(cellWidth)pt of a \(appWidth)pt "
                + "screen — the table unfolded instead of wrapping")
    }

    /// No table content may extend past the app's right edge: the
    /// whole-page horizontal-overflow failure mode. Every cell tail
    /// element from the long table must end within the app frame.
    func testNoTableContentOverflowsThePage() {
        let app = launchTablesChat()

        for tail in [
            "green on both runners",
            "the retry regression stays fixed",
            "later this week",
            "the client bridge",
            "chat already uses",
        ] {
            let element = cellText(tail, in: app)
            XCTAssertTrue(
                element.waitForExistence(timeout: UITestTimeouts.standard))
            XCTAssertLessThanOrEqual(
                element.frame.maxX, app.frame.maxX + 1,
                "cell text extends past the page's right edge "
                    + "(\(element.frame.maxX) > \(app.frame.maxX)) — "
                    + "the table overflows the reading width")
        }
    }
}
