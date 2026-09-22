import SwiftUI

/// Add/edit form for a Host (handoff §E): clean labeled fields — display
/// name, NAMED connection routes (label + address per row), username/port,
/// an auth summary (no giant key blobs; the authorized_keys line is one
/// copyable disclosure), and advanced settings folded away. Editing focus
/// and typed values are preserved: route rows are keyed by their UUID, not
/// their text (see ``AdditionalAddressRow``).
struct HostFormView: View {
    let store: HostStore
    var editing: Host?
    var onSaved: ((Host) -> Void)?

    @State private var draft: HostDraft
    @State private var availableSessions: [HerdrSession] = []
    @State private var authorizedKeysLine: String?
    @State private var deviceKeySummary: String?
    @State private var didCopyKeyLine = false
    @State private var saveFailed = false
    @State private var deviceKeyIsCorrupt = false
    @State private var isConfirmingDeviceKeyReplacement = false
    @State private var deviceKeyReplacementError: String?
    @State private var isDiscoveringSessions = false
    @State private var editingRouteID: AdditionalAddressRow.ID?
    @State private var isAddingRoute = false
    /// Discard confirmation when Canceling a dirty host form (approved
    /// behavior contract: dirty drafts are protected).
    @State private var isConfirmingDiscard = false
    @State private var isShowingAdvanced = false
    /// The draft as first shown — Cancel's dirty check compares against it.
    @State private var initialDraft: HostDraft = HostDraft()
    @Environment(\.dismiss) private var dismiss

    private let credentials = HostCredentialsProvider()
    /// Session discovery probe for the Edit form. The default connector is
    /// the real SSH one; previews and tests inject nothing (discovery
    /// silently finds no sessions).
    private let sessionConnector: any TransportConnector
    init(
        store: HostStore,
        editing: Host? = nil,
        onSaved: ((Host) -> Void)? = nil,
        sessionConnector: any TransportConnector = SSHTransportConnector()
    ) {
        self.store = store
        self.editing = editing
        self.onSaved = onSaved
        self.sessionConnector = sessionConnector
        let initial = editing.map(HostDraft.init) ?? HostDraft()
        _draft = State(initialValue: initial)
        _initialDraft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledTextField(
                        "Display name",
                        text: $draft.name,
                        prompt: Text(verbatim: aliasPlaceholder))
                    } footer: {
                        Text("The name shown beside your agents.")
                    }

                    routeSection

                    Section {
                        LabeledTextField(
                            "SSH username",
                            text: $draft.username,
                            prompt: Text("user on the Host"))
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        LabeledTextField(
                            "Port",
                            text: $draft.port,
                            prompt: Text("22"))
                            .keyboardType(.numberPad)
                    }

                    authSection

                    advancedSection

