import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// Dumb row views: they style whatever `ChatFiltering.visibleRows` emits and
// hold no level logic. All level decisions were already made upstream.

/// One full-width chat row. Rows are plain (no bubbles, no avatars) — the
/// text IS the interface.
struct ChatRowView: View {
    let row: ChatRow

    var body: some View {
        switch row {
        case .text(_, _, let role, let text):
            ChatTextRow(role: role, text: text)
        case .thinking(_, _, let text):
            ChatCollapsibleRow(
                title: "Thinking", icon: "brain.head.profile",
                initiallyExpanded: false, isSubtle: true
            ) {
                ChatBlockText(text, style: .thinking)
            }
        case .toolCall(_, _, let call, let result):
            ChatToolCallRow(call: call, result: result)
        case .orphanResult(let result):
            ChatCollapsibleRow(
                title: result.toolName, icon: "arrow.uturn.left.circle",
                initiallyExpanded: false, isSubtle: true
            ) {
                ChatResultBody(result: result)
            }
        case .pending(let interaction):
            ChatPendingRow(interaction: interaction, choose: { _ in })
        }
    }
}

/// User text vs assistant text vs shell output, at a glance.
private struct ChatTextRow: View {
    let role: ChatRole
    let text: String

    var body: some View {
        ChatBlockText(text, style: style)
    }

    private var style: ChatBlockText.Style {
        switch role {
        case .user: .user
        case .assistant: .assistant
        case .toolResult, .bashExecution: .output
        }
    }
}

/// The one place chat text is rendered.
struct ChatBlockText: View {
    enum Style {
        case user
        case assistant
        case output
        case thinking

        var font: Font { .system(.subheadline, design: mono ? .monospaced : .default) }
        var mono: Bool {
            switch self {
            case .output, .thinking: true
            case .user, .assistant: false
            }
        }
        var color: Color {
            switch self {
            case .user: .primary
            case .assistant: .primary
            case .output: .secondary
            case .thinking: .secondary
            }
        }
    }

    private let text: String
    private let style: Style

    init(_ text: String, style: Style = .assistant) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Group {
            if style == .user {
                // User turns: full-width row with a tinted leading rail —
                // turns read as turns without surrendering text width.
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.tint)
                        .frame(width: 3)
                    markdownText
                }
                .padding(.vertical, 4)
                .padding(.trailing, 4)
                .background(.tint.opacity(0.07))
            } else {
                markdownText
            }
        }
        .font(style.font)
        .foregroundStyle(style.color)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Renders inline markdown (bold, code, links) for conversational
    /// styles; falls back to plain text when the content isn't valid
    /// markdown (never fails visually). Output and thinking styles are
    /// terminal-ish payloads, not prose — markdown parsing mangles their
    /// leading `- ` lines and collapses their newlines, so they stay plain.
    private var markdownText: Text {
        guard style == .user || style == .assistant else {
            return Text(text)
        }
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
            return Text(attributed)
        }
        return Text(text)
    }

    private var alignment: Alignment {
        style == .user ? .trailing : .leading
    }
}

/// L1: one collapsed line per tool call. L2+ (result present): still
/// collapsed by default, tap to expand the result body; a missing result
/// means the call is still running → spinner.
struct ChatToolCallRow: View {
    let call: ToolCall
    let result: ToolResult?

    var body: some View {
        if let result {
            ChatCollapsibleRow(
                title: call.name, icon: icon, badge: result.isError ? "error" : nil,
                initiallyExpanded: false, isSubtle: true
            ) {
                ChatResultBody(result: result)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(call.name)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.small)
                    .opacity(0.7)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Running \(call.name)")
        }
    }

    private var icon: String {
        switch result?.isError {
        case .some(true): "exclamationmark.triangle"
        case .some(false): "checkmark.circle"
        case nil: "gear"
        }
    }
}

/// Flattened tool-result content, styled as terminal-ish output.
private struct ChatResultBody: View {
    let result: ToolResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if result.isError {
                Label("Error", systemImage: "exclamationmark.triangle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
            }
            ChatBlockText(result.content, style: .output)
        }
    }
}

/// The expand/collapse affordance shared by thinking blocks, tool calls,
/// and orphan results — everything the contract calls "collapsed".
struct ChatCollapsibleRow<Content: View>: View {
    let title: String
    let icon: String
    var badge: String? = nil
    var initiallyExpanded: Bool
    var isSubtle: Bool = false
    @ViewBuilder var content: () -> Content

    @State private var expanded: Bool

    init(
        title: String, icon: String, badge: String? = nil,
        initiallyExpanded: Bool = false, isSubtle: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.badge = badge
        self.initiallyExpanded = initiallyExpanded
        self.isSubtle = isSubtle
        self.content = content
        self._expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .imageScale(.small)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.footnote.weight(expanded ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    // The chevron is the visible affordance; give it a real
                    // target of its own even mid-animation.
                    .padding(6)
                    .contentShape(Rectangle())
            }

            if expanded {
                content()
            }
        }
        // A tap gesture on the whole row, not a Button: Button gestures on
        // a label with a Spacer proved unreliable across rebuilds and during
        // the expand/collapse transition (taps landed but never fired).
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        }
        .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(title)")
        .padding(.vertical, 2)
        .opacity(isSubtle ? 0.9 : 1)
    }
}

