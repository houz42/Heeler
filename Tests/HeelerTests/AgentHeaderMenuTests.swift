import Foundation
import Testing

@testable import Heeler

/// The Agent header menu's model contract (v3 "Header menu and statistics"):
/// fixed section order, "Not reported" for missing fields, ACTUAL snapshot
/// freshness (never bare connectivity), reported-telemetry-only statistics
/// (the agent's NAME is never a model), and lifecycle actions gated to
/// exactly what herdr 0.9.1 + the broker registration carry.
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
        let model = AgentHeaderMenuModel(
            agent: makeAgent(), hostSnapshotFreshness: .current)
        #expect(model.contextLines.map(\.label) == ["Host", "Session", "Workspace", "Tab"])
        #expect(model.contextLines.map(\.value) == ["devbox", "main", "meadow", "work"])
    }

    @Test func missingContextValuesSayNotReportedNeverVanish() {
        // The design: "Missing fields say Not reported" — a missing
        // session/workspace/tab still renders its line.
        let model = AgentHeaderMenuModel(
            agent: makeAgent(sessionName: "", workspaceLabel: nil, tabLabel: nil),
            hostSnapshotFreshness: .current)
        #expect(
            model.contextLines.map(\.value)
                == ["devbox", "Not reported", "Not reported", "Not reported"])
    }

    // MARK: Freshness (review finding 3: actual snapshot state, not
    // bare connectivity)

    @Test func connectedButAwaitingSnapshotIsLastKnown() {
        // A transport can be connected while the first fresh snapshot
        // since the (re)connect has not landed: that window is Last
        // known, NOT Current.
        let window = AgentHeaderMenuModel.SnapshotFreshness(
            hostIsConnected: true, hostIsAwaitingSnapshot: true)
        #expect(window == .lastKnown)
        let model = AgentHeaderMenuModel(agent: makeAgent(), hostSnapshotFreshness: window)
        #expect(model.contextLines.allSatisfy { $0.freshness == .lastKnown })
        #expect(model.statistics.last?.value == "Last known")
    }

    @Test func connectedAndDeliveredSnapshotIsCurrent() {
        let fresh = AgentHeaderMenuModel.SnapshotFreshness(
            hostIsConnected: true, hostIsAwaitingSnapshot: false)
        #expect(fresh == .current)
        let model = AgentHeaderMenuModel(agent: makeAgent(), hostSnapshotFreshness: fresh)
        #expect(model.contextLines.allSatisfy { $0.freshness == .current })
        #expect(model.statistics.last?.value == "Current")
    }

    @Test func disconnectedIsLastKnown() {
        let offline = AgentHeaderMenuModel.SnapshotFreshness(
            hostIsConnected: false, hostIsAwaitingSnapshot: false)
        #expect(offline == .lastKnown)
        let model = AgentHeaderMenuModel(agent: makeAgent(), hostSnapshotFreshness: offline)
        #expect(model.statistics.last?.value == "Last known")
    }

    // MARK: Statistics (review finding 1: reported telemetry only)

    @Test func modelStatisticComesOnlyFromReportedTelemetry() {
        // The agent's NAME is identity, not a model: without reported
        // telemetry the Model row says Not reported — even though the
        // agent HAS a name.
        let none = AgentHeaderMenuModel(
            agent: makeAgent(), hostSnapshotFreshness: .current, reportedTelemetry: .none)
        #expect(none.statistics.first?.label == "Model")
        #expect(none.statistics.first?.value == "Not reported")

        let reported = AgentHeaderMenuModel(
            agent: makeAgent(), hostSnapshotFreshness: .current,
            reportedTelemetry: .init(model: "qwen3-coder", contextUsage: nil))
        #expect(reported.statistics.first?.value == "qwen3-coder")
    }

    @Test func contextUsageAppearsOnlyWhenReported() {
        let without = AgentHeaderMenuModel(
            agent: makeAgent(), hostSnapshotFreshness: .current,
            reportedTelemetry: .init(model: "m", contextUsage: nil))
        #expect(!without.statistics.contains { $0.label == "Context usage" })

        let with = AgentHeaderMenuModel(
            agent: makeAgent(), hostSnapshotFreshness: .current,
            reportedTelemetry: .init(model: "m", contextUsage: "45% of 200k"))
        let row = with.statistics.first { $0.label == "Context usage" }
        #expect(row?.value == "45% of 200k")
    }

    @Test func statisticsCarryWorkingDirectoryAndFreshness() {
        let model = AgentHeaderMenuModel(
            agent: makeAgent(), hostSnapshotFreshness: .current)
        #expect(model.statistics.map(\.label) == ["Model", "Working directory", "Data freshness"])
        #expect(model.statistics[1].value == "/workspace/meadow")
    }

    @Test func missingStatisticsSayNotReported() {
        let model = AgentHeaderMenuModel(
            agent: makeAgent(cwd: nil), hostSnapshotFreshness: .current)
        #expect(model.statistics.first?.value == "Not reported")
        #expect(
            model.statistics.first { $0.label == "Working directory" }?.value
                == "Not reported")
    }

    @Test func stateSequenceNumbersAreNotStatistics() {
        // The design: "Do not turn state sequence numbers into user
        // statistics." The projection must carry only user-facing rows.
        let model = AgentHeaderMenuModel(
            agent: makeAgent(status: .idle), hostSnapshotFreshness: .current)
        #expect(model.statistics.count == 3)
        #expect(!model.statistics.contains { $0.value.contains("seq") })
    }

    // MARK: Lifecycle actions

    @Test func actionsFollowTheDesignsFixedOrder() {
        let model = AgentHeaderMenuModel(
            agent: makeAgent(), hostSnapshotFreshness: .current)
        #expect(
            AgentHeaderMenuModel.Action.allCases.map(\.title)
                == [
                    "Interrupt turn", "Stop agent",
                    "Resume saved conversation", "New conversation",
                ])
        #expect(Set(model.actionSupport.keys) == Set(AgentHeaderMenuModel.Action.allCases))
    }

    @Test func supportedInterruptIsEnabledOnlyWhileATurnIsInFlight() {
        for (status, expected) in [
            (AgentStatus.working, true),
            (AgentStatus.blocked, true),
            (AgentStatus.idle, false),
            (AgentStatus.done, false),
        ] {
            let model = AgentHeaderMenuModel(
                agent: makeAgent(status: status), hostSnapshotFreshness: .current,
                interruptSupport: .supported)
            guard case .available(let enabled)? = model.actionSupport[.interruptTurn]
            else {
                Issue.record("supported interrupt must be .available")
                continue
            }
            #expect(enabled == expected, "status \(status.rawValue)")
        }
    }

    @Test func unadvertisedInterruptIsUnsupportedWithReason() {
        // Review finding 2: a generic Esc only proves a key can be SENT.
        // Without the registration advertising interrupt, the row stays
        // unsupported with a reason — never a send-anyway button.
        let model = AgentHeaderMenuModel(
            agent: makeAgent(), hostSnapshotFreshness: .current,
            interruptSupport: .unsupported(reason: "Registration did not advertise interrupt."))
        guard case .unsupported(let reason)? = model.actionSupport[.interruptTurn]
        else {
            Issue.record("unadvertised interrupt must be .unsupported")
            return
        }
        #expect(reason.contains("interrupt"))
    }

    @Test func stopAndResumeAreHonestlyUnsupportedNotHidden() {
        // herdr 0.9.1 (protocol 22) has no agent.stop / agent.resume —
        // the design forbids faking them. They stay VISIBLE with a
        // reason naming the missing primitive.
        let model = AgentHeaderMenuModel(
            agent: makeAgent(), hostSnapshotFreshness: .current)
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
                agent: makeAgent(status: status), hostSnapshotFreshness: .current)
            guard case .available(let enabled)? = model.actionSupport[.newConversation]
            else {
                Issue.record("new conversation must be .available")
                continue
            }
            #expect(enabled)
        }
    }

    @Test func lifecycleSupportIsIndependentOfConnectionState() {
        // Disconnect must gate only FRESHNESS, not the actions: the
        // executing path rechecks connection honestly at dispatch time.
        let offline = AgentHeaderMenuModel(
            agent: makeAgent(), hostSnapshotFreshness: .lastKnown,
            interruptSupport: .supported)
        guard case .available(let enabled)? = offline.actionSupport[.interruptTurn]
        else {
            Issue.record("interrupt stays structurally available offline")
            return
        }
        #expect(enabled)
    }
}
