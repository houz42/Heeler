import SwiftUI
import UIKit

/// The approved two-line Agent row (redesign, handoff §B + the kind-icon
/// addendum): kind icon at the leading edge (runtime metadata, neutral
/// fallback for unknown kinds — never an avatar initial), then title +
/// status badge on line 1, and host · session · workspace · tab as ONE
/// quiet concatenated line — no field labels, no message brief. All four
/// location values stay on the phone; the full identity remains accessible
/// on truncation (VoiceOver reads it in full).
struct AgentCardView: View {
    let agent: ConsoleAgent
    var layout: AgentRowLayout = .heelerDefault
    var isPinned: Bool = false
    /// A leading secondary span ("Label — ") before the title, for contexts
    /// where a group label was folded into the Agent's own row (tree
    /// mode's single-Agent tab). Empty by default.
    var headlinePrefix: String = ""

    private var kindBadge: AgentKindBadgeModel {
        AgentKindBadgeModel(agent: agent)
    }

    /// The title line: the presentation's headline (the configured layout
    /// still owns which fields compose it), trimmed to one line.
    private var titleText: String {
        let headline = AgentCardPresentation(agent: agent, layout: layout).headline
        let singleLine = headline.components(separatedBy: .newlines).joined(separator: " ")
        return singleLine.isEmpty ? "Agent" : singleLine
    }

    /// The quiet location line: host · session · workspace · tab, dropping
    /// values the snapshot did not carry. Field labels never render; the
    /// separators are the only chrome.
    private var locationLine: String {
        AgentCardLocation.line(for: agent)
    }

    private var locationParts: [String] {
        AgentCardLocation.parts(for: agent)
    }

    /// VoiceOver reads the full identity, not the truncated line: each
    /// field named, so a truncated phone render never hides identity.
    private var accessibilityIdentity: String {
        var spoken: [String] = []
        spoken.append("Host \(agent.hostName)")
        if !agent.hostSessionName.isEmpty {
            spoken.append("session \(agent.hostSessionName)")
        }
        if let workspace = agent.workspaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !workspace.isEmpty {
            spoken.append("workspace \(workspace)")
        }
        if agent.showsTabLabel, let tab = agent.tabLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !tab.isEmpty {
            spoken.append("tab \(tab)")
        }
        return spoken.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentKindBadgeIcon(model: kindBadge)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 6) {
                    if !headlinePrefix.isEmpty {
                        Text(verbatim: headlinePrefix)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(verbatim: titleText)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Pinned")
                    }
                    Spacer(minLength: 8)
                    AgentStatusBadge(status: agent.agent.status)
                }
                if !locationParts.isEmpty {
                    Text(verbatim: locationLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // The quiet line truncates tail-first; the full
                        // identity is only a long-press/AX read away.
                        .truncationMode(.head)
                        .help(locationLine)
                        .contextMenu {
                            Text(locationLine)
                        }
                }
            }
        }
        .padding(.vertical, 6)
        // A live Agent tints the whole row's background at low opacity so
        // the state reads from scan distance; idle/done stay plain.
        .background(rowTint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(titleText), \(kindBadge.accessibilityLabel), status \(agent.agent.status.searchLabel)")
        .accessibilityValue(accessibilityIdentity)
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
}

/// The quiet location line's pure projection: host · session · workspace ·
/// tab, one concatenated string, no field labels, values the snapshot did
/// not carry dropped instead of rendering empty gaps. herdr's automatic
/// positional tab label never renders (`showsTabLabel`).
enum AgentCardLocation {
    static func parts(for agent: ConsoleAgent) -> [String] {
        var parts: [String] = []
        func append(_ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        append(agent.hostName)
        append(agent.hostSessionName.isEmpty ? nil : agent.hostSessionName)
        append(agent.workspaceLabel)
        if agent.showsTabLabel { append(agent.tabLabel) }
        return parts
    }

    static func line(for agent: ConsoleAgent) -> String {
        parts(for: agent).joined(separator: " · ")
    }
}

/// Keep per-field emphasis through the final Text instead of flattening the
/// rendered tokens into a String. Separators retain the row's base emphasis.
/// (Retained for the Settings Agent List Fields preview surfaces; the
/// Console's own row no longer consumes it.)
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
                hostSessionName: "main",
                tabLabel: "tests",
                tabPosition: 1,
                workspaceTabCount: 2))
        AgentCardView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_b", kind: "opencode", title: "Draft the release notes",
                    status: .working, workspaceID: "w2", tabID: "w2:t1", paneID: "w2:p1",
                    cwd: "/tmp", revision: 1),
                workspaceLabel: nil,
                repositoryCheckout: nil))
        AgentCardView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "build",
                agent: Agent(
                    terminalID: "term_c", kind: "some-new-runtime", title: "Unknown kind row",
                    status: .idle, workspaceID: "w3", tabID: "w3:t1", paneID: "w3:p1",
                    cwd: "/srv", revision: 1),
                workspaceLabel: "infra",
                repositoryCheckout: nil,
                hostSessionName: "ci"))
    }
}
