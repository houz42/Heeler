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

/// The pending-messages region. Pure presentation: entries + action
/// seams in, honest rows out. Nil seams keep affordances visible but
/// inert (previews, unwired surfaces).
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

    /// Whether any entry is hidden locally (drives the recovery row).
    private var hiddenCount: Int { entries.count { $0.isHidden } }

    var body: some View {
        // The label + rows; never rendered at all when nothing is
        // pending (the region is absence, not an empty frame).
        let visible = entries.filter { !$0.isHidden }
        if !visible.isEmpty || hiddenCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Label("Pending messages", systemImage: "tray.full")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                ForEach(visible) { entry in
                    pendingRow(entry)
                }
                if hiddenCount > 0 {
                    recoveryRow(count: hiddenCount)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// One entry's row (seams bound to THIS entry), split out so the
    /// ForEach body stays a single call within the type-check budget.
    /// The seam bindings are plain typed locals: nested closure
    /// literals inside an argument list stall Swift's type-checker.
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
