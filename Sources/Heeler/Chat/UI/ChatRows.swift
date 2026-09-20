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
/// edge.
struct ChatPendingRow: View {
    let interaction: PendingInteraction
    let choose: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

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
        .background(
            .orange.opacity(ChatWash.pending(isDark: isDark)),
            in: RoundedRectangle(cornerRadius: 10))
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
    /// Overrides the style's text color when non-nil (iMessage user
    /// bubbles: saturated blue fill needs white text).
    var foregroundOverride: Color? = nil

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    init(
        _ text: String, style: ChatBlockText.Style, router: OpenRouterCore?,
        foregroundOverride: Color? = nil
    ) {
        self.text = text
        self.style = style
        self.router = router
        self.foregroundOverride = foregroundOverride
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
        .foregroundStyle(foregroundOverride ?? style.color)
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
                .foregroundStyle(foregroundOverride ?? style.color)
        } else {
            ChatMarkdownView(
                markdown: ChatMarkdownText(text).rewritten,
                textColor: foregroundOverride)
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

// MARK: - Bubbles (per-message affordances)

/// The iMessage (iOS 17+) bubble silhouette: rounded corners everywhere
/// (~18pt) except ONE near-square corner (~4pt) at the speaker's bottom
/// side — bottom-left for agent bubbles, bottom-right for user bubbles.
/// The tightened asymmetric corner replaced the tail in modern iMessage;
/// UnevenRoundedRectangle does it with no custom path to get wrong.
enum ChatBubbleSilhouette {
    static let cornerRadius: CGFloat = 18
    static let tightenedRadius: CGFloat = 4

    /// The per-corner radii for one speaker's bubble.
    static func radii(userSide: Bool) -> RectangleCornerRadii {
        RectangleCornerRadii(
            topLeading: cornerRadius,
            bottomLeading: userSide ? cornerRadius : tightenedRadius,
            bottomTrailing: userSide ? tightenedRadius : cornerRadius,
            topTrailing: cornerRadius)
    }

    static func shape(userSide: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: radii(userSide: userSide))
    }
}

/// The bubble interior both presentations share: the message's text in
/// the iMessage-style silhouette — one markdown document (a bubble's
/// rows all belong to one message), agent gray or user blue by speaker,
/// tightened corner at the speaker's bottom side. `selectable` swaps the
/// markdown for plain selectable text (the Select affordance): MarkdownUI's
/// view tree does not support UIKit drag-selection.
struct ChatBubbleBody: View {
    let bubble: ChatBubble
    let router: OpenRouterCore
    var selectable: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    private var isUser: Bool { bubble.role == .user }

