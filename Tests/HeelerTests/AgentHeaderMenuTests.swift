import Foundation
import Testing

@testable import Heeler

/// The Agent header menu's model contract (v3 "Header menu and statistics"):
/// fixed section order, "Not reported" for missing fields, "Last known"
/// freshness offline, and lifecycle actions gated to exactly what herdr
/// 0.9.1 carries.
@MainActor
@Suite("Agent header menu model")
struct AgentHeaderMenuTests {
    private func makeAgent(
        hostName: String = "devbox",
        sessionName: String = "main",
        workspaceLabel: String? = "meadow",
        tabLabel: String? = "work",
        name: String? = "ios-polish",
        cwd: String? = "/workspace/meadow",
        status: AgentStatus = .working
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: hostName,
            agent: Agent(
                terminalID: "term:p1", kind: "omp", title: "Polish",
                status: status,
                workspaceID: "w1", tabID: "w1:t1", paneID: "p1",
                cwd: cwd ?? "", revision: 1, name: name),
            workspaceLabel: workspaceLabel,
            repositoryCheckout: nil,
            hostSessionName: sessionName,
            tabLabel: tabLabel, tabPosition: 1, workspaceTabCount: 1,
            snapshotOrder: 0)
    }

    // MARK: Identity/context section

    @Test func contextLinesFollowHostSessionWorkspaceTabOrder() {
        let model = AgentHeaderMenuModel(agent: makeAgent(), hostIsConnected: true)
        #expect(model.contextLines.map(\.label) == ["Host", "Session", "Workspace", "Tab"])
        #expect(model.contextLines.map(\.value) == ["devbox", "main", "meadow", "work"])
    }

    @Test func missingContextValuesSayNotReportedNeverVanish() {
        // The design: "Missing fields say Not reported" — a missing
        // session/workspace/tab still renders its line.
        let model = AgentHeaderMenuModel(
            agent: makeAgent(sessionName: "", workspaceLabel: nil, tabLabel: nil),
            hostIsConnected: true)
        #expect(
            model.contextLines.map(\.value)
                == ["devbox", "Not reported", "Not reported", "Not reported"])
    }

    @Test func connectedHostIsCurrentDisconnectedIsLastKnown() {
        let connected = AgentHeaderMenuModel(agent: makeAgent(), hostIsConnected: true)
        #expect(connected.contextLines.allSatisfy { $0.freshness == .current })
        #expect(connected.statistics.last?.value == "Current")

        let offline = AgentHeaderMenuModel(agent: makeAgent(), hostIsConnected: false)
        #expect(offline.contextLines.allSatisfy { $0.freshness == .lastKnown })
        #expect(offline.statistics.last?.value == "Last known")
    }

    // MARK: Statistics section

    @Test func statisticsCarryModelWorkingDirectoryAndFreshness() {
        let model = AgentHeaderMenuModel(agent: makeAgent(), hostIsConnected: true)
        #expect(
            model.statistics.map(\.label)
                == ["Model", "Working directory", "Data freshness"])
        #expect(model.statistics[0].value == "ios-polish")
        #expect(model.statistics[1].value == "/workspace/meadow")
    }

    @Test func missingStatisticsSayNotReported() {
        let model = AgentHeaderMenuModel(
            agent: makeAgent(name: nil, cwd: nil), hostIsConnected: true)
        #expect(model.statistics[0].value == "Not reported")
        #expect(model.statistics[1].value == "Not reported")
    }

    @Test func stateSequenceNumbersAreNotStatistics() {
        // The design: "Do not turn state sequence numbers into user
        // statistics." The projection must carry only the three
        // user-facing rows regardless of the agent's seq metadata.
        let model = AgentHeaderMenuModel(
            agent: makeAgent(status: .idle), hostIsConnected: true)
        #expect(model.statistics.count == 3)
        #expect(!model.statistics.contains { $0.value.contains("seq") })
    }

    // MARK: Lifecycle actions

    @Test func actionsFollowTheDesignsFixedOrder() {
        let model = AgentHeaderMenuModel(agent: makeAgent(), hostIsConnected: true)
        #expect(
            AgentHeaderMenuModel.Action.allCases.map(\.title)
                == [
                    "Interrupt turn", "Stop agent",
                    "Resume saved conversation", "New conversation",
                ])
        #expect(Set(model.actionSupport.keys) == Set(AgentHeaderMenuModel.Action.allCases))
    }

    @Test func interruptIsOnlyEnabledWhileATurnIsInFlight() {
        for (status, expected) in [
            (AgentStatus.working, true),
            (AgentStatus.blocked, true),
            (AgentStatus.idle, false),
            (AgentStatus.done, false),
        ] {
            let model = AgentHeaderMenuModel(
                agent: makeAgent(status: status), hostIsConnected: true)
            guard case .available(let enabled)? = model.actionSupport[.interruptTurn]
            else {
                Issue.record("interrupt must be .available, not unsupported")
                continue
            }
            #expect(enabled == expected, "status \(status.rawValue)")
        }
    }

    @Test func stopAndResumeAreHonestlyUnsupportedNotHidden() {
        // herdr 0.9.1 (protocol 22) has no agent.stop / agent.resume —
        // the design forbids faking them. They stay VISIBLE with a
        // reason naming the missing primitive.
        let model = AgentHeaderMenuModel(agent: makeAgent(), hostIsConnected: true)
        guard case .unsupported(let stopReason)? = model.actionSupport[.stopAgent]
        else {
            Issue.record("stop must be .unsupported on herdr 0.9.1")
            return
        }
        #expect(stopReason.contains("agent.stop"))
        guard case .unsupported(let resumeReason)? = model.actionSupport[.resumeConversation]
        else {
            Issue.record("resume must be .unsupported on herdr 0.9.1")
            return
        }
        #expect(resumeReason.contains("agent.resume"))
    }

    @Test func newConversationIsAvailableOnEveryStatus() {
        for status in [AgentStatus.working, .blocked, .idle, .done] {
            let model = AgentHeaderMenuModel(
                agent: makeAgent(status: status), hostIsConnected: true)
            guard case .available(let enabled)? = model.actionSupport[.newConversation]
            else {
                Issue.record("new conversation must be .available")
                continue
            }
            #expect(enabled)
        }
    }

    @Test func lifecycleSupportIsIndependentOfConnectionState() {
        // Disconnect must gate only FRESHNESS, not the actions: herdr
        // will refuse the send_keys/start itself when the Host is down,
        // and that failure surfaces honestly at delivery time.
        let offline = AgentHeaderMenuModel(agent: makeAgent(), hostIsConnected: false)
        guard case .available(let enabled)? = offline.actionSupport[.interruptTurn]
        else {
            Issue.record("interrupt stays structurally available offline")
            return
        }
        #expect(enabled)
    }
}
