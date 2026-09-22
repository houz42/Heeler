import Foundation
import Observation

/// First-connect auto-provisioning: when a Host has no chat broker, this
/// store drives the full bring-up as ONE user-visible flow with explicit
/// confirmations at the two points that touch the user's machine:
///
///  1. connect + detect: inspect the Host (read-only) — is a Meadow
///     broker installed, service active, shim present, socket resolvable?
///  2. OFFER: "Set up chat broker on this Host?" → user confirms.
///  3. provision: install the bundled package (checksummed, atomic),
///     enable the user service, write the adapter shim. All through the
///     existing BrokerProvisioningStore operations.
///  4. configure the Host record: `brokerChatSocketPath` = the Meadow
///     standard path resolved ON THE HOST (XDG_DATA_HOME honored); the
///     chat lane picks it up with no manual edit.
///  5. list restartable agents, then ASK: "Restart N agents to enable
///     chat?" with the agent list. Cancel keeps the broker + shim (the
///     user restarts agents whenever they like); confirm restarts each
///     agent in its own pane with `--resume` (sessions preserved).
///
/// The ask-before-restart is a hard requirement: restarting interrupts
/// the user's live agent contexts, so it NEVER runs without the explicit
/// confirmation naming exactly which agents restart.
@MainActor
@Observable
final class MeadowFirstConnectProvisioningStore {
    enum Phase: Equatable {
        case idle
        /// Read-only inspect probe in flight.
        case detecting
        /// The Host needs bring-up; waiting for the user's "Set up?".
        case offering
        /// Provisioning (install + enable + shim) in flight.
        case provisioning
        /// Provisioned; the Host record is updated; waiting for the
        /// user's restart decision.
        case restartDecision(agents: [RestartableAgent])
        /// Restarting the confirmed agents.
        case restarting(remaining: Int)
        case done
        case failed(message: String)
    }

    /// One agent the restart confirmation lists.
    struct RestartableAgent: Equatable, Identifiable, Sendable {
        let paneID: String
        let kind: String
        let title: String
        /// The omp session id for `--resume`, when the agent's session
        /// file is known; nil restarts bare (fresh session).
        let resumeSessionID: String?
        var id: String { paneID }
    }

    private(set) var phase: Phase = .idle
    /// The provisioning store for the confirmed Host, non-nil once a
    /// session connection succeeded.
    private(set) var provisioning: BrokerProvisioningStore?
    /// The resolved Meadow socket path written into the Host record.
    private(set) var resolvedSocketPath: String?
    /// The pending first-connect fingerprint, for the flow's trust alert.
    private(set) var pendingFingerprint: HostKeyCandidate?
    let host: Host
    /// The catalog the socket-path write goes through (Host record).
    let catalog: HostStore?

    @ObservationIgnored private let connector: any TransportConnector
    @ObservationIgnored private let knownHosts: any KnownHostsStore
    @ObservationIgnored private let credentials: HostCredentialsProvider
    @ObservationIgnored private let preferredAddresses: PreferredAddressStore
    @ObservationIgnored private let fingerprintTimeout: Duration
    @ObservationIgnored private let packageSource: MeadowPackageSource
    @ObservationIgnored private var transport: (any Transport)?
    @ObservationIgnored private var fingerprintDecision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var fingerprintTimeoutTask: Task<Void, Never>?

    init(
        host: Host,
        catalog: HostStore? = nil,
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        preferredAddresses: PreferredAddressStore,
        fingerprintTimeout: Duration = .seconds(60),
        packageSource: MeadowPackageSource = BundledMeadowPackageSource()
    ) {
        self.host = host
        self.catalog = catalog
        self.connector = connector
        self.knownHosts = knownHosts
        self.credentials = credentials
        self.preferredAddresses = preferredAddresses
        self.fingerprintTimeout = fingerprintTimeout
        self.packageSource = packageSource
    }

    // MARK: - Detect

