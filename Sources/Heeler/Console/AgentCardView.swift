import SwiftUI
import UIKit

/// The approved two-line Agent row (redesign §B + review findings): kind
/// glyph at the leading edge (runtime metadata, neutral fallback — never an
/// avatar initial), then the agent's actual TITLE + a small colored state
/// badge on line 1 (compact neutral row: no full-row fills, no time — the
/// wire carries no timestamps, and none are invented), and host · session ·
/// workspace · tab as ONE quiet concatenated line. No field labels, no
/// message brief. All four location values stay on the phone; the full
/// identity remains accessible on truncation.
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

    /// The title line: the agent/conversation TITLE — the server-reported
    /// name first, then the terminal title. Never the layout-composed
    /// workspace·agent·tab context (the quiet line below carries all of
    /// that; repeating it here was review finding #2).
    private var titleText: String {
        AgentCardRowTitle.title(for: agent)
    }

    /// The quiet location line: host · session · workspace · tab, dropping
    /// only values the snapshot did not carry. Field labels never render.
    private var locationLine: String {
        AgentCardLocation.line(for: agent)
    }

    private var locationParts: [String] {
        AgentCardLocation.parts(for: agent)
    }

    /// VoiceOver reads the full identity, not the truncated line: each
    /// field named, so a truncated phone render never hides identity.
    private var accessibilityIdentity: String {
        var spoken: [String] = ["Host \(agent.hostName)"]
        spoken.append("session \(AgentCardLocation.sessionLabel(for: agent))")
        if let workspace = agent.workspaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !workspace.isEmpty {
            spoken.append("workspace \(workspace)")
        }
        if let tab = AgentCardLocation.tabLabel(for: agent) {
            spoken.append("tab \(tab)")
        }
        return spoken.joinedForAccessibility()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AgentKindBadgeIcon(model: kindBadge)
                .alignmentGuide(.firstTextBaseline) { dimension in
                    dimension.height * 0.62
                }
            VStack(alignment: .leading, spacing: 2) {
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
                    AgentStateBadge(status: agent.agent.status)
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
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(titleText), \(kindBadge.accessibilityLabel), status \(agent.agent.status.searchLabel)")
        .accessibilityValue(accessibilityIdentity)
    }
}

/// The row's TITLE identity (review finding #2): the actual agent/
/// conversation title — server-reported name, then the stripped terminal
/// title, then the pane title. The configured row layout is NOT composed
/// into the title; the quiet location line carries the context.
enum AgentCardRowTitle {
    static func title(for agent: ConsoleAgent) -> String {
        // The conversation TITLE the TUI shows: `Agent.title` is the
        // terminal title with status glyphs stripped — the task title. The
        // server-reported agent NAME follows; the detected kind is the last
        // resort, never an invented label.
        let title = agent.agent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let name = agent.agent.name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty {
            return name
        }
        let pane = agent.agent.paneTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !pane.isEmpty { return pane }
        return agent.agent.displayName
    }
}

/// The quiet location line's pure projection (review finding #3): host ·
/// session · workspace · tab, one concatenated string, no field labels.
/// The DEFAULT session renders by its honest name ("default") rather than
/// dropping; the tab renders the snapshot's actual tab identity (a missing
/// explicit label renders the automatic positional name — real identity
/// from the window layout, not an invented one).
enum AgentCardLocation {
    /// The session label: the named herdr session, or "default" — the
    /// default session is real identity, not noise.
    static func sessionLabel(for agent: ConsoleAgent) -> String {
        let trimmed = agent.hostSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    /// The tab's actual identity: the explicit label when the user named
    /// the tab, else herdr's automatic positional name (real layout
    /// identity), else nil only when the snapshot carried nothing.
    static func tabLabel(for agent: ConsoleAgent) -> String? {
        guard let label = agent.tabLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !label.isEmpty
        else { return nil }
        return label
    }

    static func parts(for agent: ConsoleAgent) -> [String] {
        var parts: [String] = []
        func append(_ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        append(agent.hostName)
        append(sessionLabel(for: agent))
        append(agent.workspaceLabel)
        append(tabLabel(for: agent))
        return parts
    }

    static func line(for agent: ConsoleAgent) -> String {
        parts(for: agent).joined(separator: " · ")
    }
}

extension Array where Element == String {
    /// Small join helper for the spoken identity.
    func joinedForAccessibility() -> String {
        joined(separator: ", ")
    }
}

/// The SMALL colored state badge (review finding #1): the approved design's
/// compact "Needs you" / "Working" capsule — palette ink on a palette wash,
/// one size under the title, no full-row fills. Idle/done render a quiet
/// gray badge so the state reads as text, not just a dot.
struct AgentStateBadge: View {
    let status: AgentStatus

    private var label: String {
        status.searchLabel
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(status.inkUIColor))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(status.tintUIColor).opacity(0.18), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status \(label)")
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
    .listStyle(.plain)
}
