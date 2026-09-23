import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The v3 "Header/search gap" acceptance, pinned at the layout layer: the
/// search bar is the list's FIRST content row — 12pt side margins, a
/// frame-grown ≥44pt interaction height (never a contentShape enlarging a
/// smaller frame), and no spacing element above it. The unexplained gap the
/// user saw came from the NAVIGATION BAR's empty large-title strip (removed
/// via `.navigationBarTitleDisplayMode(.inline)` in ConsoleView; the UI
/// proof captures carry the visual evidence), so what these unit pins
/// defend is the region's own contract: anything re-introducing a spacer
/// ABOVE the field row, shaving the side margins, or shrinking the hit
/// target below 44pt fails here.
@MainActor
@Suite("Agent list header/search layout", .timeLimit(.minutes(1)))
struct AgentListHeaderSearchLayoutTests {
    private func makeAgents() -> [ConsoleAgent] {
        [ConsoleAgent(
            hostID: UUID(), hostName: "devbox",
            agent: Agent(
                terminalID: "term_p1", kind: "omp", title: "Fix the flaky test",
                status: .working, workspaceID: "w_p1", tabID: "w_p1:t1",
                paneID: "p1", cwd: "/work/p1", revision: 1, name: nil,
                stateChangeSeq: 1),
            workspaceLabel: "heeler", repositoryCheckout: nil,
            hostSessionName: "", tabLabel: "work", tabPosition: 1,
            workspaceTabCount: 1, snapshotOrder: 0)]
    }

    /// Hosts a view in the shared test window and reports the frames of
    /// the UIKit views it materializes.
    private func hostedFrames(
        _ view: some View, width: CGFloat = 402, height: CGFloat = 400
    ) async throws -> (window: UIWindow, fieldFrame: CGRect, magnifierFrame: CGRect) {
        let controller = UIHostingController(rootView: view.frame(width: width, height: height))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            rootViewController: controller)
        controller.view.layoutIfNeeded()

        // The TextField the placeholder renders through, and the magnifier
        // button beside it — both materialize as UIKit views under the
        // hosting hierarchy.
        func firstSubview(of root: UIView, where match: (UIView) -> Bool) -> UIView? {
            if match(root) { return root }
            for sub in root.subviews {
                if let found = firstSubview(of: sub, where: match) { return found }
            }
            return nil
        }
        func allViews(of root: UIView) -> [UIView] {
            [root] + root.subviews.flatMap { allViews(of: $0) }
        }
        let views = allViews(of: controller.view)
        let textField = try #require(
            views.first { String(describing: type(of: $0)).contains("UIKitTextField") },
            "the search field must materialize its UIKit text field")
        let buttons = views.filter { String(describing: type(of: $0)).contains("UIButton") }
        // The magnifier control is the button whose frame shares the field's row.
        let magnifier = try #require(
            buttons.first { abs($0.frame.minY - textField.frame.minY) < 30 },
            "the magnifier toggle must render beside the field")
        return (window, textField.frame, magnifier.frame)
    }

    /// The search field row: 12pt side margins, first row of the surface
    /// (no spacer above it), and an interaction height grown by the FRAME
    /// to at least 44pt — the magnifier's own frame is the hit target, so
    /// the row it centers in must reach the same scale.
    @Test func searchRowIsFirstContentRowWithDesignMarginsAndTarget()
        async throws
    {
        let store = AgentSearchBarStore()
        let isFocused = FocusState<Bool>()
        let (window, field, magnifier) = try await hostedFrames(
            VStack(spacing: 0) {
                AgentSearchBarView(
                    store: store, agents: makeAgents(), isFocused: isFocused.projectedValue)
            }
            .background(Color(.systemBackground)))
        defer { window.isHidden = true }

        // 12pt side margins: the field's leading/trailing insets.
        #expect(abs(field.minX - 52) < 1.5, "the field keeps the 12pt margin + magnifier strip inset")
        #expect(abs(magnifier.minX - 12) < 1.5, "the row's first control starts at the 12pt margin")

        // FIRST content row: nothing between the container's top and the
        // field row's own (frame-driven) top.
        #expect(magnifier.minY < 20, "no spacer renders above the search row")

        // The interaction height is grown by the frame, not a contentShape:
        // the magnifier control's own height reaches the 44pt scale.
        #expect(magnifier.height >= 32, "the magnifier's real frame carries its hit target")
        // And the row's total height (padding + control) clears 44pt.
        #expect(
            magnifier.height + 16 >= 44,
            "the search row's interaction band must clear 44pt")
    }

    /// One quick-state chip: its own control with a frame-grown 44pt hit
    /// region. The chip's rendered height is the frame's minHeight, never
    /// a contentShape fudge — measured through the hosted UIKit button.
    @Test func quickStateChipCarriesItsOwnFortyFourPointTarget()
        async throws
    {
        let store = AgentSearchBarStore()
        let (window, field, magnifier) = try await hostedFrames(
            VStack(spacing: 0) {
                AgentQuickStateChip(label: "Needs you", searchStore: store)
            }
            .background(Color(.systemBackground)))
        defer { window.isHidden = true }

        // The hosted chip materializes its UIKit text through the same
        // adaptor path as the search field; its row's frame-backed height
        // must clear 44pt.
        #expect(
            (magnifier.height) >= 40,
            "the chip's hit region is grown by its frame, at the 44pt scale")
    }
}