    /// Connects (surfacing TOFU like onboarding) and inspects. Read-only;
    /// safe to run automatically when the chat lane reports no broker.
    /// Lands on `.offering` when bring-up would help, `.done` when the
    /// Host is already provisioned, `.failed` otherwise.
    func detect() async {
        guard phase != .detecting, phase != .provisioning,
            phase != .restarting(remaining: 0)
        else { return }
        phase = .detecting
        do {
            let opened = try await connect()
            transport = opened
            let store = BrokerProvisioningStore(transport: opened)
            provisioning = store
            await store.inspect()
            if let error = store.lastError {
                throw BrokerProvisioningError.commandFailed(detail: error)
            }
            // Already fully provisioned AND the Host record already
            // points at the broker: nothing to offer.
            if case .fullyProvisioned = store.state.status,
                host.hasBrokerChat
            {
                phase = .done
                return
            }
            phase = .offering
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(message: String(describing: error))
        }
    }

    // MARK: - Provision (user confirmed "Set up")

    /// Runs the bring-up after the user's explicit "Set up chat broker on
    /// this Host?" confirmation: install + enable + shim + Host-record
    /// update, then lands on the restart decision with the agent list.
    func provision() async {
        guard phase == .offering, let store = provisioning else { return }
        phase = .provisioning
        do {
            guard let package = try await packageSource.package(for: store.state.platform) else {
                throw BrokerProvisioningError.commandFailed(
                    detail: "This build carries no broker package for the Host's platform.")
            }
            try await store.install(
                package: package.prepared,
                version: package.version,
                sha256: package.sha256)
            try await store.enable()
            try await store.configureAdapter(askWrapperOptIn: true)
            // Resolve the canonical socket path ON THE HOST (XDG honored)
            // and publish it to the Host record so the chat lane connects
            // with no manual edit.
            guard let resolved = try await resolveHostSocketPath() else {
                throw BrokerProvisioningError.commandFailed(
                    detail: "Could not resolve the Meadow socket path on the Host.")
            }
            resolvedSocketPath = resolved
            // Publish to the Host record: the chat lane connects with no
            // manual edit (spec item 3).
            try writeHostRecord(socketPath: resolved)
            let agents = try await restartableAgents()
            phase = .restartDecision(agents: agents)
        } catch let error as BrokerProvisioningError {
            phase = .failed(message: error.userMessage)
        } catch {
            phase = .failed(message: String(describing: error))
        }
    }

    // MARK: - Restart decision (user's data-safety line)

    /// The user declined the restarts: the broker + shim stay, the flow
    /// completes without touching any agent. Agents register at their
    /// next natural restart.
    func skipRestarts() {
        guard case .restartDecision = phase else { return }
        phase = .done
    }

    /// The user confirmed the restart of the LISTED agents: each gets
    /// `/exit` then a same-pane `agent.start --resume <session>`.
    func restartConfirmedAgents() async {
        guard case .restartDecision(let agents) = phase, let transport else { return }
        var remaining = agents
        phase = .restarting(remaining: remaining.count)
        do {
            while !remaining.isEmpty {
                let agent = remaining.removeFirst()
                try await restartOne(agent, transport: transport)
                phase = .restarting(remaining: remaining.count)
            }
            phase = .done
        } catch {
            // Honest partial state: the restart loop reports where it
            // stopped; the agents before it ARE restarted.
            phase = .failed(
                message: "Restarted \(agents.count - remaining.count) of \(agents.count). "
                    + "The rest can be restarted manually. (\(error))")
        }
    }

    /// Cancels the whole flow from any non-mutating phase.
    func cancel() async {
        if let transport {
            try? await transport.close()
        }
        transport = nil
        provisioning = nil
        phase = .idle
    }

    /// Tears the flow's connection down on completion; the broker keeps
        /// running on the Host (supervised) and the chat lane opens its
        /// own channel.
    func finish() async {
        if let transport {
            try? await transport.close()
        }
        transport = nil
    }

    // MARK: - Internals

    private func restartOne(
        _ agent: RestartableAgent, transport: any Transport
    ) async throws {
        // Exit the live agent (its pane returns to the shell), then
        // start the agent again IN THE SAME PANE with --resume so the
        // session (and the user's context) carries over.
        _ = try await transport.promptAgent(
            AgentPromptParams(target: agent.paneID, text: "/exit"))
        var arguments: [String] = []
        if let session = agent.resumeSessionID {
            arguments = ["--resume", session]
        }
        _ = try await transport.restartAgent(
            paneID: agent.paneID,
            kind: agent.kind,
            name: agent.paneID.replacingOccurrences(of: ":", with: "-"),
            arguments: arguments)
    }

