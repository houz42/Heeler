import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// The + menu's prefix-mode chooser (v3, design doc "Compact composer"):
// selecting a mode from the + menu opens THIS — never a literal prefix
// inserted into the draft. Each mode resolves to structured intent:
// a chosen agent command is a catalog ID + arguments
// (``ComposerCommandSelection``), a mention is a resolved agent +
// message, a shell command goes to the companion scratch terminal.
// Cancel returns to exactly the original draft/caret/keyboard: the
// composer field is untouched for the sheet's whole lifetime.
//
// The literal-mode editors (command arguments, shell command) disable
// autocorrection/prediction per the writing-assistance policy —
// structured fields are literal; the ordinary chat field is not
// affected.

/// One sheet for all four + menu prefix modes, driven by the router's
/// `activeChooser`. The ChatScreen presents it; the router owns the
/// state and the execution.
struct ComposerChooserSheet: View {
    @Bindable var router: ComposerRouterStore
    /// The mode the + menu selected (the sheet's configuration).
    let mode: ComposerPrefixMode
    /// Dismisses the sheet (cancel or after a handled run).
    let onDismiss: () -> Void

    @State private var arguments = ""
    @State private var mentionMessage = ""
    @State private var shellCommand = ""
    @State private var selectedCatalogID: String?
    @State private var selectedAgent: String?
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            Group {
                // A rejected run keeps the sheet OPEN with its
                // reason visible here (the composer's own error row
                // is behind the sheet).
                if let error = router.routingError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                switch mode {
                case .slash: commandList
                case .tag: tagList
                case .mention: mentionForm
                case .bash: shellForm
                }
            }
            .navigationTitle(mode.menuTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // The design doc: Cancel returns to exactly
                        // the original draft/caret/keyboard — the
                        // composer field was never touched.
                        router.cancelChooser()
                        onDismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isRunning)
    }

    // MARK: - Agent command (/) — selection resolves to a catalog ID

    /// The command catalog: the agent's own commands first, then the
    /// client-local ones — the same table the typed `/` menu filters.
    /// Selecting a command with NO arguments runs it immediately;
    /// one WITH arguments opens the inline argument editor (a
    /// literal field, per the writing-assistance policy).
    private var commandList: some View {
        let catalog = router.commandCatalog()
        return List {
            if let selection = selectedCommand(catalog) {
                argumentEditor(for: selection)
            } else {
                ForEach(catalog) { command in
                    Button {
                        select(command: command)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.title)
                                .font(.subheadline.weight(.medium))
                                .fontDesign(.monospaced)
                                .foregroundStyle(.primary)
                            if let detail = command.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// A chosen command's inline argument editor: literal input (no
    /// autocorrection/prediction — structured fields disable them),
    /// Run executes the resolved selection through the router.
    private func argumentEditor(
        for command: ComposerSuggestion
    ) -> some View {
        Form {
            Section {
                LabeledContent("Command") {
                    Text(command.title)
                        .fontDesign(.monospaced)
                }
                if let usage = command.usage {
                    LabeledContent("Usage") {
                        Text(usage)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField(
                    "Arguments", text: $arguments,
                    axis: .vertical
                )
                .lineLimit(1...3)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            } footer: {
                Text(
                    "Runs /\(command.title) with these arguments. The "
                        + "command is delivered as a resolved catalog "
                        + "selection, not typed text.")
            }
            Section {
                Button {
                    runSelection(command: command)
                } label: {
                    if isRunning { ProgressView() } else { Text("Run") }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func selectedCommand(
        _ catalog: [ComposerSuggestion]
    ) -> ComposerSuggestion? {
        guard let selectedCatalogID else { return nil }
        return catalog.first { $0.id == selectedCatalogID }
    }

    private func select(command: ComposerSuggestion) {
        // A command with NO usage signature takes no arguments —
        // run it straight from the list; one with usage opens the
        // argument editor.
        if command.usage == nil {
            runSelection(command: command)
        } else {
            selectedCatalogID = command.id
        }
    }

    private func runSelection(command: ComposerSuggestion) {
        guard !isRunning else { return }
        isRunning = true
        let name = command.title
        let catalogID = command.id
        Task { @MainActor in
            defer { isRunning = false }
            let outcome = await router.runCommandSelection(
                ComposerCommandSelection(
                    catalogID: catalogID, name: name, arguments: arguments))
            if outcome != .rejected { onDismiss() }
            // A rejection keeps the sheet open; the router's
            // routingError names what went wrong.
        }
    }

    // MARK: - Filter/tag (#) — a client-side filter, never agent-bound

    /// The tag chooser: statuses, workspaces, and agents as filter
    /// values (the same suggestions the typed `#` menu filters).
    /// Selecting one applies the structured TagFilter — client
    /// filters are never transmitted to an agent.
    private var tagList: some View {
        let suggestions = router.tagCatalog()
        return List {
            Section {
                Text(
                    "Filters are client-side — they narrow the console's "
                        + "agent list, never the agent's view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(suggestions) { suggestion in
                Button {
                    applyTag(suggestion)
                } label: {
                    HStack {
                        Text(suggestion.title)
                            .fontDesign(.monospaced)
                        Spacer()
                        if let field = suggestion.detail {
                            Text(field)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func applyTag(_ suggestion: ComposerSuggestion) {
        router.applyTagSuggestion(suggestion)
        router.cancelChooser()
        onDismiss()
    }

    // MARK: - Mention (@) — resolved agent + message

    /// The mention chooser: the console's agent roster, then the
    /// message. Delivery resolves the agent ONCE from the chosen
    /// name — never re-guessing a name from prose.
    private var mentionForm: some View {
        let roster = router.agentRoster()
        return Form {
            Section {
                if roster.isEmpty {
                    Text(
                        "No agents to mention yet — open an agent first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(roster, id: \.self) { agent in
                    Button {
                        selectedAgent = agent
                    } label: {
                        HStack {
                            Text(agent)
                                .fontDesign(.monospaced)
                            Spacer()
                            if agent == selectedAgent {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Agent")
            }
            if selectedAgent != nil {
                Section {
                    TextField(
                        "Message", text: $mentionMessage, axis: .vertical
                    )
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    Button {
                        runMention()
                    } label: {
                        if isRunning { ProgressView() } else { Text("Send") }
                    }
                    .disabled(mentionMessage.isEmpty || isRunning)
                } header: {
                    Text("Message")
                }
            }
        }
    }

    private func runMention() {
        guard let selectedAgent, !isRunning else { return }
        isRunning = true
        Task { @MainActor in
            defer { isRunning = false }
            let outcome = await router.runMentionSelection(
                ComposerMentionSelection(
                    agentName: selectedAgent, message: mentionMessage))
            if outcome != .rejected { onDismiss() }
        }
    }

    // MARK: - Shell command (!) — companion terminal, literal input

    /// The shell editor: a literal command field (no
    /// autocorrection/prediction per the writing-assistance policy —
    /// shell input is ALWAYS literal). The command goes to the Host's
    /// companion scratch terminal, never the agent prompt.
    private var shellForm: some View {
        Form {
            Section {
                TextField(
                    "Command", text: $shellCommand, axis: .vertical
                )
                .lineLimit(1...3)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(runShell)
                Button {
                    runShell()
                } label: {
                    if isRunning { ProgressView() } else { Text("Run") }
                }
                .disabled(shellCommand.isEmpty || isRunning)
            } footer: {
                Text(
                    "Runs in the Host's companion shell. Output appears "
                        + "in the chat; the agent is never prompted.")
            }
        }
    }

    private func runShell() {
        let trimmed = shellCommand.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isRunning else { return }
        isRunning = true
        Task { @MainActor in
            defer { isRunning = false }
            let outcome = await router.runShellSelection(
                ComposerShellSelection(command: trimmed))
            if outcome != .rejected { onDismiss() }
        }
    }
}
