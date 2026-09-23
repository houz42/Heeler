import Foundation

/// The Agent header menu's model (v3 design, "Header menu and statistics"):
/// a pure projection of one `ConsoleAgent` plus the host connection state
/// into the menu's sections — identity/context, Statistics, Actions — so
/// every visibility/enablement rule is unit-testable without hosting a view.
///
/// Menu sections render IN ORDER: identity/context (host → session →
/// workspace → tab), Statistics, Actions, then the caller's Companion
/// terminal section. Missing fields say "Not reported"; data from a
/// snapshot taken while the Host was last connected says "Last known".
/// State sequence numbers are deliberately NOT user statistics.
struct AgentHeaderMenuModel: Equatable, Sendable {
    // MARK: - Identity/context

    /// One line of the identity/context section: a label and its value,
    /// with the freshness the design mandates.
    struct ContextLine: Equatable, Sendable {
        enum Freshness: Equatable, Sendable {
            /// Read from a live snapshot on a connected Host.
            case current
            /// The Host is not connected now; the value came from the last
            /// snapshot it delivered.
            case lastKnown
        }

        let label: String
        let value: String
        let freshness: Freshness
    }

    // MARK: - Statistics

    /// One row of the Statistics section. Missing agent-reported fields
    /// present as "Not reported" values, not absent rows.
    struct Statistic: Equatable, Sendable {
        let label: String
        let value: String
    }

    // MARK: - Actions

    /// The lifecycle actions the v3 design names: Interrupt turn, Stop
    /// agent, Resume saved conversation, New conversation. `support` says
    /// what herdr 0.9.1 (protocol 22) actually carries — the design's rule
    /// is that a missing primitive is a prerequisite, never faked.
    enum Action: Equatable, Sendable, CaseIterable {
        case interruptTurn
        case stopAgent
        case resumeConversation
        case newConversation

        var title: String {
            switch self {
            case .interruptTurn: "Interrupt turn"
            case .stopAgent: "Stop agent"
            case .resumeConversation: "Resume saved conversation"
            case .newConversation: "New conversation"
            }
        }

        var systemImage: String {
            switch self {
            case .interruptTurn: "hand.raised"
            case .stopAgent: "stop.circle"
            case .resumeConversation: "arrow.clockwise.circle"
            case .newConversation: "plus.message"
            }
        }
    }

    /// What one action is allowed to do on this build.
    enum ActionSupport: Equatable, Sendable {
        /// Ready: visible, enabled, and `enabled` states whether the
        /// current agent state qualifies (Interrupt only while a turn is
        /// in flight).
        case available(enabled: Bool)
        /// herdr has no first-class primitive for this operation, so the
        /// row shows disabled with the honest reason. The reason is part
        /// of the contract — it must name the missing capability, not a
        /// generic "not available".
        case unsupported(reason: String)
    }

    let contextLines: [ContextLine]
    let statistics: [Statistic]
    /// Per-action support, in the design's fixed order
    /// (interrupt, stop, resume, new conversation).
    let actionSupport: [Action: ActionSupport]

    init(
        agent: ConsoleAgent,
        hostIsConnected: Bool
    ) {
        let freshness: ContextLine.Freshness = hostIsConnected ? .current : .lastKnown

        // Identity/context, host → session → workspace → tab. Every line
        // always renders: a missing value is "Not reported", never a hole.
        contextLines = [
            ContextLine(
                label: "Host",
                value: agent.hostName,
                freshness: freshness),
            ContextLine(
                label: "Session",
                value: Self.valueOrNotReported(
                    agent.hostSessionName.trimmingCharacters(in: .whitespacesAndNewlines)),
                freshness: freshness),
            ContextLine(
                label: "Workspace",
                value: Self.valueOrNotReported(agent.workspaceLabel),
                freshness: freshness),
            ContextLine(
                label: "Tab",
                value: Self.valueOrNotReported(
                    agent.tabLabel?.trimmingCharacters(in: .whitespacesAndNewlines)),
                freshness: freshness),
        ]

        // Statistics: reported model/context/working directory plus
        // freshness, reusing exactly what the Console row already
        // derives — no invented fields, no state sequence numbers.
        statistics = [
            Statistic(label: "Model", value: Self.valueOrNotReported(agent.agent.name)),
            Statistic(
                label: "Working directory",
                value: Self.valueOrNotReported(agent.displayCwd)),
            Statistic(
                label: "Data freshness",
                value: hostIsConnected ? "Current" : "Last known"),
        ]

        // Lifecycle support, verified against herdr 0.9.1 / protocol 22
        // (`herdr api schema --json`): agent.send_keys (interrupt via the
        // canonical Esc key), agent.start (via the new-agent launch flow),
        // and NO agent.stop / agent.resume exist.
        let status = agent.agent.status
        actionSupport = [
            // agent.send_keys with herdr's canonical Esc spelling. Only a
            // turn in flight (working, or blocked mid-turn) can be
            // interrupted; an idle/done agent has nothing to interrupt.
            .interruptTurn: .available(
                enabled: status == .working || status == .blocked),
            // No herdr primitive: agent.* carries list/get/read/send_keys/
            // rename/view/focus/start/prompt/wait — nothing stops a
            // process gracefully. pane.close exists but is a destructive
            // pane close, not a stop; the destructive close stays where it
            // already lives (the agent row's actions), not disguised here.
            .stopAgent: .unsupported(
                reason:
                    "herdr 0.9.1 has no agent.stop — this build does not fake a stop. "
                    + "Use Close Agent (destructive) from the agent's More menu instead."),
            // Same verification: no agent.resume primitive, and the
            // adapter's saved-conversation catalog is not exposed over the
            // wire either, so there is nothing honest to resume into.
            .resumeConversation: .unsupported(
                reason:
                    "herdr 0.9.1 has no agent.resume — resuming a saved "
                    + "conversation is not available on this host."),
            // agent.start through the existing new-agent flow (StartAgentView
            // with the agent's own Host/workspace/directory as the launch
            // origin), exactly as the Composer's New Agent entry does.
            .newConversation: .available(enabled: true),
        ]
    }

    private static func valueOrNotReported(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "Not reported" }
        return value
    }
}