    var body: some View {
        Group {
            if selectable {
                Text(bubble.text)
                    .font(.system(.subheadline))
                    .foregroundStyle(isUser ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
            } else {
                ChatLinkText(
                    bubble.text,
                    style: .assistant,
                    router: router,
                    // iMessage outgoing convention: saturated blue fill,
                    // white text (the markdown body inherits the color).
                    foregroundOverride: isUser ? .white : nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(fill, in: ChatBubbleSilhouette.shape(userSide: isUser))
    }

    private var fill: some ShapeStyle {
        isUser
            ? AnyShapeStyle(Color.blue)
            : AnyShapeStyle(.fill.tertiary)
    }
}

/// One conversation bubble in the transcript: the message's visible text
/// run as one iMessage-style unit — agent prose leading-aligned in a gray
/// bubble with the tail at bottom-left, user prose trailing-aligned in an
/// accent-tinted bubble with the tail at bottom-right, capped at ~78% of
/// the row width. Long-press hands the bubble to the focus layer; while
/// focused the in-place copy hides (the focus layer's lifted copy is the
/// message, so nothing duplicates behind the dim).
struct ChatBubbleView: View {
    let bubble: ChatBubble
    let router: OpenRouterCore
    /// Short tap toggles the inline actions rail (final interaction
    /// spec). Long press is NOT attached — it stays native text
    /// selection.
    var onToggleActions: (() -> Void)? = nil

    @State private var rowWidth: CGFloat = 320
    private var isUser: Bool { bubble.role == .user }

    var body: some View {
        ChatBubbleBody(bubble: bubble, router: router)
            .frame(maxWidth: rowWidth * 0.78, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _, w in
                rowWidth = w
            }
            .onTapGesture { onToggleActions?() }
    }
}

/// The iMessage long-press focus state: the transcript blurs and dims
/// behind a light veil, the selected bubble lifts above it with the
/// Tapback pill near-kissing above (reactions only) and the action menu
/// card below (Quote / Copy / Select rows). Tapping the veil dismisses.
/// Reactions deliver as the emoji plus a block-quoted reference to this
/// message; Quote prefills the composer with the quoted draft (caret
/// after the quote); Copy puts the plain text on the pasteboard; Select
/// swaps the lifted bubble to selectable plain text.
struct ChatBubbleFocusLayer: View {
    let bubble: ChatBubble
    let router: OpenRouterCore
    /// Sends one quick reaction's composed message. Nil hides the pill.
    var react: ((String) -> Void)? = nil
    /// Prefills the composer with the quoted text. Nil hides Quote.
    var quote: ((String) -> Void)? = nil
    /// Puts the text on the pasteboard. Nil hides Copy.
    var copy: ((String) -> Void)? = nil
    let dismiss: () -> Void

    @State private var selectsText = false
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    private var isUser: Bool { bubble.role == .user }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // The veil covers edge to edge (its own ignore of the
                // safe areas); the content column respects them, so the
                // pill and menu sit inside the reachable screen.
                veil
                VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                    reactionPill
                    // The lifted bubble clamps to the space the pill and
                    // menu leave, and scrolls when it is taller than
                    // that — so the pill stays pinned under the top
                    // inset and the menu above the bottom, reachable
                    // regardless of message height (iMessage behavior).
                    ScrollView {
                        ChatBubbleBody(
                            bubble: bubble, router: router,
                            selectable: selectsText)
                            .frame(
                                maxWidth: geo.size.width * 0.78,
                                alignment: .leading)
                            .scaleEffect(1.03)
                            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: .infinity)
                    actionMenu
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var veil: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(
                Rectangle().fill(
                    Color(white: isDark ? 0 : 1)
                        .opacity(isDark ? 0.55 : 0.35)))
            .ignoresSafeArea()
            .onTapGesture(perform: dismiss)
    }

    /// iMessage's Tapback pill: only the reactions, generous glyph
    /// circles on a fully-rounded capsule, near-kissing above the bubble.
    private var reactionPill: some View {
        HStack(spacing: 10) {
            ForEach(ChatReaction.allCases, id: \.rawValue) { reaction in
                Button {
                    react?(reaction.message(for: bubble.text))
                    dismiss()
                } label: {
                    Text(reaction.rawValue)
                        .font(.system(.title3))
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(react == nil)
                .accessibilityLabel(reaction.accessibilityLabel)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    /// iMessage's text-action menu: Quote / Copy / Select as context-menu
    /// rows (SF-symbol icon left, label right) in a compact card sized to
    /// its rows — never the full transcript width — below the bubble,
    /// its edge flush with the bubble's (leading under agent bubbles,
    /// trailing under user bubbles, via the VStack's alignment).
    private var actionMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuRow("text.quote", label: "Quote") {
                quote?(bubble.text)
                dismiss()
            }
            .disabled(quote == nil)
            menuRow("doc.on.doc", label: "Copy") {
                copy?(bubble.text)
                dismiss()
            }
            .disabled(copy == nil)
            menuRow("textformat", label: "Select") {
                selectsText = true
            }
        }
        .frame(width: 220)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    private func menuRow(
        _ systemImage: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 24)
                Text(label)
                    .font(.system(.body))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
                options: ["Run the tests", "Commit without tests"]),
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

// MARK: - Assistant article render (conversation redesign)
//
// Design contract (approved prototype, verbatim): ASSISTANT messages are
// NOT bubbles — full-width text article, no background, no border; small
// author line (11pt, weight 650, accent) then the answer (15pt,
// line-height 1.65). USER messages keep the compact right bubble.
// Affordances (long-press pill/menu) still apply to assistant content —
// article-ness is the render, not the interactions.

struct ChatAssistantArticleView: View {
    let bubble: ChatBubble
    let router: OpenRouterCore
    /// e.g. "Heeler · omp" — from the real runtime identity, never guessed.
    var authorLabel: String
    /// Short tap toggles the inline actions rail. Long press stays
    /// native text selection.
    var onToggleActions: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(authorLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(
                    red: 0x22 / 255.0, green: 0x64 / 255.0, blue: 0x4D / 255.0))
            ChatLinkText(bubble.text, style: .assistant, router: router)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
        .onTapGesture { onToggleActions?() }
    }
}

// MARK: - Message actions rail (final interaction spec)

/// The inline Copy/Quote/Helpful rail toggled under a selected message
/// by a SHORT TAP. One rail open at a time; outside tap dismisses; long
/// press is reserved for native text selection. Copy/Quote carry the
/// message's PLAIN text (no author lines, file labels, or other
/// chrome); Helpful is an honest stub — no feedback contract exists yet,
/// so it confirms locally and sends nothing.
struct ChatMessageActionsRail: View {
    var isAssistant: Bool
    var copy: () -> Void
    var quote: () -> Void
    var helpful: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            railButton("Copy", icon: "doc.on.doc", action: copy)
            railButton("Quote", icon: "text.quote", action: quote)
            if isAssistant {
                railButton("Helpful", icon: "hand.thumbsup", action: helpful)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions for selected message")
    }

    private func railButton(
        _ title: String, icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(title).font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(uiColor: .label).opacity(0.8))
        .accessibilityLabel(title)
    }
}

// MARK: - Pending question card (conversation redesign)

private struct OptionFlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }
    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            if x > bounds.minX { x += spacing }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private func optionIsCompact(_ label: String) -> Bool {
    label.count <= 24 && !label.contains("\n")
}

/// The redesigned pending-question card: border + paper + eyebrow with
/// step dots + question + quiet instruction + adaptive options. Short
/// labels flow compactly; descriptive labels stack full-width.
struct AgentPendingQuestionCard: View {
    let interaction: PendingInteraction
    var step: Int
    var stepCount: Int
    var isMultiSelect: Bool = false
    var selectedOptionIds: Set<String> = []
    var choose: (String) -> Void
    var confirmMultiSelect: (() -> Void)? = nil

    private var accent: Color {
        Color(red: 0x22 / 255.0, green: 0x64 / 255.0, blue: 0x4D / 255.0)
    }
    private var cardBorder: Color {
        Color(red: 0xC4 / 255.0, green: 0xD5 / 255.0, blue: 0xCB / 255.0)
    }
    private var optionBorder: Color {
        Color(red: 0xCA / 255.0, green: 0xD5 / 255.0, blue: 0xCD / 255.0)
    }

    var body: some View {
        // Tightened card (refinement): compressed header, gaps, and
        // question (body sizes unchanged; only chrome whitespace
        // shrank). Options keep the 44 pt floor.
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Your input needed · \(step) of \(stepCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    ForEach(0..<max(stepCount, 1), id: \.self) { index in
                        Circle()
                            .fill(index < step ? accent : Color.secondary.opacity(0.25))
                            .frame(width: 4, height: 4)
                    }
                }
            }
            Text(interaction.question)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if isMultiSelect {
                Text("Select one or more, then confirm.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            optionsView
            if isMultiSelect, let confirmMultiSelect {
                Button(action: confirmMultiSelect) {
                    Text("Confirm")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(accent, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(.white)
                }
                .disabled(selectedOptionIds.isEmpty)
                .accessibilityLabel("Confirm answers")
            }
        }
        .padding(12)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(cardBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var optionsView: some View {
        if interaction.options.allSatisfy(optionIsCompact) {
            OptionFlowLayout(spacing: 8) {
                ForEach(Array(interaction.options.enumerated()), id: \.offset) { pair in
                    optionButton(label: pair.element, id: "\(pair.offset)")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(interaction.options.enumerated()), id: \.offset) { pair in
                    optionButton(label: pair.element, id: "\(pair.offset)", fullWidth: true)
                }
            }
        }
    }

    private func optionButton(label: String, id: String, fullWidth: Bool = false) -> some View {
        let selected = isMultiSelect && selectedOptionIds.contains(id)
        return Button {
            choose(id)
        } label: {
            Text(label)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 11)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44, alignment: .leading)
                .background(selected ? accent : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(optionBorder, lineWidth: 1))
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Answer: \(label)")
    }
}