/// The blocked-agent affordance: the raw question plus one tappable button
/// per option. Visible at every detail level — it is the conversation's live
/// edge.
struct ChatPendingRow: View {
    let interaction: PendingInteraction
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Waiting for your answer", systemImage: "questionmark.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
            ChatBlockText(interaction.question, style: .assistant)
            if !interaction.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(interaction.options, id: \.self) { option in
                        Button {
                            choose(option)
                        } label: {
                            Text(option)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Answer: \(option)")
                    }
                }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Linkified chat text (openers)

/// The linkified form of `ChatBlockText`: same typography and selection,
/// with `ChatLinkDetector`'s targets applied as tappable links routed
/// through `OpenRouterCore`. Rows keep their exact layout — this wrapper
/// only swaps the inner `Text` for an attributed one; when no links are
/// detected the attributed string carries no links and rendering is
/// unchanged.
struct ChatLinkText: View {
    let text: String
    let style: ChatBlockText.Style
    let router: OpenRouterCore?

    @Environment(\.openURL) private var openURL

    init(
        _ text: String, style: ChatBlockText.Style, router: OpenRouterCore?
    ) {
        self.text = text
        self.style = style
        self.router = router
    }

    var body: some View {
        Group {
            if style == .user {
                // User turns: full-width row with a tinted leading rail —
                // matches ChatBlockText's user-turn look.
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.tint)
                        .frame(width: 3)
                    linkedText
                }
                .padding(.vertical, 4)
                .padding(.trailing, 4)
                .background(.tint.opacity(0.07))
            } else {
                linkedText
            }
        }
        .font(style.font)
        .foregroundStyle(style.color)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: alignment)
        .environment(
            \.openURL,
            OpenURLAction { url in
                guard let router else { return .discarded }
                router.open(ChatLinkTarget(linkURL: url))
                return .handled
            })
    }

    private var linkedText: Text {
        Text(attributed)
    }

    /// The row's text with markdown rendered and detected targets linked.
    /// Detection runs on the raw text; ranges are mapped onto the rendered
    /// markdown string — when markdown rendering strips syntax characters
    /// the map can miss, and that link silently stays plain text (never a
    /// visual failure).
    static func attributedText(
        _ text: String
    ) -> AttributedString {
        Self.attributedText(text, style: .assistant)
    }

    /// Markdown applies to conversational styles only (user/assistant);
    /// output and thinking stay verbatim — see ChatBlockText.markdownText.
    static func attributedText(
        _ text: String, style: ChatBlockText.Style
    ) -> AttributedString {
        var attributed: AttributedString
        if style == .user || style == .assistant {
            attributed = (try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
        } else {
            attributed = AttributedString(text)
        }
        // Detect on the RENDERED text: markdown parsing strips syntax
        // characters, so raw-text ranges would map to wrong spans. Links
        // written as markdown [text](url) already carry .link from the
        // parser; this pass catches bare URLs and absolute paths.
        let rendered = String(attributed.characters)
        for link in ChatLinkDetector.detect(in: rendered) {
            if let range = Range(link.range, in: attributed) {
                attributed[range].link = link.target.linkURL
            }
        }
        return attributed
    }

    private var attributed: AttributedString {
        Self.attributedText(text, style: style)
    }

    private var alignment: Alignment {
        style == .user ? .trailing : .leading
    }
}

/// A plain `ChatRowView` with its text/thinking rows linkified. The one
/// wrap ChatScreen applies — every row kind keeps its exact shape, only
/// the inner text views swap to `ChatLinkText` for the rows that carry
/// prose (user/assistant text, thinking bodies). Tool-call and result
/// bodies are terminal-ish output; their file paths are better served by
/// the share flow than tap-accidents mid-terminal — they stay plain v1.
struct LinkifiedChatRow: View {
    let row: ChatRow
    let router: OpenRouterCore

    init(row: ChatRow, router: OpenRouterCore) {
        self.row = row
        self.router = router
    }

    var body: some View {
        switch row {
        case .text(_, _, let role, let text):
            ChatLinkText(text, style: textStyle(role), router: router)
        case .thinking(_, _, let text):
            ChatCollapsibleRow(
                title: "Thinking", icon: "brain.head.profile",
                initiallyExpanded: false, isSubtle: true
            ) {
                ChatLinkText(text, style: .thinking, router: router)
            }
        default:
            ChatRowView(row: row)
        }
    }

    private func textStyle(_ role: ChatRole) -> ChatBlockText.Style {
        switch role {
        case .user: .user
        case .assistant: .assistant
        case .toolResult, .bashExecution: .output
        }
    }
}

/// The pane-level modifier that binds an `OpenRouterCore` and presents
/// whatever it holds. One modifier so the ChatScreen wrap stays one call.
struct ChatOpenersSurface: ViewModifier {
    @ObservedObject var router: OpenRouterCore
    /// The silent remote-file fetch (Transport.readTranscriptFile in
    /// production; in-memory closures in tests).
    var fetch: RemoteFileFetcher

    func body(content: Content) -> some View {
        content
            .modifier(OpenersPresenter(router: router))
            .onChange(of: router.defaultBrowserCandidate) { _, url in
                guard let url else { return }
                router.clearDefaultBrowserCandidate()
                openURL(url)
            }
            .task { router.fetch = fetch }
    }

    @Environment(\.openURL) private var openURL
}
