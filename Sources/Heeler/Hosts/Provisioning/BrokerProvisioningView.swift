import SwiftUI

/// The broker provisioning sheet: read-only status first, then the six
/// explicit operations. Every mutation is a user-initiated button press
/// (the store enforces this too — no operation runs on connection).
struct BrokerProvisioningView: View {
    @State private var session: BrokerProvisioningSessionStore
    @State private var operationError: String?

    init(host: Host) {
        _session = State(
            initialValue: BrokerProvisioningSessionStore(
                host: host,
                preferredAddresses: PreferredAddressStore(hostID: host.id)))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch session.phase {
                case .idle, .connecting:
                    ProgressView("Connecting to \(session.host.displayName)…")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Connection Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { Task { await session.connect() } }
                    }
                case .connected:
                    if let store = session.provisioning {
                        statusList(store)
                    }
                }
            }
            .navigationTitle("Chat Broker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { Task { await session.close() } }
                }
            }
            .alert(
                "Provisioning Failed",
                isPresented: Binding(
                    get: { operationError != nil },
                    set: { if !$0 { operationError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(operationError ?? "")
            }
            .alert(
                "Trust this Host?",
                isPresented: Binding(
                    get: { session.pendingFingerprint != nil },
                    set: { if !$0 { session.confirmFingerprint(trusted: false) } })
            ) {
                Button("Trust") { session.confirmFingerprint(trusted: true) }
                Button("Don't Trust", role: .cancel) {
                    session.confirmFingerprint(trusted: false)
                }
            } message: {
                if let candidate = session.pendingFingerprint {
                    Text(
                        "First connection to \(candidate.host):\(String(candidate.port)).\n\n"
                            + "Key fingerprint:\n\(candidate.fingerprint.displayString)\n\n"
                            + "Verify it matches the Host's key before trusting.")
                }
            }
        }
        .task {
            await session.connect()
        }
    }

    @ViewBuilder
    private func statusList(_ store: BrokerProvisioningStore) -> some View {
        List {
            Section {
                statusRow(store)
                if let platform = store.state.platform {
                    LabeledContent("Platform", value: platform.displayName)
                }
                if let version = store.state.activeVersion {
                    LabeledContent("Version", value: version)
                }
            } header: {
                HStack {
                    Text("Status")
                    if store.phase == .inspecting || store.phase == .operating {
                        ProgressView().controlSize(.mini).padding(.leading, 4)
                    }
                }
            }

            let hints = store.state.missingPrerequisiteHints
            if !hints.isEmpty {
                Section {
                    ForEach(hints, id: \.self) { hint in
                        Label(hint, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Missing Prerequisites")
                }
            }

            Section {
                Button {
                    Task { await run { try await store.inspect() } }
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
                .disabled(store.phase == .inspecting || store.phase == .operating)
            }

            if store.state.layout != nil {
                Section {
                    statusDetailRows(store)
                } header: {
                    Text("Setup")
                } footer: {
                    Text(
                        "Operations run on the Host only when you press them. "
                            + "Nothing installs automatically on connection.")
                }
            }
        }
    }

    @ViewBuilder
    private func statusDetailRows(_ store: BrokerProvisioningStore) -> some View {
        if !store.state.status.isInstalled {
            Label(
                "Not installed",
                systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        }
        if store.state.status.isInstalled && !store.state.status.isServiceActive {
            Label(
                "Service inactive",
                systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        }
        if store.state.status.isServiceActive && !store.state.adapterConfigured {
            Label(
                "Adapter not configured",
                systemImage: "wrench.and.screwdriver")
                .foregroundStyle(.secondary)
        }
    }

    private func statusRow(_ store: BrokerProvisioningStore) -> some View {
        let (icon, label): (String, String)
        switch store.state.status {
        case .backendUnavailable:
            (icon, label) = ("questionmark.circle", "Backend unavailable")
        case .notInstalled:
            (icon, label) = ("square.dashed", "Not installed")
        case .installed(let active):
            (icon, label) = (
                active ? "checkmark.circle" : "pause.circle",
                active ? "Service active" : "Installed — service inactive"
            )
        case .fullyProvisioned:
            (icon, label) = ("checkmark.seal.fill", "Ready")
        }
        return Label(label, systemImage: icon)
    }

    private func run(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch let error as BrokerProvisioningError {
            operationError = error.userMessage
        } catch {
            operationError = String(describing: error)
        }
    }
}
