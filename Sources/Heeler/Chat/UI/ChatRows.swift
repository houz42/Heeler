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
        case .notice(_, _, let text, let level):
            // Item 19: the quiet system row — never dropped; the wash
            // strengthens with the level.
            ChatNoticeRow(text: text, level: level)
        case .resolvedAsk(let ask):
            ChatResolvedAskRow(ask: ask)
        case .image:
            // Handled by the screen (fetch seam + reader); the plain
            // row renderer never sees it.
            EmptyView()
        }
    }
}

/// A system/structural notice rendered as a distinct quiet row (item
/// 19): secondary text, small caps label, level-tinted wash — never
/// raw markup, never dropped.
private struct ChatNoticeRow: View {
    let text: String
    let level: String

    private var label: String {
        switch level {
        case "error": "Error"
        case "warning": "Warning"
        default: "Notice"
        }
    }

    private var tint: Color {
        switch level {
        case "error": .red
        case "warning": .orange
        default: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundStyle(tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                ChatBlockText(text, style: .output)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(text)")
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

/// A resolved ask's quiet record in the transcript flow: 'You
/// answered: <labels>' (this client's answer) or the honest outcome
/// note (answered in the agent's terminal / cancelled / expired).
/// Full-width, secondary, checkmark-led — it is conversation history,
/// not an alert; it never carries interactive affordances.
struct ChatResolvedAskRow: View {
    let ask: ResolvedAsk

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(ask.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
                markdown: ChatMarkdownText(text).rendered,
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
    /// Resolves image-attachment refs (the host read seam) so a SENT
    /// image renders as a preview tile in the user's own bubble, not
    /// as its staged path string. Nil = no preview (the path text
    /// stays visible — honest, never a broken tile).
    var imageFetch: ((String) async throws -> Data)? = nil
    /// Opens a preview tile's full reader.
    var openImageReader: ((ChatImageRef) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    private var isUser: Bool { bubble.role == .user }

    var body: some View {
        let split: SentAttachmentText.Split? = isUser
            ? SentAttachmentText.split(bubble.text) : nil
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            // A SENT image renders as a preview tile, not its staged
            // path string: the leading path tokens of a user message
            // (the §D send composes them ahead of the prose) become
            // the small-square gallery; the prose keeps the remaining
            // text. Tapping the tile opens the full reader.
            if isUser, let openImageReader, let split,
                !split.imageRefs.isEmpty
            {
                let imageRefs = split.imageRefs.filter {
                    $0.mimeType != "file"
                }
                let fileRefs = split.imageRefs.filter {
                    $0.mimeType == "file"
                }
                if !imageRefs.isEmpty {
                    ChatTranscriptImageGallery(
                        images: imageRefs,
                        fetch: imageFetch,
                        openReader: openImageReader)
                }
                ForEach(fileRefs) { fileRef in
                    SentFileChip(fileRef: fileRef) {
                        openImageReader(fileRef)
                    }
                }
            }
            Group {
                if selectable {
                    Text(bubble.text)
                        .font(.system(.subheadline))
                        .foregroundStyle(isUser ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                } else {
                    ChatLinkText(
                        split?.prose ?? bubble.text,
                        style: .assistant,
                        router: router,
                        foregroundOverride: nil)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(fill, in: ChatBubbleSilhouette.shape(userSide: isUser))
    }

    /// The approved preview's --bubble values: #eaf0ec light /
    /// #31483b dark — soft green-neutral paper, NOT vivid blue.
    private static let userBubbleTint = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x31 / 255, green: 0x48 / 255, blue: 0x3B / 255, alpha: 1)
            : UIColor(red: 0xEA / 255, green: 0xF0 / 255, blue: 0xEC / 255, alpha: 1)
    })

    private var fill: some ShapeStyle {
        isUser
            ? AnyShapeStyle(Self.userBubbleTint)
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
    /// Sent-image preview + sent-file chip seams (the user's own
    /// bubble renders attachments, not path strings).
    var imageFetch: ((String) async throws -> Data)? = nil
    var openImageReader: ((ChatImageRef) -> Void)? = nil

    @State private var rowWidth: CGFloat = 320
    private var isUser: Bool { bubble.role == .user }

    var body: some View {
        ChatBubbleBody(
            bubble: bubble,
            router: router,
            imageFetch: imageFetch,
            openImageReader: openImageReader)
            .frame(maxWidth: rowWidth * 0.78, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _, w in
                rowWidth = w
            }
            .onTapGesture { onToggleActions?() }
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
    /// e.g. "Meadow · omp" — from the real runtime identity, never guessed.
    var authorLabel: String
    /// Short tap toggles the inline actions rail. Long press stays
    /// native text selection.
    var onToggleActions: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(authorLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            ChatLinkText(bubble.text, style: .assistant, router: router)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onTapGesture { onToggleActions?() }
    }
}

// MARK: - Local helpful reactions

/// Per-message "Helpful" marks, persisted on-device (UserDefaults).
/// There is NO feedback contract yet — this is a real LOCAL reaction
/// (survives restarts, honestly local), never presented as sent.
struct ChatHelpfulReactions {
    private let key = "chat.helpfulMessages.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func ids() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    func contains(_ id: String) -> Bool {
        ids().contains(id)
    }

    /// Toggles; returns the new state.
    @discardableResult
    func toggle(_ id: String) -> Bool {
        var set = ids()
        let nowOn: Bool
        if set.contains(id) {
            set.remove(id)
            nowOn = false
        } else {
            set.insert(id)
            nowOn = true
        }
        defaults.set(Array(set), forKey: key)
        return nowOn
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
    /// Quote needs the composer (a place for the quoted draft to
    /// land); read-only transcripts keep Copy only.
    var supportsQuote: Bool
    /// True when THIS message is already marked helpful locally — the
    /// button shows the actual state, never a fake success.
    var isMarkedHelpful: Bool
    var copy: () -> Void
    var quote: () -> Void
    var helpful: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            railButton("Copy", icon: "doc.on.doc", action: copy)
            if supportsQuote {
                railButton("Quote", icon: "text.quote", action: quote)
            }
            if isAssistant {
                railButton(
                    isMarkedHelpful ? "Helpful ✓" : "Helpful",
                    icon: "hand.thumbsup",
                    action: helpful)
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

/// Ink that clears the ACCENT FILL in both appearances: white on the
/// dark light-mode accent (#22644D, 7.0:1), the prototype's dark ink
/// #17251D on the light mint dark accent (#9ACFB2, 9.06:1) — white on
/// #9ACFB2 measures 1.76:1 (illegible; v2 accent review finding). The
/// prototype pairs its dark accent with `--primary` #17251d
/// (`.dark .primary,.dark .send{color:#17251d}`). One production
/// definition: the pending card's Confirm renders this, and the
/// contrast regression test resolves the SAME token — reverting the
/// foreground to white would fail the test.
enum ChatAccentInk {
    static let color = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x17 / 255, green: 0x25 / 255, blue: 0x1D / 255, alpha: 1)
            : .white
    })
}

/// The redesigned pending-question card: border + paper + eyebrow with
/// step dots + question + quiet instruction + adaptive options. Short
/// labels flow compactly; descriptive labels stack full-width.
struct AgentPendingQuestionCard: View {
    let interaction: PendingInteraction
    /// 1-based current question index.
    var step: Int
    var stepCount: Int
    var isMultiSelect: Bool = false
    var selectedOptionIds: Set<String> = []
    var choose: (String) -> Void
    var confirmMultiSelect: (() -> Void)? = nil
    /// Back to the previous question (choices preserved by the owner).
    var back: (() -> Void)? = nil
    /// Cancel the whole ask (small secondary; the real
    /// cancelInteraction path — nil hides it honestly).
    var cancel: (() -> Void)? = nil
    /// A failed/stale submit or cancel — surfaced HERE; choices are
    /// retained so the user can retry or Back.
    var errorMessage: String? = nil

    private var questions: [PendingAskQuestion] {
        interaction.effectiveQuestions
    }
    private var currentQuestion: PendingAskQuestion? {
        let list = questions
        guard step >= 1, step <= list.count else { return list.first }
        return list[step - 1]
    }

    private var accent: Color {
        Color.accentColor
    }
    /// Ink that clears the ACCENT FILL in both appearances — see
    /// `ChatAccentInk` (the one production definition, also what the
    /// contrast regression test resolves).
    private var onAccentInk: Color {
        ChatAccentInk.color
    }
    /// The selected option's fill: the soft accent wash with PRIMARY
    /// ink (the prototype's `.option.selected` — background var(--soft),
    /// never white-on-accent).
    private var accentWash: Color {
        Color("AccentWash")
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
            Text(currentQuestion?.text ?? interaction.question)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if isMultiSelect {
                Text("Select one or more, then confirm.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            optionsView
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if step > 1 || cancel != nil {
                HStack {
                    if let back, step > 1 {
                        Button(action: back) {
                            Label("Back", systemImage: "chevron.left")
                                .font(.footnote)
                        }
                        .accessibilityLabel("Previous question")
                    }
                    Spacer(minLength: 0)
                    if let cancel {
                        Button(action: cancel) {
                            Text("Cancel")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Cancel this question")
                    }
                }
            }
            if isMultiSelect, let confirmMultiSelect {
                Button(action: confirmMultiSelect) {
                    Text("Confirm")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(accent, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(onAccentInk)
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
        let options = currentQuestion?.options ?? []
        if options.allSatisfy({ $0.label.count <= 24 }) {
            OptionFlowLayout(spacing: 8) {
                ForEach(options) { option in
                    optionButton(label: option.label, id: option.id)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(options) { option in
                    optionButton(label: option.label, id: option.id, fullWidth: true)
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
                .background(selected ? accentWash : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? accent : optionBorder, lineWidth: 1))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Answer: \(label)")
    }
}

// MARK: - L1 Work inspector

/// The tapped Work summary's payload: every call in the run with its
/// paired result (nil while still running).
struct ChatWorkCallDetail: Identifiable {
    struct Entry: Identifiable {
        let id = UUID().uuidString
        let name: String
        let result: ToolResult?
    }
    let id: String
    let entries: [Entry]
}

/// The inspector sheet: compact COLLAPSED rows, one per call, each
/// expandable to its result/diff. A nil result is HONEST — the row
/// says "No recorded result" (an unavailable/unknown state, never a
/// fake "Running" that a historical call would render forever).
struct ChatWorkInspectorSheet: View {
    let detail: ChatWorkCallDetail

    var body: some View {
        NavigationStack {
            List(detail.entries) { entry in
                WorkInspectorRow(entry: entry)
            }
            .navigationTitle(
                "Work · \(detail.entries.count) call\(detail.entries.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private struct WorkInspectorRow: View {
        let entry: ChatWorkCallDetail.Entry
        @State private var expanded = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: entry.result == nil
                            ? "questionmark.circle" : (entry.result?.isError == true
                                ? "exclamationmark.triangle" : "checkmark.circle"))
                            .foregroundStyle(
                                entry.result?.isError == true ? .red : .secondary)
                        Text(entry.name)
                            .font(.system(.footnote, design: .monospaced))
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Call \(entry.name), \(entry.result == nil ? "no recorded result" : "result available"), \(expanded ? "collapse" : "expand")")
                if expanded {
                    if let result = entry.result {
                        ChatResultBody(result: result)
                    } else {
                        Text("No recorded result for this call.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Transcript image tiles + reader (§D fix 3)

/// One square gallery tile for an image block. Loads bytes through the
/// fetch seam on demand; without a seam (or on failure) renders an
/// honest unavailable tile — never a spinner pretending content.
struct ChatTranscriptImageTile: View {
    let image: ChatImageRef
    var fetch: ((String) async throws -> Data)?
    /// The square's side (56 in galleries, 96 standalone).
    var side: CGFloat = 96
    var openReader: () -> Void

    @State private var loadedImage: UIImage?
    @State private var failed = false

    var body: some View {
        Button(action: openReader) {
            Group {
                if let loadedImage {
                    Image(uiImage: loadedImage)
                        .resizable()
                        .scaledToFill()
                } else if failed {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.subheadline)
                        Text("Unavailable")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "photo")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .task {
            guard loadedImage == nil, !failed, let fetch else { return }
            do {
                let data = try await fetch(image.ref)
                loadedImage = UIImage(data: data)
                if loadedImage == nil { failed = true }
            } catch {
                failed = true
            }
        }
        .accessibilityLabel("Image attachment, opens full view")
    }
}

/// The full-size reader for a transcript image: loads via the fetch
/// seam, pinch-zooms (ZoomableImageView).
struct ChatTranscriptImageReader: View {
    let image: ChatImageRef
    var fetch: ((String) async throws -> Data)?

    @State private var loadedImage: UIImage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let loadedImage {
                    ZoomableImageView(image: loadedImage)
                } else if failed {
                    ContentUnavailableView(
                        "Image unavailable",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text(
                            "The image could not be loaded (\(image.ref))."))
                } else {
                    ProgressView("Loading image…")
                }
            }
            .navigationTitle("Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Close image viewer")
                }
            }
        }
        .task {
            guard let fetch else {
                failed = true
                return
            }
            do {
                let data = try await fetch(image.ref)
                loadedImage = UIImage(data: data)
                if loadedImage == nil { failed = true }
            } catch {
                failed = true
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
}

/// One message's images as a single-row gallery: MEASURED capacity
/// (tile+gap math, boundary-correct), the +N tile opens the collection
/// sheet where EVERY image is reachable.
struct ChatTranscriptImageGallery: View {
    let images: [ChatImageRef]
    var fetch: ((String) async throws -> Data)?
    var openReader: (ChatImageRef) -> Void

    @State private var showsCollection = false

    private static let tile: CGFloat = 56
    private static let gap: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let fits = Self.fits(width: geo.size.width - 24)
            let hasOverflow = images.count > fits
            // fits can be 0 at constrained widths; never negative.
            let visible = hasOverflow ? max(fits - 1, 0) : images.count
            HStack(spacing: Self.gap) {
                ForEach(images.prefix(visible)) { image in
                    ChatTranscriptImageTile(
                        image: image, fetch: fetch, side: Self.tile)
                    { openReader(image) }
                }
                if hasOverflow {
                    Button {
                        showsCollection = true
                    } label: {
                        Text("+\(images.count - visible)")
                            .font(.footnote.weight(.medium))
                            .frame(width: Self.tile, height: Self.tile)
                            .background(
                                Color.secondary.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(images.count - visible) more images, opens all")
                }
            }
        }
        .frame(height: Self.tile)
        .padding(.horizontal, 12)
        .sheet(isPresented: $showsCollection) {
            NavigationStack {
                List(images) { image in
                    HStack(spacing: 12) {
                        ChatTranscriptImageTile(
                            image: image, fetch: fetch, side: 44)
                        { openReader(image) }
                        Text("Image \(image.ref)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { openReader(image) }
                }
                .navigationTitle("Images")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    static func fits(width: CGFloat) -> Int {
        guard width >= tile else { return 0 }
        return Int((width + gap) / (tile + gap))
    }
}


/// Splits a SENT user message into its attachment path tokens and the
/// prose remainder — the §D send composes attachment paths as leading
/// standalone lines ahead of the message text (the agent reads the
/// paths; the UI renders them as preview tiles instead). Pure static —
/// testable. Image extensions only: a staged file path stays in the
/// prose (no tile without image bytes).
enum SentAttachmentText {
    struct Split: Equatable {
        var imageRefs: [ChatImageRef]
        var prose: String
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff",
    ]

    static func split(_ text: String) -> Split? {
        // Reference lines may LEAD (bare image paths, the §D send) or
        // TRAIL (the @-file references after the prose — the
        // misclassification fix put prose first). Consume refs from
        // both edges; everything in the middle is the user's prose.
        let lines = text.components(separatedBy: "\n")

        func refIfAny(_ line: String) -> ChatImageRef? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let ext = Self.extensionOf(trimmed)
            if trimmed.hasPrefix("/"), imageExtensions.contains(ext) {
                return ChatImageRef(
                    ref: trimmed, mimeType: "image/\(ext)", byteLength: nil)
            }
            if trimmed.hasPrefix("@/") {
                return ChatImageRef(
                    ref: String(trimmed.dropFirst()),
                    mimeType: "file", byteLength: nil)
            }
            return nil
        }

        var start = 0
        var leadRefs: [ChatImageRef] = []
        while start < lines.count, let ref = refIfAny(lines[start]) {
            leadRefs.append(ref)
            start += 1
        }
        var end = lines.count
        var tailRefs: [ChatImageRef] = []
        while end > start, let ref = refIfAny(lines[end - 1]) {
            tailRefs.insert(ref, at: 0)
            end -= 1
        }
        let refs = leadRefs + tailRefs
        guard !refs.isEmpty else { return nil }
        let prose = lines[start..<end]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Split(imageRefs: refs, prose: prose)
    }

    /// The lowercased extension of `path`'s last path component
    /// ("" when none).
    private static func extensionOf(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}

/// A sent file reference rendered as its NAME (never the raw path),
/// opening the in-app file reader — the design's contract: every file
/// opens in a preview before any external app.
struct SentFileChip: View {
    let fileRef: ChatImageRef
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .font(.caption)
                Text(fileName)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 32, alignment: .center)
            .background(
                Color.secondary.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open file \(fileName)")
    }

    private var fileName: String {
        fileRef.ref.split(separator: "/").last.map(String.init) ?? fileRef.ref
    }
}
