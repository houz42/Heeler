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
            // The plain row renderer (previews) keeps the card
            // read-only: the real submit seam lives in ChatScreen.
            ChatInteractionCard(
                interaction: interaction, submit: { _ in })
        case .notice(_, _, let text, let level):
            // Item 19: the quiet system row — never dropped; the wash
            // strengthens with the level.
            ChatNoticeRow(text: text, level: level)
        case .specialSection(let section):
            // Level-dependent initial state is the screen's call; the
            // plain row renderer (previews) keeps the chip collapsed.
            ChatSpecialSectionRow(section: section)
        case .resolvedAsk(let ask):
            ChatResolvedAskCard(ask: ask)
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
        case "resend": "Not Delivered?"
        default: "Notice"
        }
    }

    private var tint: Color {
        switch level {
        case "error": .red
        case "warning": .orange
        case "resend": .orange
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


// MARK: - Special sections (system notices & IRC)

/// A `<system-notice>`/`<irc>` section: chrome, not conversation, so
/// it renders as a SHORT SUMMARY chip — a capsule with the kind's
/// label and a one-line excerpt — never the full body inline. Tap
/// toggles the full body below the chip; `initiallyExpanded` is set
/// by the screen from the detail level (L3 opens the body, lower
/// levels keep the chip collapsed). The accent (green) carries the
/// section identity: icon + label + the capsule's accent wash, the
/// same quiet accent-bar language the user-turn rail and pending
/// card speak. The body is terminal-ish output — plain monospace
/// via `ChatBlockText(.output)`, never markdown (a fenced block
/// inside a notice is data, not markup).
struct ChatSpecialSectionRow: View {
    let section: ChatSpecialSection
    /// True = the full body renders below the chip (the screen's
    /// level wiring: L3 starts expanded, lower levels collapsed).
    var initiallyExpanded: Bool = false

    @State private var expanded: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    init(section: ChatSpecialSection, initiallyExpanded: Bool = false) {
        self.section = section
        self.initiallyExpanded = initiallyExpanded
        self._expanded = State(initialValue: initiallyExpanded)
    }

    private var accent: Color { .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: section.kind.icon)
                    .imageScale(.small)
                    .foregroundStyle(accent)
                Text(section.kind.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)
                    .fixedSize()
                Text(section.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(
                    systemName: expanded
                        ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                accent.opacity(isDark ? 0.16 : 0.07),
                in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    expanded.toggle()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(section.kind.label): \(section.summary)")
            .accessibilityHint(
                expanded ? "Collapses the full text" : "Expands the full text")

            if expanded {
                // Accent bar rail + the verbatim body: the same
                // accent-bar shape the user-turn rail uses, so the
                // expanded section still reads as chrome.
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accent)
                        .frame(width: 3)
                    ChatBlockText(section.body, style: .output)
                }
                .padding(.vertical, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
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
    /// HUG-CONTENT sizing (v3 own-message bubbles): forwards to
    /// `ChatMarkdownView` so rich prose lays out at intrinsic width
    /// inside a capped proposal instead of filling it — the caller's
    /// `frame(maxWidth:)` carries the wrap cap.
    var hugsContent: Bool = false

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    init(
        _ text: String, style: ChatBlockText.Style, router: OpenRouterCore?,
        foregroundOverride: Color? = nil, hugsContent: Bool = false
    ) {
        self.text = text
        self.style = style
        self.router = router
        self.foregroundOverride = foregroundOverride
        self.hugsContent = hugsContent
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
        // HUG-CONTENT: no fill-frame — the text keeps its intrinsic
        // width under the caller's capped proposal (the bubble hugs
        // the content). Every other consumer keeps the original
        // full-width fill.
        .frame(
            maxWidth: hugsContent ? nil : .infinity, alignment: alignment)
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
                textColor: foregroundOverride,
                hugsContent: hugsContent)
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
    /// Review gap 2: a failed send's retry affordance. Non-nil makes a
    /// FAILED-echo error notice row tappable (retry the send); nil keeps
    /// the row inert (previews, unwired surfaces).
    var onRetry: (() -> Void)? = nil
    /// The pane's detail level: L3 starts special-section chips
    /// expanded (the reader asked for everything); lower levels keep
    /// them collapsed.
    var detailLevel: DetailLevel = .l2

    init(
        row: ChatRow, router: OpenRouterCore,
        onRetry: (() -> Void)? = nil, detailLevel: DetailLevel = .l2
    ) {
        self.row = row
        self.router = router
        self.onRetry = onRetry
        self.detailLevel = detailLevel
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
        case .specialSection(let section):
            ChatSpecialSectionRow(
                section: section,
                initiallyExpanded: detailLevel >= .l3)
        case .notice(_, _, _, let level)
        where (level == "error" || level == "resend") && onRetry != nil:
            // Re-review round 4, finding 3: the AX label names the
            // real action. "error" = the broker answered NO — a
            // duplicate-safe retry. "resend" = acceptance UNKNOWN —
            // the re-send MAY DUPLICATE (never labeled "retry").
            let hint = level == "resend"
                ? "Sends the message again — it may arrive twice"
                : "Retries the failed send"
            Button {
                onRetry?()
            } label: {
                ChatRowView(row: row)
            }
            .buttonStyle(.plain)
            .accessibilityHint(hint)
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
    /// Internal (not private): the v3 content-sized own-bubble path
    /// (`ChatBubbleView`) reuses the SAME tint for its hugged bubble.
    static let userBubbleTint = Color(UIColor { traits in
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

/// v3 own-message bubble WIDTH POLICY (pure, unit-pinned): outgoing
/// bubbles HUG content — the visible bubble never stretches past its
/// content, and is capped at
/// `min(0.85 × available transcript width, 560pt)`.
/// `transcriptWidth` is the width the row itself may use (the chat's
/// full-width row, inside the transcript's horizontal insets); the
/// 0.85 factor and the 560pt absolute cap are the design doc's initial
/// tokens. The cap is a MAXIMUM, never a forced width: content smaller
/// than the cap stays at its own size.
enum ChatUserBubbleSizing {
    /// Bubble padding: 12pt horizontal / 8pt vertical (design token).
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 8
    /// The absolute bubble-width cap (design token).
    static let absoluteCap: CGFloat = 560
    /// The fraction of the available transcript width one own-message
    /// bubble may span (design token).
    static let transcriptFraction: CGFloat = 0.85

    /// The maximum VISIBLE bubble width for one own message, given the
    /// width its row can use.
    static func maxVisibleBubbleWidth(transcriptWidth: CGFloat) -> CGFloat {
        min(transcriptWidth * transcriptFraction, absoluteCap)
    }

    /// The LAYOUT WIDTH to propose to the bubble's content: the visible
    /// cap PLUS the horizontal padding, so a filled-long-prose bubble's
    /// text area spans exactly the visible maximum.
    static func proposedContentWidth(transcriptWidth: CGFloat) -> CGFloat {
        maxVisibleBubbleWidth(transcriptWidth: transcriptWidth)
            + 2 * horizontalPadding
    }
}

/// HUG-CONTENT single-pass layout: proposes `min(row proposal, cap)` to
/// its single subview and reports EXACTLY the subview's size — no
/// fixedSize/nil-proposal dance (which would lay prose out at its
/// longest unwrapped line and overflow the cap). One capped proposal:
/// content that fits keeps its intrinsic width, content that would
/// exceed the cap wraps at exactly the cap.
private struct HugContentLayout: Layout {
    /// The proposal cap (the padded, visible bubble's max width).
    var maxWidth: CGFloat

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        let cap = min(proposal.width ?? maxWidth, maxWidth)
        return ProposedViewSize(width: cap, height: proposal.height)
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(capped(proposal))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            proposal: capped(proposal))
    }
}

/// The hug-content wrapper that turns a content view into a
/// trailing-aligned own-message bubble. The bubble's visible
/// background is applied to the CONTENT's intrinsic frame (v3:
/// outgoing bubbles hug content — an emoji/one-word bubble stays
/// small; long prose wraps at `min(0.85 × transcript, 560pt)`),
/// inside a full-width trailing-aligned row that never stretches the
/// bubble.
///
/// Layout contract: natively-hugging content (plain Text, galleries,
/// chips) keeps its intrinsic width under the capped proposal; rich
/// markdown needs help — `ChatMarkdownView` carries a
/// `frame(maxWidth: .infinity)` fill that would span the proposal, so
/// the prose path renders it in `hugsContent` mode (no fill-frame →
/// intrinsic). The tap target is the VISIBLE bubble
/// (`contentShape` over the hugged silhouette) — the row's empty
/// leading space stays inert — while the row itself remains one
/// full-width element for accessibility, so VoiceOver users keep the
/// reachable message without the visual bubble being padded to full
/// width.
private struct HuggingBubble<Content: View>: View {
    /// The cap on the VISIBLE bubble's TOTAL width — content +
    /// padding + background together, the design's
    /// `min(0.85 × transcript, 560pt)`. NOT the inner content alone:
    /// the padded child IS the visible bubble, so the cap applies to
    /// it directly (no +2×padding arithmetic — that would let the
    /// visible bubble exceed the design cap by the padding).
    var maxWidth: CGFloat
    var shape: UnevenRoundedRectangle
    var fill: AnyShapeStyle
    var paddingH: CGFloat
    var paddingV: CGFloat
    var onTap: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        // The visible bubble: content + padding + background, sized
        // by ONE capped proposal (HugContentLayout) — the cap bounds
        // the TOTAL visible bubble (padding included), content within
        // the cap keeps its intrinsic width, content that would
        // exceed it wraps at exactly the cap.
        HugContentLayout(maxWidth: maxWidth) {
            content()
                .padding(.horizontal, paddingH)
                .padding(.vertical, paddingV)
                .background(fill, in: shape)
                // The tap target is the VISIBLE BUBBLE — the row's
                // empty leading space stays inert (v3: actions
                // without padding the bubble to full width).
                .contentShape(shape)
        }
        .onTapGesture { onTap?() }
        // Full-width trailing-aligned row: the ROW stretches so the
        // bubble parks at the trailing edge; the bubble itself stays
        // content-sized.
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}



/// One conversation bubble in the transcript. AGENT bubbles keep the
/// fill-width presentation (leading-aligned gray silhouette, capped at
/// ~78% of the row). USER bubbles are CONTENT-SIZED (v3): the bubble
/// hugs its content — intrinsic width for emoji/one-word/multiline/
/// image cases, long prose wrapping at `min(0.85 × transcript, 560pt)`
/// — trailing-aligned in a full-width row, with the background applied
/// to the intrinsic content, never the row. Short tap toggles the
/// inline actions rail on the VISIBLE bubble only (the row's empty
/// leading space stays inert).
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
        Group {
            if isUser {
                // v3 content-sized own bubble: hug-content layout with
                // the trailing-aligned full-width row.
                HuggingBubble(
                    maxWidth: ChatUserBubbleSizing.maxVisibleBubbleWidth(
                        transcriptWidth: rowWidth),
                    shape: ChatBubbleSilhouette.shape(userSide: true),
                    fill: AnyShapeStyle(ChatBubbleBody.userBubbleTint),
                    paddingH: ChatUserBubbleSizing.horizontalPadding,
                    paddingV: ChatUserBubbleSizing.verticalPadding,
                    onTap: onToggleActions)
                {
                    userBubbleContent
                }
            } else {
                ChatBubbleBody(
                    bubble: bubble,
                    router: router,
                    imageFetch: imageFetch,
                    openImageReader: openImageReader)
                    .frame(maxWidth: rowWidth * 0.78, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _, w in
            rowWidth = w
        }
    }

    /// The user bubble's content: attachments + prose, WITHOUT the
    /// padding/background (HuggingBubble applies those to the hugged
    /// frame).
    @ViewBuilder
    private var userBubbleContent: some View {
        let split = SentAttachmentText.split(bubble.text)
        VStack(alignment: .trailing, spacing: 6) {
            if let openImageReader, let split, !split.imageRefs.isEmpty {
                let imageRefs = split.imageRefs.filter { $0.mimeType != "file" }
                let fileRefs = split.imageRefs.filter { $0.mimeType == "file" }
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
            ChatLinkText(
                split?.prose ?? bubble.text,
                style: .assistant,
                router: router,
                foregroundOverride: nil,
                hugsContent: true)
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
                .text(
                    """
                    Before the reply, the harness injected two special \
                    sections into this turn:

                    <system-notice>Skill "shell-qa" is now active for this \
                    session. Commands run through the dev-box shell QA \
                    profile.</system-notice>

                    <irc><Main> The retry fix looks good from my side — \
                    go ahead and ship it when tests pass.
                    </irc>

                    With the sections extracted, this prose continues \
                    as ordinary conversation.
                    """),
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
        let resolvedAsks = [
            ResolvedAsk(
                id: "r-preview",
                questions: [
                    ResolvedAskQuestion(
                        id: "q", question: "Run the suite first?",
                        selectedOptions: [
                            .init(id: "o0", label: "Run the tests")])
                ],
                outcome: .youAnswered,
                questionText: "Run the suite first?"),
        ]
        return ChatContent(
            messages: messages, toolResults: results, pending: pending,
            resolvedAsks: resolvedAsks)
    }

    static var rows: [ChatRow] {
        ChatFiltering.visibleRows(
            messages: content.messages, toolResults: content.toolResults,
            pending: content.pending, resolvedAsks: content.resolvedAsks,
            level: .l3)
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

/// Options chip flow (internal): shared by the pending question card
/// and the Q/A cards — short labels flow compactly, long labels
/// stack full-width at the call site.
struct OptionFlowLayout: Layout {
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
            guard loadedImage == nil, !failed else { return }
            // Re-review round 4, finding 2: inline bytes (a locally-
            // sent image) render DIRECTLY — never through the fetch
            // seam (its ref is a local marker, not a fetchable id).
            if let inline = image.inlineData {
                loadedImage = UIImage(data: inline)
                if loadedImage == nil { failed = true }
                return
            }
            guard let fetch else { return }
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
            // Re-review round 4, finding 2: inline bytes first (a
            // locally-sent image renders from its real bytes).
            if let inline = image.inlineData {
                loadedImage = UIImage(data: inline)
                if loadedImage == nil { failed = true }
                return
            }
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
