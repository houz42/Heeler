import SwiftUI
import UIKit
import Testing

@testable import Heeler

/// The width-crossing reset proof (review round v2), hosted-window level:
/// an open NARROW drawer must not survive the crossing into the WIDE
/// layout — the reserved sidebar owns destinations there, and leftover
/// compact-modal layers (drawer + scrim) would cover it.
///
/// Why a hosted window and not XCUITest: a device rotation on the
/// simulator does not re-layout an iPhone app window into landscape
/// geometry (verified: the app renders sideways inside a portrait
/// frame and GeometryReader never sees wide width), so the crossing is
/// driven by resizing the hosted WINDOW — which IS the layout input
/// GeometryReader reads. AX trees are empty in this harness (see
/// AppRootViewTests' header), so the proof asserts BEHAVIOR the UIKit
/// layer still observes: the trigger's identity (the root publishes it
/// to pages through the environment — the wide identity exists only
/// when the sidebar layout is live) and hit-testing against a unique
/// UIKit marker inside the page (while the drawer layer is presented it
/// COVERS the page, so the marker is not hit-testable; after the reset
/// the marker is again — a leaked scrim would keep swallowing it).
@MainActor
@Suite("App root drawer width crossing", .timeLimit(.minutes(1)))
struct AppRootDrawerResizeTests {
    /// The trigger identity the probe page last saw.
    private final class TriggerBox: ObservableObject {
        @Published var identity: String = ""
        var action: (() -> Void)?
    }

    /// A unique UIKit hit-test marker inside the page.
    private final class MarkerView: UIView {}

    private struct MarkerProbe: UIViewRepresentable {
        func makeUIView(context: Context) -> MarkerView {
            MarkerView()
        }

        func updateUIView(_ uiView: MarkerView, context: Context) {}
    }

    /// The probe page: captures the published trigger identity and
    /// mounts the hit-test marker.
    private struct ProbePage: View {
        let box: TriggerBox
        var body: some View {
            NavigationStack {
                VStack {
                    Text("Page")
                    Button("Tap Page") {}
                    MarkerProbe()
                }
            }
            .onAppear { capture() }
            .onChange(of: identity) { capture() }
        }

        @Environment(\.appNavigationTrigger) private var trigger
        private var identity: String {
            guard let trigger else { return "" }
            return trigger.accessibilityLabel + "|" +
                trigger.accessibilityValue
        }

        private func capture() {
            guard let trigger else { return }
            box.identity = identity
            box.action = trigger.action
        }
    }

    /// The hit-testable marker currently in the window's pages, if any
    /// page hosts it (the first marker found in the tree).
    private func marker(in window: UIWindow) -> MarkerView? {
        window.subviews.recursiveSubsequences()
            .compactMap { $0 as? MarkerView }
            .first
    }

    @Test func openNarrowDrawerCrossingWideResetsCompactPresentation()
        async throws
    {
        let box = TriggerBox()
        let root = AppRootView(
            agents: ProbePage(box: box),
            hosts: ProbePage(box: box),
            settings: ProbePage(box: box))
        let controller = UIHostingController(rootView: root)

        // NARROW: the phone drawer layout.
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()

        // Let the onAppear capture land, then require the NARROW
        // identity before driving the drawer.
        let narrowDeadline = Date().addingTimeInterval(3)
        while box.identity != "Open navigation|Closed",
            Date() < narrowDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            box.identity == "Open navigation|Closed",
            "narrow must publish the closed drawer-trigger identity")

        // Open the drawer through the published action — the same path
        // the hamburger trigger runs. The identity flips to Open.
        box.action?()
        let openDeadline = Date().addingTimeInterval(3)
        while box.identity != "Open navigation|Open",
            Date() < openDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            box.identity == "Open navigation|Open",
            "the published identity must flip to Open with the drawer")

        // The drawer layer COVERS the page: the marker is not
        // hit-testable while the compact presentation is up.
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        guard let marker = marker(in: window) else {
            Issue.record("the probe marker must mount in the page")
            return
        }
        let markerPoint = CGPoint(
            x: marker.frame.midX, y: marker.frame.midY)
        let coveredHit = window.hitTest(markerPoint, with: nil)
        #expect(
            coveredHit !== marker,
            "with the drawer presented, the layer covers the page — the marker must not be hit-testable")

        // CROSS into wide: resize the window. The compact presentation
        // must RESET and the WIDE identity must land (that identity
        // exists only when the reserved-sidebar layout is live).
        window.frame = CGRect(x: 0, y: 0, width: 1000, height: 874)
        controller.view.layoutIfNeeded()
        let wideDeadline = Date().addingTimeInterval(3)
        while !box.identity.hasPrefix("Collapse navigation sidebar"),
            Date() < wideDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            box.identity.hasPrefix("Collapse navigation sidebar"),
            "wide must publish the sidebar-fold identity — the compact drawer identity must not survive the crossing")

        // NO compact residue: the marker is hit-testable again (a
        // leaked scrim would keep swallowing page touches).
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        let resetHit = window.hitTest(markerPoint, with: nil)
        #expect(
            resetHit === marker,
            "after the crossing, the page marker must be hit-testable again — no drawer/scrim residue")
    }
}

/// Flattens a view tree for marker lookup.
private extension Sequence where Element: UIView {
    func recursiveSubsequences() -> [UIView] {
        flatMap { [$0] + $0.subviews.recursiveSubsequences() }
    }
}
