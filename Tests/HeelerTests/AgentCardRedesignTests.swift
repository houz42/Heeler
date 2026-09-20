import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent card redesign")
struct AgentCardRedesignTests {
    private func makeAgent(
        kind: String = "omp",
        name: String? = "reviewer",
        title: String = "Fix the flaky test",
        host: String = "devbox",
        session: String = "",
        workspace: String? = "heeler",
        tab: String? = nil,
        paneID: String = "p1",
        tabCount: Int = 1,
        status: AgentStatus = .working,
        tabPosition: Int? = 1
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: host,
            agent: Agent(
                terminalID: "term_\(paneID)", kind: kind, title: title, status: status,
                workspaceID: "w", tabID: "w:t1", paneID: paneID,
                cwd: "/work", revision: 1, name: name),
            workspaceLabel: workspace, repositoryCheckout: nil,
            hostSessionName: session,
            tabLabel: tab, tabPosition: tabPosition, workspaceTabCount: tabCount)
    }

    @Test func locationLineConcatenatesAllFourValuesWithoutLabels() {
        let agent = makeAgent(
            host: "devbox", session: "main", workspace: "heeler", tab: "tests",
            tabCount: 2, tabPosition: 1)
        #expect(AgentCardLocation.line(for: agent) == "devbox · main · heeler · tests")
    }

    @Test func missingValuesDropOutInsteadOfRenderingEmptyGaps() {
        let agent = makeAgent(host: "devbox", session: "", workspace: "heeler", tab: nil)
        #expect(AgentCardLocation.line(for: agent) == "devbox · heeler")
    }

    @Test func automaticTabPositionNeverRendersOnPhone() {
        // One tab, herdr's label is the position: plumbing, not identity.
        let agent = makeAgent(tab: "1", tabCount: 1, tabPosition: 1)
        #expect(!AgentCardLocation.line(for: agent).contains(" · 1"))
        // A manual label on a multi-tab workspace stays.
        let manual = makeAgent(tab: "refactor", tabCount: 2, tabPosition: 1)
        #expect(AgentCardLocation.line(for: manual).hasSuffix("refactor"))
    }

    @Test func kindBadgeRidesEveryRowFromRuntimeMetadata() {
        let badge = AgentKindBadgeModel(agent: makeAgent(kind: "claude"))
        #expect(badge.accessibilityLabel == "Claude Code")
        #expect(badge.isRecognized)
        let fallback = AgentKindBadgeModel(agent: makeAgent(kind: "brand-new-agent"))
        #expect(fallback.systemImage == AgentKindBadgeModel.fallbackSystemImage)
        #expect(!fallback.isRecognized)
    }

    @Test func sessionAndTabStayOnTheQuietLineNotTheTitle() {
        let agent = makeAgent(session: "ci", tab: "build", tabCount: 2)
        let headline = AgentCardPresentation(agent: agent).headline
        #expect(!headline.contains("ci"))
        #expect(AgentCardLocation.line(for: agent).contains("ci"))
        #expect(AgentCardLocation.line(for: agent).contains("build"))
    }
}
