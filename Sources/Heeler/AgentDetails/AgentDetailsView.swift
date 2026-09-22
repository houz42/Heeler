import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The Agent details inspector (v2 slice 1), per the approved design
// (agent-details-preview.js, revision compact-model-list). A sheet
// stack: root (context panel + facts) → Model picker → Confirm card /
// Compaction history → one record / Working directory.
//
// Honest-state rules baked into the layout: context usage comes from the
// agent (never transcript length), missing fields render "Not reported"
// states, model changes are agent-scoped and explicit (confirm card →
// pending on the agent → agent confirms or provider rejects; the old
// model is retained throughout; a working turn is never interrupted),
// and compaction history shows only what the agent recorded — no delete,
// no Compact now.

// MARK: - Entry (the shared three-dot menu)

/// The Agent details menu entry, shared by the Chat status strip and the
/// Terminal surface header (the design's three-dot entry point).
struct AgentDetailsMenuEntry: View {
    let title: String
    let onOpen: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            Label(title, systemImage: "info.circle")
        }
        .accessibilityHint("Opens the agent details inspector: context, model, working directory.")
    }
}

// MARK: - Root sheet

/// The Agent details root: context-window panel + the facts group.
struct AgentDetailsRootView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AgentDetailsStore
    let agentName: String
    let hostLabel: String
    /// The console's honest working directory (the snapshot's launch cwd)
    /// — the agent's own report arrives via telemetry and wins when both
    /// exist.
    let consoleCwd: String?
    let isOffline: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let notice = store.rejectionNotice {
                        AgentDetailsNotice(notice, style: .warning)
                            .onTapGesture { store.clearRejectionNotice() }
                    }
                    contextPanel
                    if isOffline {
                        AgentDetailsNotice(
                            "Offline. Showing cached details; changes are disabled.",
                            style: .neutral)
                    }
                    if store.isPendingModelChange {
                        AgentDetailsNotice(
                            "Model change awaiting confirmation. Current model remains unchanged.",
                            style: .neutral)
                    }
                    factsGroup
                    footNote
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Agent details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await store.refreshTelemetry() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(agentName).font(.subheadline.weight(.semibold))
            Text(hostLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Context panel

    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Context window").font(.subheadline.weight(.semibold))
                Spacer()
                Text(percentUsed ?? "Not reported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch (store.context, store.context?.contextWindow, store.context?.tokens) {
            case (.some(let context), .some(let window), .some(let tokens))
                where window > 0:
                VStack(alignment: .leading, spacing: 4) {
                    (Text(CompactTokenNumber.format(tokens))
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        + Text("  /  \(CompactTokenNumber.format(window)) tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary))
                    ProgressView(value: Double(tokens), total: Double(window))
                        .tint(.accentColor)
                    HStack {
                        Text(remaining)
                        Spacer()
                        Text(freshness)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            case (.some(let context), .some(let window), _) where window > 0:
                // The window is reported but the USED count is not: show
                // the window, with usage honestly unknown — never 0.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage not reported")
                        .font(.subheadline.weight(.semibold))
                    Text("Window: \(CompactTokenNumber.format(window)) tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(freshness)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            default:
                AgentDetailsNotice(
                    "This agent does not expose context usage. Transcript length is not a substitute.",
                    style: .neutral)
            }
            Text("Agent-reported usage, not lifetime tokens. Output reservation and model-specific limits may reduce usable space.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var percentUsed: String? {
        guard let context = store.context,
            let tokens = context.tokens,
            let window = context.contextWindow, window > 0
        else { return nil }
        return "\(Int((Double(tokens) / Double(window) * 100).rounded()))% used"
    }

    private var remaining: String {
        guard let context = store.context,
            let tokens = context.tokens,
            let window = context.contextWindow, window > tokens
        else { return "—" }
        return "\(CompactTokenNumber.format(window - tokens)) remaining"
    }

    private var freshness: String {
        switch (store.freshness, isOffline) {
        case (.unknown, _): return "Not reported"
        case (_, true): return "Last known · offline"
        case (.stale, _): return "Last known · refresh unavailable"
        case (.live, _): return "Updated on last response"
        }
    }

    // MARK: Facts

    private var factsGroup: some View {
        VStack(spacing: 0) {
            NavigationLink {
                AgentModelPickerView(store: store, isOffline: isOffline)
            } label: {
                AgentDetailsRow(
                    title: "Model",
                    subtitle: store.currentModel?.provider ?? nil,
                    value: store.currentModel.map { $0.displayName }
                        ?? "Not reported",
                    accessory: modelChangeAccessory)
            }
            Divider().padding(.leading, 16)
            let workdir = store.workingDirectory ?? consoleCwd
            NavigationLink {
                AgentWorkingDirectoryView(path: workdir)
            } label: {
                AgentDetailsRow(
                    title: "Working directory", subtitle: nil,
                    value: workdir.map { AgentDetailsRootView.shorten($0) }
                        ?? "Not reported",
                    accessory: .disclosure)
            }
            Divider().padding(.leading, 16)
            NavigationLink {
                AgentCompactionHistoryView(store: store)
            } label: {
                AgentDetailsRow(
                    title: "Compactions",
                    subtitle: latestCompactionLabel,
                    value: "\(store.compactions.count) recorded",
                    accessory: .disclosure)
            }
        }
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var modelChangeAccessory: AgentDetailsRow.Accessory {
        let gate = store.modelGate
        switch gate {
        case .allowed: return .disclosure
        default: return .disclosure
        }
    }

    private var latestCompactionLabel: String? {
        guard let latest = store.compactions.last, let time = latest.time
        else { return nil }
        return "Latest: \(time.formatted(date: .abbreviated, time: .shortened))"
    }

    private var footNote: some View {
        Group {
            switch store.modelGate {
            case .working:
                Text("Agent is working. Model changes are unavailable until the turn finishes.")
            case .unsupported:
                Text("Read-only adapter: model switching is not supported.")
            default:
                Text("Model changes apply only to this agent, after explicit confirmation.")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// The console's `~` shortening, shared with rows: only the account's
    /// conventional home is shortened; other paths print as reported.
    static func shorten(_ path: String) -> String {
        path
    }
}

// MARK: - Row

/// One fact row in the inspector's group card.
struct AgentDetailsRow: View {
    enum Accessory {
        case disclosure
        case plain(String)
    }

    let title: String
    let subtitle: String?
    let value: String
    var accessory: Accessory = .disclosure

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(accessoryLabel == nil ? .primary : .secondary)
                if let accessoryLabel {
                    Text(accessoryLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.secondary.opacity(0.5))
        }
        .padding(12)
        .contentShape(Rectangle())
    }

    private var accessoryLabel: String? {
        if case .plain(let text) = accessory { return text }
        return nil
    }
}

// MARK: - Notice

/// The inspector's notice callout (design: details-notice).
struct AgentDetailsNotice: View {
    enum Style {
        case neutral, warning
    }

    private let text: String
    private let style: Style

    init(_ text: String, style: Style = .neutral) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Label(
            text,
            systemImage: style == .warning
                ? "exclamationmark.triangle" : "info.circle")
            .font(.caption)
            .foregroundStyle(style == .warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                (style == .warning ? Color.orange.opacity(0.08) : Color.primary.opacity(0.04)),
                in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Model picker

/// The compact fuzzy model picker: search field + ~68pt rows carrying
/// name, ctx count, provider, price in/out, capabilities. Selection opens
/// the confirm card (typing never changes the model).
struct AgentModelPickerView: View {
    @Bindable var store: AgentDetailsStore
    let isOffline: Bool
    @State private var searchText = ""

    private var gate: AgentModelGate { store.modelGate }
    private var blocked: Bool { gate != .allowed }

    var body: some View {
        List {
            if let notice = gate.notice {
                Section {
                    AgentDetailsNotice(notice, style: .neutral)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                ForEach(matches) { model in
                    NavigationLink {
                        AgentModelConfirmView(store: store, picked: model, isOffline: isOffline)
                    } label: {
                        AgentModelRow(
                            model: model,
                            isCurrent: model.wireID == store.currentModel?.wireID,
                            contextUsed: store.context?.tokens,
                            disabled: blocked)
                    }
                }
            } footer: {
                Text("Fuzzy matches names, IDs and providers. Selecting a result opens details and confirmation; typing never changes the model. Prices are the provider's catalog rates, not bills or subscription prices.")
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search model or provider…")
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if store.models == nil { await store.loadModels() }
        }
    }

    private var matches: [AgentCatalogModel] {
        guard let models = store.models else { return [] }
        return AgentModelSearch.matches(query: searchText, models: models)
    }
}

/// One compact model row (~68pt, per the design's compact-model spec).
struct AgentModelRow: View {
    let model: AgentCatalogModel
    let isCurrent: Bool
    let contextUsed: Int?
    var disabled: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(context)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(model.provider)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(price)
                        .font(.caption2)
                        .foregroundStyle(Color(red: 0x22/255, green: 0x64/255, blue: 0x4D/255))
                }
                Text(capabilities)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if doesNotFit {
                    Label("Context exceeds window", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Image(systemName: isCurrent ? "checkmark" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    isCurrent
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(Color.secondary.opacity(0.5)))
        }
        .padding(.vertical, 4)
        .opacity(disabled ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(model.displayName), \(context), \(capabilities)")
    }

    private var context: String {
        model.contextWindow.map { "\(CompactTokenNumber.format($0)) ctx" } ?? "ctx unknown"
    }

    private var price: String {
        guard let cost = model.cost,
            let input = cost.input, let output = cost.output
        else { return "Price unknown" }
        return "$\(Self.priceString(input)) / $\(Self.priceString(output))"
    }

    static func priceString(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2g", value)
    }

    private var capabilities: String {
        let input: String
        if let kinds = model.input {
            input = kinds.contains("image") ? "Text + images" : "Text only"
        } else {
            input = "Input not reported"
        }
        let reasoning: String
        switch model.reasoning {
        case .some(true): reasoning = "Reasoning"
        case .some(false): reasoning = "No reasoning"
        case .none: reasoning = "Reasoning unknown"
        }
        return "\(input) · \(reasoning)"
    }

    private var doesNotFit: Bool {
        guard let used = contextUsed, let window = model.contextWindow
        else { return false }
        return window < used
    }
}

// MARK: - Confirm card

/// The explicit change card: full model details + old → new transition +
/// confirmation. The context-does-not-fit branch refuses (nothing is
/// trimmed automatically) and routes back.
struct AgentModelConfirmView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: AgentDetailsStore
    let picked: AgentCatalogModel
    let isOffline: Bool
    @State private var inFlight = false

    private var oldModel: AgentCatalogModel? { store.currentModel }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let notice = store.rejectionNotice {
                    AgentDetailsNotice(notice, style: .warning)
                        .onTapGesture { store.clearRejectionNotice() }
                }
                AgentModelDetailsCard(model: picked)
                if let old = oldModel {
                    transition(old: old, new: picked)
                } else {
                    AgentDetailsNotice(
                        "The agent has not reported its current model; the transition cannot be shown.",
                        style: .neutral)
                }
                if tooSmall {
                    Text("The last reported context exceeds this model's window. Nothing will be trimmed, compacted or discarded automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Use this model for the next request in Chat experience. Existing messages and your draft remain unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if tooSmall {
                    Button("Choose another model") { dismiss() }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        confirm()
                    } label: {
                        if inFlight {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Waiting for the agent…")
                            }
                        } else {
                            Text("Confirm change")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inFlight || store.modelGate != .allowed)
                    .accessibilityLabel("Confirm model change to \(picked.displayName)")
                }
                Text("Context fit must be revalidated by the agent; local last-known usage is advisory.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .navigationTitle(tooSmall ? "Context does not fit" : "Change model?")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var tooSmall: Bool {
        guard let used = store.context?.tokens, let window = picked.contextWindow
        else { return false }
        return window < used
    }

    private func confirm() {
        inFlight = true
        Task {
            _ = await store.confirmChange()
            inFlight = false
            // Dismiss ONLY on a RESOLVED outcome: confirmed (idle, no
            // notice) or explicitly rejected (idle + notice shown on the
            // root). A still-pending change keeps the card open — never
            // dismiss an unresolved pending as if it confirmed.
            if case .idle = store.modelChange.phase {
                if store.rejectionNotice == nil {
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private func transition(old: AgentCatalogModel, new: AgentCatalogModel) -> some View {
        VStack(spacing: 6) {
            Text(old.displayName).font(.subheadline)
            Image(systemName: "arrow.down").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(new.displayName).font(.subheadline.weight(.semibold))
                Text("\(new.provider) · \(new.contextWindow.map { CompactTokenNumber.format($0) } ?? "unknown") tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The full model-details card (selection view): every capability surface
/// the catalog reports, honestly.
struct AgentModelDetailsCard: View {
    let model: AgentCatalogModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model details")
                .font(.subheadline.weight(.semibold))
            rows
            Text("Rates are USD per 1M tokens where reported. Missing price is not \"free\".")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Provider / ID", "\(model.provider) / \(model.id)")
            row("Context window", model.contextWindow.map { "\(CompactTokenNumber.format($0)) tokens" } ?? "Not reported")
            row("Maximum output", model.maxTokens.map { "\(CompactTokenNumber.format($0)) tokens" } ?? "Not reported")
            row("Input", model.input?.joined(separator: ", ") ?? "Not reported")
            row(
                "Reasoning",
                model.reasoning == true ? "Supported"
                    : model.reasoning == false ? "Not supported" : "Not reported")
            row(
                "Tool calling",
                model.supportsTools == true ? "Supported"
                    : model.supportsTools == false ? "Not supported" : "Not reported")
            row(
                "Input / output",
                model.cost.flatMap { c in
                    pair(c.input, c.output).map { "$\(AgentModelRow.priceString($0)) / $\(AgentModelRow.priceString($1))" }
                } ?? "Unavailable")
            row(
                "Cache read / write",
                model.cost.flatMap { c in
                    pair(c.cacheRead, c.cacheWrite).map { "$\(AgentModelRow.priceString($0)) / $\(AgentModelRow.priceString($1))" }
                } ?? "Unavailable")
        }
    }

    /// Both sides must be reported for a price pair — one-sided prices
    /// render Unavailable rather than a half-invented rate.
    private func pair(_ a: Double?, _ b: Double?) -> (Double, Double)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Working directory

struct AgentWorkingDirectoryView: View {
    let path: String?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let path {
                    Text(path)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        UIPasteboard.general.string = path
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy path", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                } else {
                    AgentDetailsNotice(
                        "The working directory is not reported for this agent.",
                        style: .neutral)
                }
            }
            .padding(16)
        }
        .navigationTitle("Working directory")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Compaction history

struct AgentCompactionHistoryView: View {
    @Bindable var store: AgentDetailsStore

    var body: some View {
        List {
            switch (store.compactionsQueried, store.compactions.isEmpty) {
            case (false, _):
                Section {
                    AgentDetailsNotice(
                        "The compaction history has not been read yet for this agent.",
                        style: .neutral)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            case (true, true):
                Section {
                    AgentDetailsNotice(
                        "No compactions in the loaded history window for this agent.",
                        style: .neutral)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            default:
                Section {
                    ForEach(store.compactions.reversed()) { event in
                        NavigationLink {
                            AgentCompactionEventView(event: event)
                        } label: {
                            AgentCompactionRow(event: event)
                                .accessibilityIdentifier("compaction-row")
                        }
                    }
                } footer: {
                    Text("Context summaries reported by this agent. Not deleted chat messages. No Compact now action: history inspection is separate from modifying context.")
                }
            }
        }
        .navigationTitle("Compaction history")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AgentCompactionRow: View {
    let event: AgentCompactionEvent

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(time)
                    .font(.subheadline)
                Text(event.trigger ?? "Trigger not reported")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(numbers)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.secondary.opacity(0.5))
        }
        .accessibilityElement(children: .combine)
    }

    private var time: String {
        event.time?.formatted(date: .abbreviated, time: .shortened) ?? "Time not reported"
    }

    private var numbers: String {
        guard let before = event.tokensBefore, let after = event.tokensAfter
        else { return "Token counts unavailable" }
        return "\(CompactTokenNumber.format(before)) → \(CompactTokenNumber.format(after)) tokens"
    }
}

/// One compaction record: before/after comparison, the trigger, and the
/// actual retained summary when the agent reported one.
struct AgentCompactionEventView: View {
    let event: AgentCompactionEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(time) · \(event.trigger ?? "Trigger not reported")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let before = event.tokensBefore, let after = event.tokensAfter {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Before").font(.caption2).foregroundStyle(.secondary)
                            Text(CompactTokenNumber.format(before))
                                .font(.title3.weight(.semibold))
                        }
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("After").font(.caption2).foregroundStyle(.secondary)
                            Text(CompactTokenNumber.format(after))
                                .font(.title3.weight(.semibold))
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                    Text("Context reduced by \(CompactTokenNumber.format(before - after)) tokens. This is not a claim of billing savings.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    AgentDetailsNotice(
                        "This record does not include before/after token counts.",
                        style: .neutral)
                }
                if let summary = event.summary {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Summary retained by the agent")
                            .font(.subheadline.weight(.semibold))
                        ScrollView {
                            Text(summary)
                                .font(.caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 320)
                    }
                    .padding(12)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    AgentDetailsNotice(
                        "Summary text is unavailable. It must not be regenerated and presented as the original record.",
                        style: .neutral)
                }
                Text("Earlier conversation can remain in chat history even when it is no longer sent to the model. Undo is not assumed to be supported.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .navigationTitle("Context summarized")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var time: String {
        event.time?.formatted(date: .abbreviated, time: .shortened) ?? "Time not reported"
    }
}

#Preview("Agent details — ready") {
    AgentDetailsPreviewFixture.preview(mode: .ready)
}

#Preview("Agent details — unavailable") {
    AgentDetailsPreviewFixture.preview(mode: .unavailable)
}

/// Preview fixtures — real shapes, illustrative values only in DEBUG
/// previews (never shipped data paths).
enum AgentDetailsPreviewFixture {
    enum Mode { case ready, unavailable }

    @MainActor
    static func preview(mode: Mode) -> some View {
        let store = AgentDetailsStore(
            wire: .init(request: { _, _ in .object([:]) }, readItem: nil),
            telemetrySupported: mode == .ready,
            isAgentWorking: { false },
            isOffline: { false })
        if mode == .ready {
            store.seedFixture(
                context: .init(tokens: 86_400, contextWindow: 200_000),
                currentModel: AgentCatalogModel(
                    id: "balanced", provider: "example", name: "Balanced model",
                    contextWindow: 200_000, maxTokens: 32_000,
                    input: ["text", "image"], reasoning: true,
                    supportsTools: true,
                    cost: .init(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
                workingDirectory: "/home/developer/work/heeler",
                compactions: [
                    AgentCompactionEvent(
                        id: "c3", time: Date(),
                        trigger: "snapcompact",
                        tokensBefore: 171_200, tokensAfter: 58_300,
                        summary: "## Goal\nRedesign the agent conversation while preserving native runtime behavior."),
                ])
        }
        return AgentDetailsRootView(
            store: store, agentName: "Chat experience",
            hostLabel: "omp · Devbox · heeler",
            consoleCwd: "/home/developer/work/heeler",
            isOffline: false)
    }
}
