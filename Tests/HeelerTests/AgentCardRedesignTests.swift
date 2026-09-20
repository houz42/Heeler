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

    @Test func defaultSessionRendersByItsHonestName() {
        // Review finding #3: the default session is real identity.
        let agent = makeAgent(host: "devbox", session: "", workspace: "heeler", tab: "tests")
        #expect(AgentCardLocation.line(for: agent) == "devbox · default · heeler · tests")
        #expect(AgentCardLocation.sessionLabel(for: agent) == "default")
    }

    @Test func tabIdentityRendersEvenWhenTheNameIsAutomatic() {
        // Review finding #3: the snapshot's actual tab identity (herdr's
        // automatic positional name) is real layout identity.
        let agent = makeAgent(tab: "1", tabCount: 1, tabPosition: 1)
        #expect(AgentCardLocation.tabLabel(for: agent) == "1")
        #expect(AgentCardLocation.line(for: agent).hasSuffix("· 1"))
        // A manual label on a multi-tab workspace stays.
        let manual = makeAgent(tab: "refactor", tabCount: 2, tabPosition: 1)
        #expect(AgentCardLocation.line(for: manual).hasSuffix("refactor"))
    }

    @Test func titleLineIsTheConversationTitleNotComposedContext() {
        // Review finding #2: the title is the agent's actual title, never
        // the layout-composed workspace·agent·tab context.
        // The task title wins over the server-reported agent name: the
        // row's first line is the conversation title the TUI shows.
        let agent = makeAgent(name: "reviewer", title: "Checkout review")
        #expect(AgentCardRowTitle.title(for: agent) == "Checkout review")
        let unnamed = makeAgent(name: nil, title: "Fix the flaky test")
        #expect(AgentCardRowTitle.title(for: unnamed) == "Fix the flaky test")
        #expect(!AgentCardRowTitle.title(for: unnamed).contains("heeler"))
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
