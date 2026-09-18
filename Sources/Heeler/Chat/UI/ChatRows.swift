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

/// The iMessage-style bubble silhouette: ~18pt corners with a small
/// curved tail nub hugging the bottom corner — bottom-left for agent
/// bubbles, bottom-right (mirrored) for user bubbles. The nub is a few
/// points tall and lands flush on the corner; content pads the bottom
/// so text never rides into it. The path is drawn clockwise from the
/// top edge, and the tail is inserted at whichever bottom corner the
/// traversal reaches LAST — so the closing edge never crosses the
/// shape (the mirrored user-side tail must not be drawn where the
/// traversal has already passed).
struct ChatBubbleShape: Shape {
    static let tailDepth: CGFloat = 5
    /// True when the tail sits at the bottom-right (user side).
    let userSide: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 18
        let tailRun: CGFloat = 12
        let bodyBottom = rect.maxY - Self.tailDepth
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: bodyBottom - radius))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: bodyBottom),
            control: CGPoint(x: rect.maxX, y: bodyBottom))

        if userSide {
            // Bottom-right tail: the traversal just rounded into the
            // bottom edge at the right corner, so the nub comes first.
            // It hugs the corner: a short run out, a tight curve that
            // dips `tailDepth` and lands back on the bottom edge.
            p.addQuadCurve(
                to: CGPoint(x: rect.maxX - tailRun, y: bodyBottom),
                control: CGPoint(
                    x: rect.maxX - tailRun * 0.3,
                    y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + radius, y: bodyBottom))
            p.addQuadCurve(
                to: CGPoint(x: rect.minX, y: bodyBottom - radius),
                control: CGPoint(x: rect.minX, y: bodyBottom))
        } else {
            // Bottom-left tail: the bottom edge runs left first, then
            // the nub hugs the left corner before the edge turns up.
            p.addLine(to: CGPoint(x: rect.minX + radius + tailRun, y: bodyBottom))
            p.addQuadCurve(
                to: CGPoint(x: rect.minX, y: bodyBottom - radius),
                control: CGPoint(x: rect.minX + tailRun * 0.3, y: rect.maxY))
        }

        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// The bubble interior both presentations share: the message's text in
/// the iMessage-style silhouette — one markdown document (a bubble's rows
/// all belong to one message), agent fill or user tint by speaker, tail
/// at the speaker's bottom corner. `selectable` swaps the markdown for
/// plain selectable text (the Select affordance): MarkdownUI's view tree
/// does not support UIKit drag-selection.
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
        .padding(.bottom, ChatBubbleShape.tailDepth)
        .background(fill, in: ChatBubbleShape(userSide: isUser))
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
    var isFocused: Bool = false
    var onLongPress: (() -> Void)? = nil

    @State private var rowWidth: CGFloat = 320
    private var isUser: Bool { bubble.role == .user }

    var body: some View {
        ChatBubbleBody(bubble: bubble, router: router)
            .frame(maxWidth: rowWidth * 0.78, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _, w in
                rowWidth = w
            }
            .opacity(isFocused ? 0 : 1)
            .onLongPressGesture { onLongPress?() }
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
                veil
                VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                    reactionPill
                    ChatBubbleBody(
                        bubble: bubble, router: router, selectable: selectsText)
                        .frame(
                            maxWidth: geo.size.width * 0.78, alignment: .leading)
                        .scaleEffect(1.03)
                        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                    actionMenu
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
    }

    /// The blurred, dimmed backdrop. A light veil in light mode (iMessage
    /// whites the background out), a dark one in dark mode. Taps dismiss.
    private var veil: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(
                Rectangle().fill(
                    Color(white: isDark ? 0 : 1)
                        .opacity(isDark ? 0.55 : 0.35)))
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
