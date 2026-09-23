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

    /// The Statistics section's agent-reported telemetry inputs. The
    /// design says Statistics reuse the details store's REPORTED model
    /// and context usage — the agent's NAME is never a model. This
    /// input struct is the ONE seam the broker/details store plugs
    /// into; a missing `model` renders "Not reported" and context usage
    /// appears only when a source actually reports it. No second
    /// statistics projection with different meanings.
    struct ReportedTelemetry: Equatable, Sendable {
        /// The serving model the agent itself reported. nil = not reported.
        let model: String?
        /// Context usage as the agent reported it, already
        /// display-formatted (e.g. "45% of 200k"). nil = not reported.
        let contextUsage: String?

        static let none = ReportedTelemetry(model: nil, contextUsage: nil)
    }

    /// Actual snapshot freshness, NOT bare connectivity: a transport can
    /// be connected while the console is still awaiting the first fresh
    /// snapshot after a reconnect — that window is "Last known", not
    /// "Current".
    enum SnapshotFreshness: Equatable, Sendable {
        /// The host delivered a snapshot on the current connection.
        case current
        /// Disconnected, or connected but the first snapshot since the
        /// (re)connect has not landed yet.
        case lastKnown

        var isCurrent: Bool { self == .current }

        /// Resolves from the Console's live host state: connected AND not
        /// awaiting a snapshot is the only combination that reads Current.
        init(hostIsConnected: Bool, hostIsAwaitingSnapshot: Bool) {
            self = hostIsConnected && !hostIsAwaitingSnapshot ? .current : .lastKnown
        }
    }

    /// Interrupt support from the broker registration's capability flag.
    /// `turnInFlight` gates the enabled state at menu-construction time;
    /// the executing path rechecks connection, identity, and status again
    /// at dispatch time.
    enum InterruptSupport: Equatable, Sendable {
        /// The agent's registration advertised capabilities.interrupt.
        case supported
        /// The registration is absent, or it did not advertise interrupt —
        /// the reason names what is missing, never a generic unavailable.
        case unsupported(reason: String)

        fileprivate func support(turnInFlight: Bool) -> ActionSupport {
            switch self {
            case .supported: .available(enabled: turnInFlight)
            case .unsupported(let reason): .unsupported(reason: reason)
            }
        }
    }

    init(
        agent: ConsoleAgent,
        hostSnapshotFreshness: SnapshotFreshness,
        reportedTelemetry: ReportedTelemetry = .none,
        interruptSupport: InterruptSupport = .unsupported(
            reason:
                "This agent did not report interrupt support, so Meadow does not "
                + "send a generic interrupt — a keystroke proves nothing about "
                + "what the agent would do with it.")
    ) {
        let freshness: ContextLine.Freshness = hostSnapshotFreshness.isCurrent ? .current : .lastKnown

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

        // Statistics: reported model/context usage/working directory plus
        // freshness. The model comes ONLY from reported telemetry — the
        // agent's NAME is identity, not a model — and context usage only
        // appears when a source reports it. No state sequence numbers.
        var stats: [Statistic] = [
            Statistic(label: "Model", value: Self.valueOrNotReported(reportedTelemetry.model)),
        ]
        if let contextUsage = reportedTelemetry.contextUsage {
            stats.append(Statistic(label: "Context usage", value: contextUsage))
        }
        stats.append(
            Statistic(
                label: "Working directory",
                value: Self.valueOrNotReported(agent.displayCwd)))
        stats.append(
            Statistic(
                label: "Data freshness",
                value: hostSnapshotFreshness.isCurrent ? "Current" : "Last known"))
        statistics = stats

        actionSupport = [
            // Interrupt rides the BROKER's capability-gated interrupt
            // contract (AgentChatStore.interrupt, guarded by the
            // registration's capabilities.interrupt) — never a generic
            // Esc keystroke, which only proves a key can be SENT, not
            // that every agent treats it as interrupt. Only a turn in
            // flight qualifies; the executing path rechecks connection,
            // identity, and status again at dispatch time.
            .interruptTurn: interruptSupport.support(
                turnInFlight: agent.agent.status == .working || agent.agent.status == .blocked),
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

