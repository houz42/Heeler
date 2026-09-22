import SwiftUI

/// The first-connect auto-provisioning flow's UI: one sheet, every phase
/// rendered honestly, and the TWO explicit confirmations the spec
/// requires — "Set up?" before any remote mutation, and the
/// ask-before-restart list before any agent restarts.
struct MeadowFirstConnectFlowView: View {
    @State private var store: MeadowFirstConnectProvisioningStore
    /// The catalog for the Host-record socket-path write. The AgentDetail
    /// presentation passes nil (the Console owns the catalog reload); a
    /// Hosts-side presentation may pass the live catalog.
    private let onProvisioned: () -> Void

    init(host: Host, catalog: HostStore?, onProvisioned: @escaping () -> Void) {
        _store = State(
            initialValue: MeadowFirstConnectProvisioningStore(
                host: host,
                catalog: catalog,
                preferredAddresses: PreferredAddressStore(hostID: host.id)))
        self.onProvisioned = onProvisioned
    }

    var body: some View {
        NavigationStack {
            Group {
                switch store.phase {
                case .idle, .detecting:
                    ProgressView("Checking this Host for a chat broker…")
                case .offering:
                    offer
                case .provisioning:
                    ProgressView("Setting up the chat broker…")
                case .restartDecision(let agents):
                    restartDecision(agents)
                case .restarting(let remaining):
                    ProgressView("Restarting agents… \(remaining) left")
                case .done:
                    doneView
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Setup Failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Dismiss") { dismissFlow() }
                    }
                }
            }
            .navigationTitle("Chat Broker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task {
                            await store.cancel()
                            dismissFlow()
                        }
                    }
                    .disabled(isMutating)
                }
            }
            .alert(
                "Trust this Host?",
                isPresented: Binding(
                    get: { pendingFingerprint != nil },
                    set: { if !$0 { store.confirmFingerprint(trusted: false) } })
            ) {
                Button("Trust") { store.confirmFingerprint(trusted: true) }
                Button("Don't Trust", role: .cancel) {
                    store.confirmFingerprint(trusted: false)
                }
            } message: {
                if let candidate = pendingFingerprint {
                    Text(
                        "First connection to \(candidate.host):\(String(candidate.port)).\n\n"
                            + "Key fingerprint:\n\(candidate.fingerprint.displayString)\n\n"
                            + "Verify it matches the Host's key before trusting.")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            if store.phase == .idle {
                await store.detect()
            }
        }
    }


    private func restartFooter(_ isEmpty: Bool) -> String {
        if isEmpty { return "" }
        return "Restarting briefly interrupts each agent's context; "
            + "sessions resume exactly where they were. "
            + "Cancel keeps the broker — agents register at their next "
            + "natural restart."
    }

    private var pendingFingerprint: HostKeyCandidate? {
        // The store surfaces the candidate through the provisioning
        // session's TOFU callback; the sheet mirrors it for the alert.
        store.pendingFingerprint
    }

    private var isMutating: Bool {
        if case .provisioning = store.phase { return true }
        if case .restarting = store.phase { return true }
        return false
    }

    /// Confirmation 1: "Set up chat broker on this Host?" — no remote
    /// mutation before this.
    private var offer: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Set up chat broker on this Host?")
                .font(.title3.weight(.semibold))
            Text(
                "Meadow installs a small chat broker on the Host and "
                    + "registers your agents with it, so this agent gets "
                    + "broker chat on your phone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task {
                    await store.provision()
                    if store.resolvedSocketPath != nil {
                        onProvisioned()
                    }
                }
            } label: {
                Text("Set Up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button("Not Now") { dismissFlow() }
        }
        .padding(24)
    }

    /// Confirmation 2 (the user's data-safety line): the restart list.
    /// Cancel keeps everything installed; nothing restarts.
    private func restartDecision(_ agents: [MeadowFirstConnectProvisioningStore.RestartableAgent]) -> some View {
        List {
            Section {
                if agents.isEmpty {
                    Text(
                        "The broker is set up. No live agents need a restart — "
                            + "agents you start from now on register automatically.")
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(agents) { agent in
                        HStack {
                            Image(systemName: "terminal")
                            VStack(alignment: .leading) {
                                Text(agent.title)
                                    .lineLimit(1)
                                Text(agent.paneID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(agents.isEmpty ? "Done" : "Restart these agents?")
            } footer: {
                Text(restartFooter(agents.isEmpty))
            }
            Section {
                if !agents.isEmpty {
                    Button {
                        Task {
                            await store.restartConfirmedAgents()
                            onProvisioned()
                        }
                    } label: {
                        Text("Restart \(agents.count) Agents")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Not Now") {
                    store.skipRestarts()
                    onProvisioned()
                    dismissFlow()
                }
            }
        }
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Chat broker ready")
                .font(.title3.weight(.semibold))
            if let path = store.resolvedSocketPath {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button("Done") {
                Task { await store.finish() }
                dismissFlow()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    @Environment(\.dismiss) private var dismiss

    private func dismissFlow() {
        Task { await store.finish() }
        dismiss()
    }
}
