import SwiftUI
import UIKit

/// The shared Agent Row Layout leads each card; status and Heeler Pin end
/// Row 1, and the Host name ends the last additional row (or its own line
/// when Row 1 is the only row). Fields retain their emphasis using accessible
/// semantic colors; plugin colors and weights do not replace app typography.
struct AgentCardView: View {
    let agent: ConsoleAgent
    var layout: AgentRowLayout = .heelerDefault
    var isPinned: Bool = false

    private var presentation: AgentCardPresentation {
        AgentCardPresentation(agent: agent, layout: layout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Centered, not baseline-aligned: the status dot is smaller
            // than Row 1's type, so baseline alignment drops it below Row 1.
            HStack(alignment: .center) {
                AgentRowText(tokens: presentation.rows.first ?? [])
                    .font(.headline)
                    .lineLimit(1)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .layoutPriority(1)
                        .accessibilityLabel("Pinned")
                }
                Spacer(minLength: 8)
                AgentStatusBadge(status: agent.agent.status)
            }
            let additionalRows = Array(presentation.rows.dropFirst())
            ForEach(Array(additionalRows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    AgentRowText(tokens: row, isSecondary: true)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // The Host shares the last row's line and keeps its width;
                    // the row's fields truncate first.
                    if index == additionalRows.count - 1 {
                        Spacer(minLength: 8)
                        hostText.layoutPriority(1)
                    }
                }
            }
            if additionalRows.isEmpty {
                hostText.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        // Terminal blank rows become bounded extra card spacing on a phone.
        .padding(.bottom, CGFloat(min(layout.rowGap, 3)) * 8)
        // A live Agent tints the whole row's background at low opacity so
        // the state reads from scan distance; idle/done stay plain.
        .background(rowTint)
    }

    @ViewBuilder
    private var rowTint: some View {
        switch agent.agent.status {
        case .working, .blocked:
            Color(agent.agent.status.tintUIColor)
                .opacity(0.10)
        default:
            EmptyView()
        }
    }

    private var hostText: some View {
        Text(verbatim: hostChip)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// The trailing Host chip: `host:session` when the Host points at a
    /// named herdr session, else the Host name alone.
    private var hostChip: String {
        agent.hostSessionName.isEmpty
            ? agent.hostName
            : "\(agent.hostName):\(agent.hostSessionName)"
    }
}

/// Keep per-field emphasis through the final Text instead of flattening the
/// rendered tokens into a String. Separators retain the row's base emphasis.
struct AgentRowText: View {
    let tokens: [RenderedToken]
    var isSecondary = false

    var body: some View {
        Text(attributedText)
    }

    private var attributedText: AttributedString {
        var result = AttributedString()
        for token in tokens {
            var span = AttributedString(token.text)
            let color: UIColor = if token.dim == true {
                isSecondary ? .tertiaryLabel : .secondaryLabel
            } else {
                isSecondary ? .secondaryLabel : .label
            }
            span.foregroundColor = Color(uiColor: color)
            result.append(span)
        }
        return result
    }
}

struct AgentCardPresentation: Equatable, Sendable {
    let rows: [[RenderedToken]]

    var headline: String { rows.first?.map(\.text).joined() ?? "Agent" }
    var additionalRows: [String] { rows.dropFirst().map { $0.map(\.text).joined() } }

    init(agent: ConsoleAgent, layout: AgentRowLayout = .heelerDefault) {
        let rendered = AgentRowRenderer.render(layout: layout, agent: agent)
        if rendered.isEmpty {
            let name = agent.agent.displayName
            rows = [[RenderedToken(
                token: .agent,
                text: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Agent" : name,
                fg: nil, bold: nil, dim: nil)]]
        } else {
            rows = rendered
        }
    }

    /// Bound by graphemes, preserving literal plugin text and whole emoji.
    var switcherTitle: String {
        let singleLine = headline.components(separatedBy: .newlines).joined(separator: " ")
        return singleLine.count > 48 ? String(singleLine.prefix(47)) + "…" : singleLine
    }
}

/// The agent's live state as a big colored dot (~10–12pt), painted from
/// the single status palette. Working keeps the live solving orb inside
/// the dot's footprint — a still badge cannot tell a busy Agent from a
/// finished one at a glance.
struct AgentStatusBadge: View {
    let status: AgentStatus

    var body: some View {
        Group {
            if status == .working {
                SolvingOrbView(size: 11)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(Color(status.inkUIColor))
                    .frame(width: 11, height: 11)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 11, height: 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent status")
        .accessibilityValue(status.rawValue.capitalized)
    }
}

#Preview {
    List {
        AgentCardView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_a", kind: "claude", title: "Fix the flaky test",
                    status: .blocked, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
                    cwd: "/work/proj", revision: 3),
                workspaceLabel: "proj",
                repositoryCheckout: RepositoryCheckout(
                    repoKey: "/work/proj/.git",
                    repoName: "proj",
                    repoRoot: "/work/proj",
                    checkoutPath: "/work/proj-wt",
                    isLinkedWorktree: true),
                lastOutputSnippet: "Allow Claude to run rm -rf? 1. Yes 2. No"))
        // No workspace in the snapshot: the Agent's own name takes the lead.
        AgentCardView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_b", kind: "claude", title: "Draft the release notes",
                    status: .working, workspaceID: "w2", tabID: "w2:t1", paneID: "w2:p1",
                    cwd: "/tmp", revision: 1),
                workspaceLabel: nil,
                repositoryCheckout: nil,
                lastOutputSnippet: nil))
    }
}
