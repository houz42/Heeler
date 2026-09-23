import SwiftUI

/// The Agent header menu's content (v3 design, "Header menu and statistics").
/// Rendered inside the header's Menu, in the design's fixed section order:
/// identity/context (host → session → workspace → tab), Statistics, Actions,
/// Companion terminal. The caller owns the Companion terminal entry because
/// it wires the detail's live open-terminal store; everything here is a pure
/// projection of `AgentHeaderMenuModel`.
struct AgentHeaderMenuContent: View {
    let model: AgentHeaderMenuModel
    /// The agent's spoken name for confirmation dialogs that must name
    /// their target (the design's destructive-action rule).
    let agentDisplayName: String
    /// Lifecycle handlers. Interrupt is herdr's `agent.send_keys` with the
    /// canonical Esc key; New conversation routes through the existing
    /// launch flow with this agent as origin.
    let interruptTurn: () -> Void
    let startNewConversation: () -> Void
    /// The Companion terminal entry, supplied by the detail (it owns the
    /// open-terminal store and its availability). Nil hides the section.
    var companionTerminal: AgentHeaderCompanionTerminal? = nil

    var body: some View {
        // Section 1: identity/context. The design's order is fixed:
        // host → session → workspace → tab. SwiftUI Menu rows carry the
        // label/value pair; freshness rides the value ("… — Last known").
        Section("Agent") {
            ForEach(model.contextLines, id: \.label) { line in
                Text(verbatim: "\(line.label): \(line.value)\(freshnessSuffix(line.freshness))")
            }
        }

        // Section 2: Statistics.
        Section("Statistics") {
            ForEach(model.statistics, id: \.label) { statistic in
                Text(verbatim: "\(statistic.label): \(statistic.value)")
            }
        }

        // Section 3: Actions, in the design's fixed order. Unsupported
        // rows stay visible and disabled with their reason — the design
        // forbids hiding a relevant action behind absence.
        Section("Actions") {
            ForEach(AgentHeaderMenuModel.Action.allCases, id: \.self) { action in
                switch model.actionSupport[action] {
                case .available(let enabled):
                    Button {
                        switch action {
                        case .interruptTurn: interruptTurn()
                        case .newConversation: startNewConversation()
                        case .stopAgent, .resumeConversation: break
                        }
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .disabled(!enabled)
                case .unsupported(let reason):
                    // A disabled Menu row cannot carry its reason in the
                    // row itself; the reason renders as the row's detail
                    // line so the user reads WHY without a tap that goes
                    // nowhere.
                    VStack(alignment: .leading, spacing: 2) {
                        Label(action.title, systemImage: action.systemImage)
                            .foregroundStyle(.secondary)
                        Text(verbatim: reason)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                case nil:
                    EmptyView()
                }
            }
        }

        // Section 4: Companion terminal (the caller's live wiring).
        if let companionTerminal {
            Section("Companion terminal") {
                Button {
                    companionTerminal.open()
                } label: {
                    Label(
                        companionTerminal.isOpening ? "Opening…" : "Open Shell Terminal",
                        systemImage: "terminal")
                }
                .disabled(!companionTerminal.canOpen)
                if companionTerminal.canOpen == false,
                    let reason = companionTerminal.unavailableReason
                {
                    Text(verbatim: reason)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func freshnessSuffix(_ freshness: AgentHeaderMenuModel.ContextLine.Freshness) -> String {
        switch freshness {
        case .current: ""
        case .lastKnown: " — Last known"
        }
    }
}

/// The Companion terminal entry's view inputs. Availability mirrors the
/// detail's open-terminal store (which already refuses a missing cwd and
/// another window's terminal channel); the reason surfaces the same honesty
/// rule as unsupported lifecycle actions.
struct AgentHeaderCompanionTerminal: Equatable, Sendable {
    let canOpen: Bool
    let isOpening: Bool
    let unavailableReason: String?
    let open: @Sendable () -> Void

    static func == (lhs: AgentHeaderCompanionTerminal, rhs: AgentHeaderCompanionTerminal) -> Bool {
        lhs.canOpen == rhs.canOpen && lhs.isOpening == rhs.isOpening
            && lhs.unavailableReason == rhs.unavailableReason
    }
}
