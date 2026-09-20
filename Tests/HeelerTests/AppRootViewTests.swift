import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The destination switcher contract (#A): three top-level pages kept
/// mounted behind the compact selector, hidden pages off the hit-test, and
/// the environment binding that every page's `AppDestinationMenu` reads.
/// Drives the mounted `AppRootView` the way the app mounts it, via
/// `\.appDestination` — the same wiring ContentView uses.
@MainActor
@Suite("App root destinations", .timeLimit(.minutes(1)))
struct AppRootViewTests {
    /// A page whose @State must survive destination switches: taps are the
    /// observable state, the identifier the interaction handle.
    private struct CountingPage: View {
        let name: String
        @State private var taps = 0

        var body: some View {
            NavigationStack {
                VStack {
                    Text(name)
                        .accessibilityIdentifier("\(name)-label")
                    Button("Tap \(taps)") { taps += 1 }
                        .accessibilityIdentifier("\(name)-tap")
                }
            }
        }
    }

    private func labels(in root: UIView) -> [String] {
        var visited = Set<ObjectIdentifier>()
        var labels: [String] = []
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if let label = node.accessibilityLabel { labels.append(label) }
            for element in node.accessibilityElements ?? [] {
                if let object = element as? NSObject { visit(object) }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject {
                        visit(object)
                    }
                }
            }
            if let view = node as? UIView { view.subviews.forEach { visit($0) } }
        }
        visit(root)
        return labels
    }

    @Test func compactRootShowsSelectedPageAndSelectorAndNoOtherPage() async throws {
        let root = AppRootView(
            agents: CountingPage(name: "Agents Page"),
            hosts: CountingPage(name: "Hosts Page"),
            settings: CountingPage(name: "Settings Page"))
        let controller = UIHostingController(rootView: root)
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        // iOS 26 does not materialize hosted SwiftUI accessibility without
        // an assistive client; the mounted-page assertions run on iOS 27+.
        guard #available(iOS 27, *) else { return }
        let mountDeadline = ContinuousClock.now + .seconds(2)
        var allLabels: [String] = []
        while ContinuousClock.now < mountDeadline {
            try await Task.sleep(for: .milliseconds(10))
            controller.view.layoutIfNeeded()
            allLabels = labels(in: controller.view)
            if allLabels.contains(where: { $0.contains("Agents Page") }) { break }
        }
        #expect(allLabels.contains { $0.contains("Agents Page") },
            "the selected destination's page must be mounted")
        #expect(!allLabels.contains { $0.contains("Hosts Page") },
            "hidden pages must not expose accessibility")
        #expect(!allLabels.contains { $0.contains("Settings Page") },
            "hidden pages must not expose accessibility")
    }

    @Test func switchViaEnvironmentMovesTheSelectedPage() async throws {
        let controller = UIHostingController(
            rootView: AppRootView(
                agents: CountingPage(name: "Agents Page"),
                hosts: CountingPage(name: "Hosts Page"),
                settings: CountingPage(name: "Settings Page"))
                .environment(\.appDestination, .constant(.hosts)))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        guard #available(iOS 27, *) else { return }
        let switchDeadline = ContinuousClock.now + .seconds(2)
        var allLabels: [String] = []
        while ContinuousClock.now < switchDeadline {
            try await Task.sleep(for: .milliseconds(10))
            controller.view.layoutIfNeeded()
            allLabels = labels(in: controller.view)
            if allLabels.contains(where: { $0.contains("Hosts Page") }) { break }
        }
        #expect(allLabels.contains { $0.contains("Hosts Page") },
            "a destination change must mount the new page")
        #expect(!allLabels.contains { $0.contains("Agents Page") },
            "the previous page must be hidden again")
    }
}
