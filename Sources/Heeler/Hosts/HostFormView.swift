import SwiftUI

/// Add/edit form for a Host. Device-key auth shows the copyable
/// `authorized_keys` line (generated on device, never exported beyond its
/// public half); the password goes straight to the Keychain via `HostStore`.
struct HostFormView: View {
    let store: HostStore
    var editing: Host?
    var onSaved: ((Host) -> Void)?

    @State private var draft: HostDraft
    @State private var availableSessions: [HerdrSession] = []
    @State private var authorizedKeysLine: String?
    @State private var didCopyKeyLine = false
    @State private var saveFailed = false
    @State private var deviceKeyIsCorrupt = false
    @State private var isConfirmingDeviceKeyReplacement = false
    @State private var deviceKeyReplacementError: String?
    @State private var isDiscoveringSessions = false
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
        _draft = State(initialValue: editing.map(HostDraft.init) ?? HostDraft())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $draft.name)
                    TextField(
                        aliasPlaceholder,
                        text: $draft.alias,
                        prompt: Text(verbatim: aliasPlaceholder)
                    )
                    TextField("Address", text: $draft.address)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    ForEach($draft.additionalAddresses) { $row in
                        HStack {
                            TextField("Additional address", text: $row.address)
                                .textContentType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button(role: .destructive) {
                                draft.removeAdditionalAddress(id: row.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onMove { source, destination in
                        draft.moveAdditionalAddress(from: source, to: destination)
                    }
                    Button {
                        draft.addAdditionalAddress()
                    } label: {
                        Label("Add address", systemImage: "plus.circle.fill")
                    }
                    TextField("Port", text: $draft.port)
                        .keyboardType(.numberPad)
                    TextField("User", text: $draft.username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Host")
                } footer: {
                    Text(addressFooter)
                }

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
                            "Add this line to ~/.ssh/authorized_keys on the Host. "
                                + "The private key never leaves this device.")
                    }
                }

                Section {
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
                } header: {
                    Text("herdr Session")
                } footer: {
                    if availableSessions.isEmpty {
                        Text("Leave blank for the default herdr session.")
                    } else {
                        Text("Pick a discovered session or type a name. Leave blank for the default herdr session.")
                    }
                }

                Section {
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
                } header: {
                    Text("Jump Host")
                } footer: {
                    if draft.usesJumpHost {
                        Text(jumpHostFooter)
                    } else {
                        Text("Leave blank to connect to the Host directly.")
                    }
                }
            }
            .navigationTitle(editing == nil ? "Add Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!draft.canSave(editing: editing))
                }
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

    /// The Alias field's title/placeholder: the Host's real name when the
    /// form has one to preview, otherwise a generic hint. Empty stays empty
    /// (no alias) rather than defaulting to the name.
    private var aliasPlaceholder: String {
        let realName = editing?.displayName ?? draft.name.trimmingCharacters(in: .whitespaces)
        return realName.isEmpty ? "Alias (optional)" : "Alias (optional) — replaces \"\(realName)\""
    }

    private var jumpHostFooter: String {
        let credentialRequirement =
            switch draft.authMethod {
            case .deviceKey:
                "Both machines must authorize the Device Key."
            case .password:
                "Both machines must accept the same password; separate passwords are not supported."
            }
        return "The Host's Address and Port are resolved from the Jump Host, usually through "
            + "a loopback-only reverse tunnel. \(credentialRequirement) You confirm each "
            + "machine's host key fingerprint independently on first connect."
    }

    private var addressFooter: String {
        "The first address is dialed first; each additional one is tried in "
            + "order when the one before it does not answer. They should all "
            + "name the same machine."
    }


    @ViewBuilder
    private var deviceKeySection: some View {
        if let authorizedKeysLine {
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
                    didCopyKeyLine ? "Copied" : "Copy authorized_keys Line",
                    systemImage: didCopyKeyLine ? "checkmark" : "doc.on.doc")
            }
        } else {
            Label(
                deviceKeyIsCorrupt ? "Device key is corrupted" : "Device key unavailable",
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            if deviceKeyIsCorrupt {
                Button("Replace Device Key", role: .destructive) {
                    isConfirmingDeviceKeyReplacement = true
                }
            } else {
                Button("Try Again") { loadDeviceKey() }
            }
        }
    }

    private func loadDeviceKey() {
        do {
            let key = try credentials.deviceKey()
            authorizedKeysLine = key.authorizedKeysLine(comment: "heeler")
            deviceKeyIsCorrupt = false
        } catch DeviceKeyStoreError.storedKeyCorrupt {
            authorizedKeysLine = nil
            deviceKeyIsCorrupt = true
        } catch {
            authorizedKeysLine = nil
            deviceKeyIsCorrupt = false
        }
    }

    private func replaceDeviceKey() {
        do {
            let key = try credentials.replaceDeviceKey()
            authorizedKeysLine = key.authorizedKeysLine(comment: "heeler")
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
