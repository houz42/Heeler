import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The "Pending messages" region (v3 design: "Submitted-draft stack and
// delivery state"): a SEPARATE, labeled region after loaded history and
// before the composer — never falsely timestamp-interleaved with the
// committed transcript. Entries render in LOCAL SUBMISSION ORDER with
// their honest delivery state from the design's table; pending state is
// conveyed by border/caption/icon with normal-contrast text (never
// low-opacity body text), using the app's adaptive Meadow tokens.

/// One pending entry's VIEW MODEL: the durable outbox entry plus the
/// display state the region derives (sent-timestamp formatting is the
/// view's; ownership of actions stays the surface owner's).
struct ChatPendingEntry: Identifiable, Equatable {
    let id: UUID
    let text: String
    let images: [AgentChatOutgoingImage]
    let ordinal: Int
    let status: AgentChatOutboxEntry.Status
    let isTransmitting: Bool
    let failureMessage: String?
    let isHidden: Bool

    init(_ entry: AgentChatOutboxEntry) {
        id = entry.id
        text = entry.text
        images = entry.images
        ordinal = entry.ordinal
        status = entry.status
        isTransmitting = entry.isTransmitting
        failureMessage = entry.failureMessage
        isHidden = entry.isHidden
    }

    init(
        id: UUID = UUID(), text: String,
        images: [AgentChatOutgoingImage] = [], ordinal: Int = 0,
        status: AgentChatOutboxEntry.Status, isTransmitting: Bool = false,
        failureMessage: String? = nil, isHidden: Bool = false
    ) {
        self.id = id
        self.text = text
        self.images = images
        self.ordinal = ordinal
        self.status = status
        self.isTransmitting = isTransmitting
        self.failureMessage = failureMessage
        self.isHidden = isHidden
    }
}

/// The region's fold decisions as a PURE function (unit-testable
/// without a view): the collapsed summary's counts, the unfolded
/// preview slice, and the attention set. The fold itself is view
/// state (collapsed by default, user-toggled only) — this model only
/// DERIVES from the entries, never mutates anything.
enum ChatPendingFoldModel: Sendable {
    static let previewLimit = 3

    /// The region's visible (not-locally-hidden) entries.
    static func visible(from entries: [ChatPendingEntry]) -> [ChatPendingEntry] {
        entries.filter { !$0.isHidden }
    }

    /// The summary row's count: "Pending N".
    static func summaryCount(from entries: [ChatPendingEntry]) -> Int {
        visible(from: entries).count
    }

    /// Entries needing the user's decision (the attention count —
    /// rejected / outcome-unknown are the actionable states).
    static func attentionCount(from entries: [ChatPendingEntry]) -> Int {
        visible(from: entries).count {
            $0.status == .rejected || $0.status == .outcomeUnknown
        }
    }

    /// The unfolded preview slice: at most `previewLimit`, never the
    /// whole stack inline.
    static func previews(from entries: [ChatPendingEntry]) -> [ChatPendingEntry] {
        Array(visible(from: entries).prefix(previewLimit))
    }

    /// Entries past the preview limit (the sheet owns them).
    static func overflowCount(from entries: [ChatPendingEntry]) -> Int {
        max(0, visible(from: entries).count - previewLimit)
    }

    /// Whether the region mounts at all: any visible entry, or any
    /// hidden one (the recovery row's home).
    static func isPresent(entries: [ChatPendingEntry]) -> Bool {
        !visible(from: entries).isEmpty || entries.contains { $0.isHidden }
    }

    /// The one-line preview text for an entry: the entry's own text
    /// (ellipsized by the view), an image-only entry its count.
    static func previewText(for entry: ChatPendingEntry) -> String {
        if entry.text.isEmpty {
            let n = entry.images.count
            return n == 1 ? "Image" : "\(n) images"
        }
        return entry.text
    }
}

/// The pending-messages region (v3 design amendment: COMPACT FOLDABLE).
/// COLLAPSED BY DEFAULT: one 44pt summary row — "Pending N" with an
/// attention count (rejected / outcome-unknown entries — the states
/// that need the user). Unfolded: at most THREE one-line previews,
/// then "N more / View all" (the full stack lives in a SHEET, never
/// inline). Per-entry detail rows (full text, images, state, actions)
/// render in the sheet; previews are one line only.
///
/// Fold invariants (design amendment): NEVER show the whole stack
/// inline; never auto-expand on arrivals (new entries change the
/// count, nothing else); folding never mutates delivery state (the
/// fold is pure presentation — entries, statuses, and action seams
/// are read as-is); the composer is never overwritten. Pure
/// presentation: entries + action seams in, honest rows out. Nil
/// seams keep affordances visible but inert (previews, unwired
/// surfaces).
struct ChatPendingRegionView: View {
    /// Local-submission-ordered entries, hidden ones excluded by the
    /// owner (the recovery seam re-shows them).
    let entries: [ChatPendingEntry]
    /// Duplicate-safe retry of a REJECTED entry (same requestKey).
    var retry: ((UUID) -> Void)? = nil
    /// The explicit may-duplicate re-send of an OUTCOME-UNKNOWN entry.
    var resend: ((UUID) -> Void)? = nil
    /// Display-only local removal (never a retraction); the recovery
    /// row re-shows everything hidden.
    var hide: ((UUID) -> Void)? = nil
    var showHidden: (() -> Void)? = nil
    /// Returns a rejected entry's text to the composer for editing.
    var edit: ((ChatPendingEntry) -> Void)? = nil

    /// COLLAPSED BY DEFAULT (design amendment) — the reader opening a
    /// chat sees the transcript, not the outbox. Only the user's tap
    /// expands; arrival-count changes NEVER auto-expand.
    @State private var isExpanded = false
    /// The View-all sheet.
    @State private var showsAllSheet = false

    private var visible: [ChatPendingEntry] {
        ChatPendingFoldModel.visible(from: entries)
    }
    private var attentionEntries: [ChatPendingEntry] {
        visible.filter {
            $0.status == .rejected || $0.status == .outcomeUnknown
        }
    }
    private var hiddenCount: Int { entries.count { $0.isHidden } }
    private var previews: [ChatPendingEntry] {
        ChatPendingFoldModel.previews(from: entries)
    }
    private var overflowCount: Int {
        ChatPendingFoldModel.overflowCount(from: entries)
    }

    var body: some View {
        // The region never renders at all when nothing is pending —
        // absence, not an empty frame.
        if ChatPendingFoldModel.isPresent(entries: entries) {
            VStack(alignment: .leading, spacing: 8) {
                if isExpanded {
                    expandedRegion
                } else {
                    summaryRow
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .sheet(isPresented: $showsAllSheet) {
                ChatPendingAllSheet(
                    entries: visible,
                    hiddenCount: hiddenCount,
                    retry: retry,
                    resend: resend,
                    hide: hide,
                    showHidden: { showHidden?() },
                    edit: edit)
            }
        }
    }

    /// COLLAPSED: the one 44pt row — "Pending N" + attention count.
    /// Tap unfolds (never auto); the chevron mirrors the state.
    private var summaryRow: some View {
        Button {
            withAnimation(.snappy) { isExpanded = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "tray.full")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Pending \(visible.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                if !attentionEntries.isEmpty {
                    Label(
                        "\(attentionEntries.count) need attention",
                        systemImage: "exclamationmark.circle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Pending messages: \(visible.count)"
            + (attentionEntries.isEmpty
                ? "" : ", \(attentionEntries.count) need attention"))
        .accessibilityHint("Shows your pending messages")
    }

    /// UNFOLDED: label + at most three one-line previews + the overflow
    /// affordance + collapse. The full stack is NEVER inline — beyond
    /// the previews it lives in the View-all sheet.
    private var expandedRegion: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The region label row doubles as the collapse control
            // (same 44pt band; the chevron mirrors the state).
            Button {
                withAnimation(.snappy) { isExpanded = false }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Pending \(visible.count)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !attentionEntries.isEmpty {
                        Text("\(attentionEntries.count) need attention")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Pending messages: \(visible.count), folded")
            .accessibilityHint("Hides the pending previews")
            ForEach(previews) { entry in
                ChatPendingPreviewRow(entry: entry)
                    .padding(.horizontal, 12)
            }
            if overflowCount > 0 {
                overflowRow
            }
            if hiddenCount > 0 {
                recoveryRow(count: hiddenCount)
            }
        }
    }

    /// The overflow affordance: the sheet owns everything past the
    /// previews — per-entry detail with the state's actions. Shown
    /// while unfolded (the collapsed summary is the other entry).
    private var overflowRow: some View {
        Button {
            showsAllSheet = true
        } label: {
            Text("View all \(visible.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "View all \(visible.count) pending messages")
        .accessibilityHint("Opens the full pending list")
    }

    /// One entry's FULL row (the sheet's per-entry detail), seams bound
    /// to THIS entry. The seam bindings are plain typed locals: nested
    /// closure literals inside an argument list stall the type-checker.
    private func pendingRow(_ entry: ChatPendingEntry) -> some View {
        let retryAction: (() -> Void)? = retry.map { action in
            { action(entry.id) }
        }
        let resendAction: (() -> Void)? = resend.map { action in
            { action(entry.id) }
        }
        let hideAction: (() -> Void)? = hide.map { action in
            { action(entry.id) }
        }
        let editAction: ((ChatPendingEntry) -> Void)? = edit.map { action in
            { _ in action(entry) }
        }
        return ChatPendingEntryRow(
            entry: entry,
            retry: retryAction,
            resend: resendAction,
            hide: hideAction,
            edit: editAction)
            .padding(.horizontal, 12)
    }

    /// The recovery affordance: hidden entries are NOT gone (hiding is
    /// display-only; the design's warning rides the hide confirmation
    /// on the entry row, this row restores).
    private func recoveryRow(count: Int) -> some View {
        Button {
            showHidden?()
        } label: {
            Label(
                "Show \(count) hidden message\(count == 1 ? "" : "s")",
                systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Restores locally hidden pending messages")
    }
}

/// One pending entry: a draft-OUTLINE bubble (bordered, not filled like
/// a committed send) with normal-contrast text, a leading state icon
/// and caption from the design's state table, and the state's allowed
/// actions. Trailing-aligned like a user send; the outline + caption is
/// the pending signal — never low-opacity text.
struct ChatPendingEntryRow: View {
    let entry: ChatPendingEntry
    var retry: (() -> Void)?
    var resend: (() -> Void)?
    var hide: (() -> Void)?
    var edit: ((ChatPendingEntry) -> Void)?

    /// The design's state table: caption + icon per status.
    private var caption: (text: String, icon: String) {
        switch entry.status {
        case .locallyQueued:
            return entry.isTransmitting
                ? ("Sending", "paperplane")
                : ("Queued", "clock")
        case .accepted:
            return ("Awaiting agent", "clock")
        case .rejected:
            return ("Not delivered", "exclamationmark.circle")
        case .outcomeUnknown:
            return ("Delivery unknown", "questionmark.circle")
        case .committed:
            return ("Sent", "checkmark.circle")
        }
    }

    private var accent: Color { .accentColor }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: caption.icon)
                        .font(.caption)
                        .foregroundStyle(iconColor)
                        .accessibilityHidden(true)
                    if !entry.text.isEmpty {
                        Text(entry.text)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: 480, alignment: .leading)
                if !entry.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(
                            Array(entry.images.enumerated()), id: \.offset
                        ) { _, image in
                            pendingImageTile(image)
                        }
                    }
                }
                // The state caption + the failure copy (both
                // normal-contrast; the caption is the status line).
                HStack(spacing: 6) {
                    Text(caption.text)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let failure = entry.failureMessage {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background, in: ChatBubbleSilhouette.shape(userSide: true))
            .overlay {
                ChatBubbleSilhouette.shape(userSide: true)
                    .strokeBorder(accent.opacity(0.55), lineWidth: 1.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    /// The allowed actions per the design's state table.
    @ViewBuilder
    private var actions: some View {
        let acts = allowedActions
        if !acts.isEmpty {
            HStack(spacing: 14) {
                if acts.contains(.retry) {
                    actionButton("Retry", isDestructive: false) { retry?() }
                }
                if acts.contains(.resend) {
                    // The EXPLICIT warning copy — never bare "retry":
                    // the re-send MAY DUPLICATE.
                    actionButton("Send again — may duplicate", isDestructive: false) {
                        resend?()
                    }
                }
                if acts.contains(.edit) {
                    actionButton("Edit", isDestructive: false) { edit?(entry) }
                }
                if acts.contains(.copy) {
                    actionButton("Copy", isDestructive: false) {
                        ChatBubbleCopy.perform(entry.text)
                    }
                }
                if acts.contains(.hide) {
                    actionButton("Hide", isDestructive: false) { hide?() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct Action: OptionSet {
        let rawValue: Int
        static let retry = Action(rawValue: 1 << 0)
        static let resend = Action(rawValue: 1 << 1)
        static let edit = Action(rawValue: 1 << 2)
        static let copy = Action(rawValue: 1 << 3)
        static let hide = Action(rawValue: 1 << 4)
    }

    /// Rejected: error + Edit/Retry/Copy (retry only for definitive
    /// nonacceptance — which rejected IS). Outcome unknown: "Delivery
    /// unknown", Check status, explicit may-duplicate re-send; NEVER
    /// auto-resubmitted (the region's resend seam is the only path).
    /// Locally queued / accepted / committed: no actions (cancel is not
    /// offered — the host cannot prove never-dispatched once the wire
    /// took it, and "Hide locally is not cancellation").
    private var allowedActions: Action {
        switch entry.status {
        case .rejected:
            var acts: Action = [.retry, .copy]
            if edit != nil { acts.insert(.edit) }
            if hide != nil { acts.insert(.hide) }
            return acts
        case .outcomeUnknown:
            var acts: Action = [.copy]
            if resend != nil { acts.insert(.resend) }
            if hide != nil { acts.insert(.hide) }
            return acts
        case .locallyQueued, .accepted, .committed:
            return []
        }
    }

    private var iconColor: Color {
        switch entry.status {
        case .rejected: .orange
        case .outcomeUnknown: .orange
        default: accent
        }
    }

    /// Pending images: inline bytes draw directly; a broker ref (a
    /// re-send after a blob upload landed) shows the photo glyph —
    /// honest unavailable is a later fetch seam, never a guess.
    @ViewBuilder
    private func pendingImageTile(_ image: AgentChatOutgoingImage) -> some View {
        Group {
            if let data = image.data, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityLabel("Attached image")
    }

    private func actionButton(
        _ title: String, isDestructive: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isDestructive ? .red : accent)
        }
        .buttonStyle(.plain)
    }

    private var accessibilitySummary: String {
        var parts = ["Pending message"]
        parts.append(caption.text)
        if let failure = entry.failureMessage { parts.append(failure) }
        return parts.joined(separator: ", ")
    }
}

/// One unfolded preview: a ONE-LINE row (status glyph + single-line
/// text) — the design amendment's "max three one-line previews". The
/// full entry (text, images, actions) is the SHEET's per-entry detail,
/// never this row.
struct ChatPendingPreviewRow: View {
    let entry: ChatPendingEntry

    private var glyph: (icon: String, tint: Color) {
        switch entry.status {
        case .locallyQueued:
            return entry.isTransmitting
                ? ("paperplane", Color.accentColor) : ("clock", Color.accentColor)
        case .accepted:
            return ("clock", Color.accentColor)
        case .rejected:
            return ("exclamationmark.circle", Color.orange)
        case .outcomeUnknown:
            return ("questionmark.circle", Color.orange)
        case .committed:
            return ("checkmark.circle", Color.accentColor)
        }
    }

    /// The one-line preview text (the fold model's derivation).
    private var previewText: String {
        ChatPendingFoldModel.previewText(for: entry)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph.icon)
                .font(.caption)
                .foregroundStyle(glyph.tint)
            Text(previewText)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pending message, \(previewText)")
    }
}

/// The View-all sheet: the FULL pending stack (never inline — the
/// design amendment's overflow home) as per-entry detail rows — the
/// complete ChatPendingEntryRow with each state's allowed actions —
/// plus the hidden-recovery row. Entries live in local submission
/// order; commits that happen while the sheet is open simply remove
/// their rows (the sheet is a live projection of the region; folding
/// never mutated anything).
struct ChatPendingAllSheet: View {
    let entries: [ChatPendingEntry]
    let hiddenCount: Int
    var retry: ((UUID) -> Void)? = nil
    var resend: ((UUID) -> Void)? = nil
    var hide: ((UUID) -> Void)? = nil
    var showHidden: (() -> Void)? = nil
    var edit: ((ChatPendingEntry) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        detailRow(entry)
                    }
                    if hiddenCount > 0 {
                        Button {
                            showHidden?()
                        } label: {
                            Label(
                                "Show \(hiddenCount) hidden message"
                                    + (hiddenCount == 1 ? "" : "s"),
                                systemImage: "eye")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(
                            "Restores locally hidden pending messages")
                    }
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Pending messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// One per-entry DETAIL: the complete row (full text, images,
    /// state caption, actions) — the sheet's job per the design
    /// amendment. Typed-local seam bindings (the type-checker rule).
    private func detailRow(_ entry: ChatPendingEntry) -> some View {
        let retryAction: (() -> Void)? = retry.map { action in
            { action(entry.id) }
        }
        let resendAction: (() -> Void)? = resend.map { action in
            { action(entry.id) }
        }
        let hideAction: (() -> Void)? = hide.map { action in
            { action(entry.id) }
        }
        let editAction: ((ChatPendingEntry) -> Void)? = edit.map { action in
            { _ in action(entry) }
        }
        return ChatPendingEntryRow(
            entry: entry,
            retry: retryAction,
            resend: resendAction,
            hide: hideAction,
            edit: editAction)
            .padding(.horizontal, 12)
    }
}