                    Section {
                        TextField(
                            "Chat broker socket path (optional)",
                            text: $draft.brokerChatSocketPath)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: {
                        Text("Chat Broker")
                    } footer: {
                        Text(
                            "Absolute path of the native chat broker socket on this Host. "
                                + "Blank keeps the chat surface on the transcript file backend.")
                    }
                }
                .navigationTitle(editing == nil ? "Add Host" : "Edit Host")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { requestCancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(!draft.canSave(editing: editing))
                    }
                }
                // The swipe-down gesture cannot discard a dirty draft:
                // interactive dismiss is disabled while edits exist, so
                // the guarded Cancel is the only exit (approved behavior
                // contract; the reviewer's dirty-dismiss residue).
                .interactiveDismissDisabled(draft != initialDraft)
                .sheet(item: routeEditorBinding) { route in
                    HostRouteEditView(
                        hostName: routeEditorHostName,
                        route: route,
                        isPrimaryRoute: draft.addresses.first?.id == route.id,
                        onSave: { updated in
                            applyRouteEdit(updated)
                        },
                        onRemove: draft.addresses.count > 1
                            ? { rowID in
                                removeRoute(id: rowID)
                            }
                            : nil)
                }
                .sheet(isPresented: $isAddingRoute) {
                    // Add mode: a route not yet in the draft; created only
                    // on Save (Cancel touches nothing).
                    HostRouteEditView(
                        hostName: routeEditorHostName,
                        route: nil,
                        isPrimaryRoute: false,
                        onSave: { updated in
                            applyRouteEdit(updated)
                        },
                        onRemove: nil)
                }
                .confirmationDialog(
                    "Discard changes?",
                    isPresented: $isConfirmingDiscard,
                    titleVisibility: .visible
                ) {
                    Button("Discard Changes", role: .destructive) { dismiss() }
                    Button("Keep Editing", role: .cancel) {}
                } message: {
                    Text("Your edits to this Host have not been saved.")
                }
                .alert("Could not save the Host", isPresented: $saveFailed) {
                    Button("OK", role: .cancel) {}
                }
                .alert(
                    "Could not replace the Device Key",
                    isPresented: Binding(
                        get: { deviceKeyReplacementError != nil },
                        set: { if !$0 { deviceKeyReplacementError = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(deviceKeyReplacementError ?? "")
                }
                .confirmationDialog(
                    "Replace the Device Key?",
                    isPresented: $isConfirmingDeviceKeyReplacement,
                    titleVisibility: .visible
                ) {
                    Button("Replace Device Key", role: .destructive) { replaceDeviceKey() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "Every Host using Device Key authentication will reject the replacement "
                            + "until you add its new public key to ~/.ssh/authorized_keys.")
                }
                .task {
                    loadDeviceKey()
                    await discoverSessions()
                }
        }
    }

    // MARK: Routes

    /// NAMED connection routes, one tappable row each: the route name
    /// bolded, the exact address under it. Tapping opens the route editor
    /// for THAT row — never a hardcoded host (handoff §E requirement 3).
    private var routeSection: some View {
        Section {
            ForEach(draft.addresses) { row in
                Button {
                    editingRouteID = row.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(routeName(for: row))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                Text(routeSubtitle(for: row))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                // Nameability hint (device finding): an
                                // unnamed route says so quietly, inline.
                                if row.label.trimmingCharacters(in: .whitespaces).isEmpty {
                                    Text("Add label")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    "Route \(routeName(for: row)), \(routeSubtitle(for: row))")
                .accessibilityIdentifier("host-form-route-\(row.id.uuidString)")
            }
            Button {
                // Add mode: the editor opens WITHOUT appending anything;
                // the row is only created when the user Saves the new
                // route. Cancel leaves the draft exactly as it was.
                isAddingRoute = true
            } label: {
                Label("Add connection route", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Connection routes")
        } footer: {
            Text(
                "Routes are tried in order until one answers. Every route "
                    + "must reach the same trusted Host.")
        }
    }

    /// The route editor's item binding: only the editing row travels, so
    /// the sheet presents the selected route's real values.
    private var routeEditorBinding: Binding<AdditionalAddressRow?> {
        Binding(
            get: {
                guard let editingRouteID else { return nil }
                return draft.addresses.first { $0.id == editingRouteID }
            },
            set: { newValue in
                if newValue == nil { editingRouteID = nil }
            })
    }

    private func applyRouteEdit(_ updated: AdditionalAddressRow) {
        if isAddingRoute {
            // Save on a NEW route: the row is created here, not on open —
            // a canceled Add never leaves a blank row in the draft.
            draft.addresses.append(updated)
            isAddingRoute = false
            return
        }
        guard let index = draft.addresses.firstIndex(where: { $0.id == updated.id })
        else { return }
        draft.addresses[index] = updated
    }

    /// Deliberate route removal (approved §E): the multi-path floor
    /// lives in the model — the LAST remaining route always survives, so
    /// a Host is never left with nothing to dial.
    private func removeRoute(id: UUID) {
        draft.removeAddress(id: id)
        editingRouteID = nil
    }

    /// Cancel protects a dirty draft (approved behavior contract):
    /// unchanged drafts dismiss directly; edited ones confirm first.
    private func requestCancel() {
        if draft != initialDraft {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    /// The Host identity the route editor scopes itself to (§E 3): the
    /// form's draft names this Host; a brand-new Host falls back to a
    /// generic phrase rather than a fake name.
    private var routeEditorHostName: String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "this Host" : trimmed
    }
    private func routeName(for row: AdditionalAddressRow) -> String {
        let trimmed = row.label.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        let address = row.address.trimmingCharacters(in: .whitespaces)
        return address.isEmpty ? "Unnamed route" : address
    }

    private func routeSubtitle(for row: AdditionalAddressRow) -> String {
        let address = row.address.trimmingCharacters(in: .whitespaces)
        let primaryMark = draft.addresses.first?.id == row.id ? " · primary" : ""
        return (address.isEmpty ? "No address yet" : address) + primaryMark
    }

    // MARK: Auth

    /// Auth summary: which method is active and, for Device Key, the key's
    /// kind — not the blob. The copyable `authorized_keys` line and the
    /// password field sit under their own disclosure so the form stays
    /// clean without hiding anything (handoff §E requirement 1).
    private var authSection: some View {
        Section {
            Picker("Method", selection: $draft.authMethod) {
                Text("Device Key").tag(Host.AuthMethod.deviceKey)
                Text("Password").tag(Host.AuthMethod.password)
            }
            .pickerStyle(.segmented)
            switch draft.authMethod {
            case .deviceKey:
                deviceKeySection
            case .password:
                SecureField(
                    editing == nil ? "Password" : "Password (blank keeps current)",
                    text: $draft.password)
            }
        } header: {
            Text("Authentication")
        } footer: {
            if draft.authMethod == .deviceKey {
                Text(
                    "Heeler signs in with this device's key. The private key "
                        + "never leaves this device.")
            }
        }
    }

    @ViewBuilder
    private var deviceKeySection: some View {
        if deviceKeyIsCorrupt {
            Label("Device key is corrupted", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button("Replace Device Key", role: .destructive) {
                isConfirmingDeviceKeyReplacement = true
            }
        } else {
            LabeledContent("Device key") {
                Text(deviceKeySummary ?? "Ed25519")
                    .foregroundStyle(.secondary)
            }
            if let authorizedKeysLine {
                DisclosureGroup("authorized_keys line") {
                    Text(authorizedKeysLine)
                        .font(.caption.monospaced())
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = authorizedKeysLine
                        didCopyKeyLine = true
                    } label: {
                        Label(
                            didCopyKeyLine ? "Copied" : "Copy line",
                            systemImage: didCopyKeyLine ? "checkmark" : "doc.on.doc")
                    }
                }
            } else {
                Label("Device key unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Try Again") { loadDeviceKey() }
            }
        }
    }

    // MARK: Advanced

    /// Advanced connection settings folded away by default: session and
    /// jump host. Focus-retention rules apply inside the disclosure
    /// exactly as anywhere else in the form.
    @ViewBuilder
    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced settings", isExpanded: $isShowingAdvanced) {
                TextField("Session name", text: $draft.sessionName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !availableSessions.isEmpty {
                    Picker("Discovered", selection: $draft.sessionName) {
                        Text("default").tag("")
                        ForEach(availableSessions, id: \.name) { session in
                            Text(session.name).tag(session.name)
                        }
                    }
                }
                TextField("Jump Host address (optional)", text: $draft.jumpAddress)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if draft.usesJumpHost {
                    TextField("Jump Host port", text: $draft.jumpPort)
                        .keyboardType(.numberPad)
                    TextField("Jump Host user (blank = same as Host)", text: $draft.jumpUsername)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
        } footer: {
            if draft.usesJumpHost {
                Text(jumpHostFooter)
            } else if isShowingAdvanced {
                Text("Leave blank to connect to the Host directly.")
            }
        }
    }

    /// The Alias field's title/placeholder: the Host's real name when the
    /// form has one to preview, otherwise a generic hint. Empty stays empty
    /// (no alias) rather than defaulting to the name.
    private var aliasPlaceholder: String {
        let trimmed = editing?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? "Optional" : trimmed
    }

    private var jumpHostFooter: String {
        "Address and Port above are reached through the Jump Host"
            + (draft.usesJumpHost ? "." : " only while a Jump Host is set.")
    }

    private func loadDeviceKey() {
        do {
            let key = try credentials.deviceKey()
            authorizedKeysLine = key.authorizedKeysLine(comment: "heeler")
            deviceKeySummary = "Ed25519 · this device"
            deviceKeyIsCorrupt = false
        } catch DeviceKeyStoreError.storedKeyCorrupt {
            authorizedKeysLine = nil
            deviceKeySummary = nil
            deviceKeyIsCorrupt = true
        } catch {
            authorizedKeysLine = nil
            deviceKeySummary = nil
            deviceKeyIsCorrupt = false
        }
    }

    private func replaceDeviceKey() {
        do {
            let key = try credentials.replaceDeviceKey()
            authorizedKeysLine = key.authorizedKeysLine(comment: "heeler")
            deviceKeySummary = "Ed25519 · this device"
            deviceKeyIsCorrupt = false
            didCopyKeyLine = false
        } catch {
            deviceKeyReplacementError = "The replacement could not be saved to the Keychain."
        }
    }

    /// Sessions/Hosts blending (Phase 5): populates the session picker for
    /// an existing Host by connecting once and running `session list`.
    /// Best-effort by design — a failure (offline, stale pin, untrusted
    /// key, missing password) leaves the manual text field as the only
    /// session source, exactly as before. A first-connect trust prompt can
    /// never fire from here: an unknown host key is declined silently and
    /// discovery ends; onboarding owns the TOFU conversation.
    private func discoverSessions() async {
        guard let editing, !isDiscoveringSessions else { return }
        isDiscoveringSessions = true
        defer { isDiscoveringSessions = false }
        do {
            let resolved = try credentials.credentials(for: editing)
            // No TOFU prompt from the form: keys not already trusted fail.
            let policy = HostKeyPolicy(knownHosts: UserDefaultsKnownHostsStore.shared) { _ in false }
            let settings = SSHTransportSettings(
                host: editing, credentials: resolved, hostKeyPolicy: policy)
            let transport = try await sessionConnector.connect(settings: settings)
            defer { Task { try? await transport.close() } }
            availableSessions = try await transport.listSessions()
        } catch {
            availableSessions = []
        }
    }

    private func save() {
        guard draft.canSave(editing: editing) else { return }
        guard let host = draft.makeHost(id: editing?.id ?? UUID()) else { return }
        do {
            if editing == nil {
                try store.add(host, password: draft.passwordUpdate)
            } else {
                try store.update(host, password: draft.passwordUpdate)
            }
        } catch {
            saveFailed = true
            return
        }
        dismiss()
        onSaved?(host)
    }
}

/// A Form row that keeps its own label visible above the field, so no
/// placeholder-only unlabeled fields ship (handoff §E requirement 1).
private struct LabeledTextField: View {
    private let title: String
    private let prompt: Text?
    @Binding private var text: String

    init(_ title: String, text: Binding<String>, prompt: Text? = nil) {
        self.title = title
        _text = text
        self.prompt = prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            // The field keeps its own accessibility identity (title),
            // so UI tests and VoiceOver can focus and type into it
            // directly; the caption above is a separate element.
            TextField(title, text: $text, prompt: prompt)
                .accessibilityLabel(title)
        }
    }
}

/// The sheet that edits ONE route of the selected Host: the route's name
/// and its exact address. Blank label falls back to the address as the
/// route's presentation name, matching ``Host/routeName(for:)``.
struct HostRouteEditView: View {
    @State private var label: String
    @State private var address: String
    private let hostName: String
    private let routeID: AdditionalAddressRow.ID?
    private let isPrimaryRoute: Bool
    private let onSave: (AdditionalAddressRow) -> Void
    /// Deliberate removal (§E): nil in add mode (nothing to remove) and
    /// for the last remaining route (the model's floor keeps it).
    private let onRemove: ((AdditionalAddressRow.ID) -> Void)?
    private let isNewRoute: Bool
    @Environment(\.dismiss) private var dismiss

    init(
        hostName: String,
        route: AdditionalAddressRow?,
        isPrimaryRoute: Bool,
        onSave: @escaping (AdditionalAddressRow) -> Void,
        onRemove: ((AdditionalAddressRow.ID) -> Void)?
    ) {
        _label = State(initialValue: route?.label ?? "")
        _address = State(initialValue: route?.address ?? "")
        self.hostName = hostName
        self.routeID = route?.id
        self.isPrimaryRoute = isPrimaryRoute
        self.onSave = onSave
        self.onRemove = onRemove
        self.isNewRoute = route == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledTextField("Route label", text: $label, prompt: Text("For example, VPN"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    LabeledTextField(
                        "Hostname or address", text: $address, prompt: Text("host.example.com"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } footer: {
                    Text(
                        "Routes apply only to \(hostName). Changing an "
                            + "address never bypasses host-key verification.")
                }
                if isPrimaryRoute {
                    Section {
                        Label(
                            "Primary route — tried first, and the address other "
                                + "surfaces summarize this Host by.",
                            systemImage: "bolt")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let onRemove, let routeID {
                    Section {
                        Button("Remove route", role: .destructive) {
                            onRemove(routeID)
                            dismiss()
                        }
                        .accessibilityIdentifier("route-editor-remove")
                    } footer: {
                        Text(
                            "Removing keeps every other route; the last "
                                + "remaining route cannot be removed.")
                    }
                }
            }
            // Identity-scoped title (§E 3): the editor names WHICH Host's
            // route is being added or edited.
            .navigationTitle(
                (isNewRoute ? "Add route on " : "Edit route on ") + hostName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let routeID {
                            onSave(
                                AdditionalAddressRow(
                                    id: routeID, address: address, label: label))
                        } else {
                            // Add mode: the row is born here, with its own
                            // UUID identity.
                            onSave(AdditionalAddressRow(address: address, label: label))
                        }
                        dismiss()
                    }
                    .accessibilityIdentifier("route-editor-save")
                }
            }
        }
    }
}

#Preview("Add") {
    HostFormView(store: HostStore(secrets: PreviewSecretStore()))
}

#Preview("Edit multipath") {
    HostFormView(
        store: HostStore(secrets: PreviewSecretStore()),
        editing: Host(
            name: "Studio Mac",
            address: "192.168.31.71",
            username: "developer",
            additionalAddresses: ["CMF79KM7YF.local", "studio.vpn.example"],
            routeLabels: [
                "192.168.31.71": "Local network",
                "studio.vpn.example": "VPN",
            ]))
}

/// Keeps previews out of the real Keychain.
private final class PreviewSecretStore: SecretStore {
    func read(account: String) throws -> Data? { nil }
    func readAll() throws -> [String: Data] { [:] }
    func write(_ secret: Data, account: String) throws {}
    func removeSecret(account: String) throws {}
}
