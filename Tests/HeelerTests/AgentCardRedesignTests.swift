import Foundation
import Testing

@testable import Heeler

/// The v2 grouped agent-row layout: the workspace group header carries
/// the full `host · session · workspace` context path; each agent row is
/// two lines — the TAB label on line 1, the agent TITLE as the secondary
/// subtitle on line 2.
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

    // MARK: Row line 1 — the tab label only

    @Test func lineOneIsTheTabLabelOnly() {
        let agent = makeAgent(
            name: "reviewer", title: "Checkout review",
            host: "devbox", session: "main", workspace: "heeler",
            tab: "tests", tabCount: 2, tabPosition: 1)
        #expect(AgentCardRow.tabLine(for: agent) == "tests",
                "line 1 must show the herdr tab label and nothing else")
        // The other context values must NOT crowd the tab line: the
        // workspace header above the group carries them.
        let line = AgentCardRow.tabLine(for: agent)
        #expect(!line.contains("devbox") && !line.contains("heeler"))
        #expect(!line.contains("Checkout review"))
    }

    @Test func tabIdentityRendersEvenWhenTheNameIsAutomatic() {
        // herdr's automatic positional tab name is real layout identity.
        let agent = makeAgent(tab: "1", tabCount: 1, tabPosition: 1)
        #expect(AgentCardLocation.tabLabel(for: agent) == "1")
        #expect(AgentCardRow.tabLine(for: agent) == "1")
        // A manual label on a multi-tab workspace stays.
        let manual = makeAgent(tab: "refactor", tabCount: 2, tabPosition: 1)
        #expect(AgentCardRow.tabLine(for: manual) == "refactor")
    }

    @Test func missingTabIdentityFallsBackToTheTitleNeverAnEmptyLine() {
        // No tab label at all: the first line falls back to the title so
        // the row never renders an empty line 1.
        let agent = makeAgent(title: "Harden webhook retries", tab: nil)
        #expect(AgentCardRow.tabLine(for: agent) == "Harden webhook retries")
    }

    // MARK: Row line 2 — the agent title as the subtitle

    @Test func lineTwoIsTheConversationTitle() {
        let agent = makeAgent(
            name: "reviewer", title: "Checkout review",
            tab: "tests", tabCount: 2, tabPosition: 1)
        #expect(AgentCardRowTitle.title(for: agent) == "Checkout review",
                "line 2 must be the actual conversation title")
        // The task title wins over the server-reported agent name.
        let unnamed = makeAgent(name: nil, title: "Fix the flaky test", tab: "tests")
        #expect(AgentCardRowTitle.title(for: unnamed) == "Fix the flaky test")
        #expect(!AgentCardRowTitle.title(for: unnamed).contains("heeler"))
    }

    // MARK: Group header — the full three-part context path

    @Test func workspaceHeaderCarriesHostSessionWorkspacePath() {
        let host = Host.fixture(name: "devbox")
        let agent = ConsoleAgent(
            hostID: host.id, hostName: "devbox",
            agent: Agent(
                terminalID: "t1", kind: "omp", title: "A", status: .idle,
                workspaceID: "w-1", tabID: "w-1:t", paneID: "p1", cwd: "/", revision: 1),
            workspaceLabel: "heeler", repositoryCheckout: nil,
            hostSessionName: "main", snapshotOrder: 0)
        let sections = AgentListLayout.grouped([agent], by: .workspace)
        #expect(sections.count == 1)
        #expect(sections[0].title == "heeler")
        #expect(sections[0].contextLine == "devbox · main · heeler")
    }

    @Test func defaultSessionRendersByItsHonestNameInTheHeaderPath() {
        // The default session is real identity, not noise.
        let host = Host.fixture(name: "devbox")
        let agent = ConsoleAgent(
            hostID: host.id, hostName: "devbox",
            agent: Agent(
                terminalID: "t1", kind: "omp", title: "A", status: .idle,
                workspaceID: "w-1", tabID: "w-1:t", paneID: "p1", cwd: "/", revision: 1),
            workspaceLabel: "heeler", repositoryCheckout: nil,
            hostSessionName: "", snapshotOrder: 0)
        let sections = AgentListLayout.grouped([agent], by: .workspace)
        #expect(sections[0].contextLine == "devbox · default · heeler")
        #expect(AgentCardLocation.sessionLabel(for: agent) == "default")
    }

    // MARK: Retained projections

    @Test func kindBadgeRidesEveryRowFromRuntimeMetadata() {
        let badge = AgentKindBadgeModel(agent: makeAgent(kind: "claude"))
        #expect(badge.accessibilityLabel == "Claude Code")
        #expect(badge.isRecognized)
        let fallback = AgentKindBadgeModel(agent: makeAgent(kind: "brand-new-agent"))
        #expect(fallback.systemImage == AgentKindBadgeModel.fallbackSystemImage)
        #expect(!fallback.isRecognized)
    }
}
