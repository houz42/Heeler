import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// Dumb row views: they style whatever `ChatFiltering.visibleRows` emits and
// hold no level logic. All level decisions were already made upstream.

/// Accent-wash opacities for surfaces painted straight onto the chat's
/// default background. One alpha does not serve both appearances: 6–7% of
/// the accent or orange disappears against dark mode's near-black
/// background, so dark lifts the alpha until the wash reads again (the
/// values are otherwise the original design's).
fileprivate enum ChatWash {
    /// The tinted wash behind a user turn's full-width row.
    static func turn(isDark: Bool) -> Double { isDark ? 0.16 : 0.07 }
    /// The orange wash behind the blocked-agent pending card.
    static func pending(isDark: Bool) -> Double { isDark ? 0.12 : 0.06 }
    /// The dimmed orange wash behind an answered pending card.
    static func pendingAnswered(isDark: Bool) -> Double { isDark ? 0.05 : 0.03 }
}

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
            ChatPendingRow(interaction: interaction, answer: interaction.answer, choose: { _ in })
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

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Group {
            if style == .user {
                // User turns: full-width row with a tinted leading rail —
                // turns read as turns without surrendering text width.
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.tint)
                        .frame(width: 3)
                    markdownBody
                }
                .padding(.vertical, 4)
                .padding(.trailing, 4)
                .background(.tint.opacity(ChatWash.turn(isDark: isDark)))
            } else {
                markdownBody
            }
        }
        .font(style.font)
        .foregroundStyle(style.color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Prose (user/assistant) renders as rich markdown; output/thinking
    /// stay plain monospace — terminal-ish content must never have its
    /// syntax reinterpreted (a fenced block inside tool output is data,
    /// not markup).
    @ViewBuilder private var markdownBody: some View {
        if style.mono {
            Text(text)
                .textSelection(.enabled)
        } else {
            ChatMarkdownView(markdown: text)
        }
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
/// edge. While unanswered it is loud (orange wash, full-width buttons); the
/// answered form dims to history, marks the chosen option, and drops the
/// tap targets.
struct ChatPendingRow: View {
    let interaction: PendingInteraction
    /// The effective answer (local choice or the transcript's own record);
    /// non-nil renders the answered form.
    let answer: String?
    let choose: (PendingInteraction.Option) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    private var isAnswered: Bool { answer != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                isAnswered ? "Answered" : "Waiting for your answer",
                systemImage: isAnswered ? "checkmark.circle" : "questionmark.circle"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isAnswered ? Color.secondary : Color.orange)
            ChatBlockText(interaction.question, style: .assistant)
            if !interaction.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(interaction.options, id: \.label) { option in
                        optionButton(option)
                    }
                }
            }
        }
        .padding(12)
        .background(
            .orange.opacity(
                isAnswered ? ChatWash.pendingAnswered(isDark: isDark)
                    : ChatWash.pending(isDark: isDark)),
            in: RoundedRectangle(cornerRadius: 10))
        .opacity(isAnswered ? 0.6 : 1)
    }

    /// One option: a full-width rounded button while the question blocks,
    /// a dimmed marked line once answered. Descriptions (omp's `ask`
    /// options carry them) ride as secondary text inside the target.
    @ViewBuilder
    private func optionButton(_ option: PendingInteraction.Option) -> some View {
        if isAnswered {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(
                    systemName: option.label == answer
                        ? "checkmark.circle.fill" : "circle"
                )
                .imageScale(.small)
                .foregroundStyle(option.label == answer ? .orange : .secondary)
                optionText(option)
            }
        } else {
            Button {
                choose(option)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let description = option.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("Answer: \(option.label)")
        }
    }

    @ViewBuilder
    private func optionText(_ option: PendingInteraction.Option) -> some View {
        Text(option.label)
            .font(.subheadline)
            .strikethrough(false)
        if let description = option.description {
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Linkified chat text (openers)

/// The linkified form of `ChatBlockText`: same layout, with the
/// rendered markdown's links routed through `OpenRouterCore` via the
/// `\.openURL` environment — the same interception seam the attributed-
/// string path used (MarkdownUI renders links as `Text` with `.link`
/// attributes, which SwiftUI hands to that environment's action).
/// Output/thinking stay plain monospace exactly as `ChatBlockText`
/// renders them (no markdown, no routing of terminal paths).
struct ChatLinkText: View {
    let text: String
    let style: ChatBlockText.Style
    let router: OpenRouterCore?

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
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
                    linkedBody
                }
                .padding(.vertical, 4)
                .padding(.trailing, 4)
                .background(.tint.opacity(ChatWash.turn(isDark: isDark)))
            } else {
                linkedBody
            }
        }
        .font(style.font)
        .foregroundStyle(style.color)
        .frame(maxWidth: .infinity, alignment: alignment)
        .environment(
            \.openURL,
            OpenURLAction { url in
                guard let router else { return .discarded }
                router.open(ChatLinkTarget(linkURL: url))
                return .handled
            })
    }

    /// Prose renders rich markdown with the detector's path targets
    /// rewritten in (bare URLs and http(s) constructs are MarkdownUI's
    /// own); output/thinking stay plain monospace with text selection —
    /// terminal paths open via the share flow, not tap accidents.
    @ViewBuilder private var linkedBody: some View {
        if style.mono {
            Text(text)
                .textSelection(.enabled)
        } else {
            ChatMarkdownView(markdown: ChatMarkdownText(text).rewritten)
        }
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

// MARK: - Previews (dark + light)

/// One representative of every row kind, at a level that shows them all
/// (L2 pairs results, L3 adds thinking) — the fixture both appearance
/// previews render.
private enum ChatRowPreviewFixture {
    static var content: ChatContent {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, blocks: [
                .text("Ship the checkout fix — run the **targeted** tests first."),
            ]),
            ChatMessage(role: .assistant, blocks: [
                .thinking(
                    "The user wants the fix shipped. Read the failing test first, then run the suite."),
                .toolCall(ToolCall(
                    id: "preview-call-1", name: "read",
                    arguments: .object([
                        "path": .string("CheckoutView.swift"),
                    ]))),
                .text(
                    "The retry logic drops the cart because `PaymentCoordinator` resets state on the *first* attempt. I'll preserve the cart across retries and re-run `CheckoutFlowTests`."),
            ]),
            ChatMessage(role: .assistant, blocks: [
                .text("All 18 tests pass. Ready to commit when you are."),
            ]),
        ]
        let results = [
            ToolResult(
                toolCallId: "preview-call-1", toolName: "read",
                isError: false,
                content: "struct CheckoutView: View {\n    var body: some View {\n        Text(\"Checkout\")\n    }\n}"),
        ]
        let pending = [
            PendingInteraction(
                question: "Run the full CheckoutFlowTests suite before committing?",
                options: [
                    PendingInteraction.Option(
                        label: "Run the tests",
                        description: "About 40s; catches regressions before they land."),
                    PendingInteraction.Option(label: "Commit without tests"),
                ]),
            PendingInteraction(
                question: "Squash the two fixup commits before pushing?",
                options: [
                    PendingInteraction.Option(label: "Squash"),
                    PendingInteraction.Option(label: "Keep separate"),
                ],
                answer: "Squash"),
        ]
        return ChatContent(
            messages: messages, toolResults: results, pending: pending)
    }

    static var rows: [ChatRow] {
        ChatFiltering.visibleRows(
            messages: content.messages, toolResults: content.toolResults,
            pending: content.pending, level: .l3)
    }
}

/// The full row gallery on the chat's own plain background, so a wash or
/// material that fails to read in one appearance is visible at a glance.
private struct ChatRowsPreviewSurface: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(ChatRowPreviewFixture.rows) { row in
                    LinkifiedChatRow(row: row, router: OpenRouterCore())
                        .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 10)
        }
    }
}

#Preview("Chat rows — dark") {
    ChatRowsPreviewSurface()
        .preferredColorScheme(.dark)
}

#Preview("Chat rows — light") {
    ChatRowsPreviewSurface()
        .preferredColorScheme(.light)
}

/// The strip + switcher (the chat's only chrome) over a `.bar` background,
/// as the screen presents it.
#Preview("Chat status strip — dark") {
    ChatStatusStrip(
        agentName: "checkout", state: .blocked, level: .l2,
        changeLevel: { _ in })
        .padding()
        .background(.bar)
        .preferredColorScheme(.dark)
}

#Preview("Chat status strip — light") {
    ChatStatusStrip(
        agentName: "checkout", state: .blocked, level: .l2,
        changeLevel: { _ in })
        .padding()
        .background(.bar)
        .preferredColorScheme(.light)
}
