import SwiftUI

/// Console preview for a Host's current rows.
///
/// Draws the configured rows with their per-field styles (the editor's whole
/// purpose: the user previews what Sync sends herdr before saving), plus
/// the status badge and kind icon the Console card renders. The redesigned
/// Console card owns its own typography, so the preview renders the
/// configured presentation directly instead of pixel-matching the card.
struct AgentListFieldsPreview: View {
    let layout: AgentRowLayout
    let hostName: String

    var body: some View {
        let agent = Self.sampleAgent(hostName: hostName)
        let rows = AgentRowRenderer.render(layout: layout, agent: agent)
        HStack(alignment: .top, spacing: 10) {
            AgentKindBadgeIcon(model: AgentKindBadgeModel(agent: agent))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    AgentRowText(tokens: row, isSecondary: index > 0)
                        .font(index == 0 ? .subheadline.weight(.medium) : .caption)
                        .lineLimit(1)
                }
                if rows.isEmpty {
                    Text(verbatim: agent.agent.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    AgentStatusBadge(status: agent.agent.status)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityRespondsToUserInteraction(false)
    }

    /// Same presentation the Console card uses for this sample.
    static func presentation(layout: AgentRowLayout, hostName: String) -> AgentCardPresentation {
        AgentCardPresentation(agent: sampleAgent(hostName: hostName), layout: layout)
    }

    /// Deterministic sample values for built-in and custom tokens; not a live Agent.
    static func sampleAgent(hostName: String) -> ConsoleAgent {
        ConsoleAgent(
            hostID: sampleHostID,
            hostName: hostName,
            agent: Agent(
                terminalID: "preview-terminal",
                kind: "claude",
                title: "fix sidebar sync",
                status: .idle,
                workspaceID: "preview-workspace",
                tabID: "preview-tab",
                paneID: "preview-pane",
                cwd: "/work/heeler",
                revision: 1,
                name: "claude",
                terminalTitle: "fix sidebar sync",
                terminalTitleStripped: "fix sidebar sync",
                paneTitle: "claude",
                tokens: ["branch": "feat/sidebar"]),
            workspaceLabel: "heeler",
            repositoryCheckout: nil,
            tabLabel: "1",
            tabPosition: 1,
            workspaceTabCount: 2)
    }

    private static let sampleHostID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    ))
}
