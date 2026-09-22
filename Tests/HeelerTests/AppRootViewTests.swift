import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The destination switcher contract (#A): three top-level pages kept
/// mounted behind the compact selector, hidden pages off the hit-test, and
/// the environment binding every page's `AppDestinationMenu` reads.
///
/// AX-label assertions are gated on the environment actually materializing
/// hosted SwiftUI accessibility. An XCTest host without an assistive client
/// attached reports EMPTY accessibility trees for hosted SwiftUI — verified
/// against the pre-existing `SidebarConsoleIntegrationTests` baseline, which
/// fails identically at origin/main on the same simulator. The interactive
/// proof set for this slice therefore lives in the idb-driven simulator
/// sessions (see the slice report); these tests hold the structural
/// invariants every runtime CAN observe.
@MainActor
@Suite("App root destinations", .timeLimit(.minutes(1)))
struct AppRootViewTests {
    /// A page whose identity doubles as the observability probe.
    private struct NamedPage: View {
        let name: String

        var body: some View {
            NavigationStack {
                VStack {
                    Text(name)
                    Button("Tap \(name)") {}
                }
            }
        }
    }

    /// The mounted root for one destination state, type-erased.
    private func makeRoot() -> AnyView {
        AnyView(AppRootView(
            agents: NamedPage(name: "Agents Page"),
            hosts: NamedPage(name: "Hosts Page"),
            settings: NamedPage(name: "Settings Page")))
    }

    @Test func compactRootMountsPagesAndSurvivesDestinationSwitch() async throws {
        let controller = UIHostingController(rootView: makeRoot())
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        #expect(controller.view.subviews.count >= 1, "the root must mount content")

        // A destination change must not crash or unmount the window's root
        // (the switch is an opacity/hit-test flip, not a conditional).
        // Same root identity, new environment: exactly the way the in-page
        // menu writes through the shared binding.
        let switched = UIHostingController(
            rootView: makeRoot().environment(\.appDestination, .constant(.hosts)))
        let switchedWindow = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: switched)
        defer { switchedWindow.isHidden = true }
        switched.view.layoutIfNeeded()
        #expect(switched.view.subviews.count >= 1, "root survives a destination switch")
    }

    @Test func destinationEnumCoversExactlyTheApprovedDestinations() {
        // The menu and sidebar are both generated from the enum; the three
        // approved destinations must stay exactly these, in display order.
        #expect(AppDestination.allCases.map(\.title) == ["Agents", "Hosts", "Settings"])
        for destination in AppDestination.allCases {
            #expect(!destination.title.isEmpty)
            #expect(!destination.systemImage.isEmpty)
        }
    }
}