    /// The agents the restart confirmation lists: live omp agents with a
    /// pane. Non-omp kinds are skipped (their adapters are not installed
    /// by this flow).
    private func restartableAgents() async throws -> [RestartableAgent] {
        guard let transport else { return [] }
        let snapshot = try await transport.sessionSnapshot()
        return snapshot.agents
            .filter { $0.agent == "omp" && !$0.paneID.isEmpty }
            .map { info in
                let title = info.terminalTitleStripped
                    ?? info.terminalTitle
                    ?? info.paneID
                return RestartableAgent(
                    paneID: info.paneID,
                    kind: info.agent ?? "omp",
                    title: title,
                    resumeSessionID: Self.resumeSessionID(from: info.agentSession))
            }
    }

    /// omp sessions reference their transcript file
    /// (`.../<timestamp>_<sessionID>.jsonl`); the resume id is the
    /// basename's UUID tail.
    static func resumeSessionID(from session: AgentSessionInfo?) -> String? {
        guard let session else { return nil }
        let basename = (session.value as NSString).lastPathComponent
        guard let underscore = basename.lastIndex(of: "_") else { return nil }
        let tail = String(basename[basename.index(after: underscore)...])
        let stem = tail.hasSuffix(".jsonl") ? String(tail.dropLast(".jsonl".count)) : tail
        return stem.count == 36 ? stem : nil
    }

    /// Writes the resolved socket path into the Host record so the chat
    /// lane picks it up without a manual edit. A missing catalog (tests
    /// that only exercise the flow) skips the write; the resolved path
    /// stays published for assertions.
    private func writeHostRecord(socketPath: String) throws {
        guard let catalog else { return }
        var updated = host
        updated.brokerChatSocketPath = socketPath
        try catalog.update(updated)
    }

    /// Resolves `${XDG_DATA_HOME:-$HOME/.local/share}/meadow/broker.sock`
    /// ON THE HOST and returns the literal path for the Host record.
    private func resolveHostSocketPath() async throws -> String? {
        guard let transport else { return nil }
        let result = try await transport.runProvisioningCommand(
            "printf '%s' \"${XDG_DATA_HOME:-$HOME/.local/share}/meadow/broker.sock\"")
        let path = result.trimmedText
        guard path.hasPrefix("/"), path.hasSuffix("broker.sock") else {
            return nil
        }
        return path
    }

    private func connect() async throws -> any Transport {
        let resolved = try credentials.credentials(for: host)
        let policy = HostKeyPolicy(knownHosts: knownHosts) { [weak self] candidate in
            await self?.awaitFingerprintDecision(for: candidate) ?? false
        }
        var settings = SSHTransportSettings(
            host: host, credentials: resolved, hostKeyPolicy: policy)
        settings.candidateAddresses = preferredAddresses.preferredOrder(
            for: host.candidateAddresses)
        return try await connector.connect(settings: settings)
    }

    private func awaitFingerprintDecision(for candidate: HostKeyCandidate) async -> Bool {
        guard fingerprintDecision == nil else { return false }
        pendingFingerprint = candidate
        return await withCheckedContinuation { continuation in
            fingerprintDecision = continuation
            fingerprintTimeoutTask = Task { [fingerprintTimeout] in
                try? await Task.sleep(for: fingerprintTimeout)
                guard !Task.isCancelled else { return }
                self.confirmFingerprint(trusted: false)
            }
        }
    }

    /// The user's verdict on the pending first-connect fingerprint.
    func confirmFingerprint(trusted: Bool) {
        guard let decision = fingerprintDecision else { return }
        fingerprintDecision = nil
        fingerprintTimeoutTask?.cancel()
        fingerprintTimeoutTask = nil
        pendingFingerprint = nil
        decision.resume(returning: trusted)
    }
}
