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
    @ObservationIgnored private var transport: (any Transport)?
    @ObservationIgnored private var fingerprintDecision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var fingerprintTimeoutTask: Task<Void, Never>?
    /// The wire-level "does the broker answer at this path" probe.
    /// Production opens a real broker channel (HeelerSSHTransport,
    /// direct-streamlocal); tests inject a scripted answer because test
    /// doubles cannot open streamlocal channels.
    @ObservationIgnored private let brokerProbe:
        @Sendable (_ socketPath: String, _ transport: (any Transport)?) async -> Bool

    init(
        host: Host,
        catalog: HostStore? = nil,
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        preferredAddresses: PreferredAddressStore,
        fingerprintTimeout: Duration = .seconds(60),
        brokerProbe: @escaping @Sendable (
            _ socketPath: String, _ transport: (any Transport)?
        ) async -> Bool = MeadowFirstConnectProvisioningStore.sshBrokerProbe
    ) {
        self.host = host
        self.catalog = catalog
        self.connector = connector
        self.knownHosts = knownHosts
        self.credentials = credentials
        self.preferredAddresses = preferredAddresses
        self.fingerprintTimeout = fingerprintTimeout
        self.brokerProbe = brokerProbe
    }

    /// The production probe: a real broker channel open on the SSH
    /// transport — the same streamlocal discipline the chat lane uses.
    static let sshBrokerProbe: @Sendable (String, (any Transport)?) async -> Bool = { socketPath, transport in
        guard let ssh = transport as? HeelerSSHTransport else { return false }
        do {
            _ = try await ssh.openBrokerChannel(socketPath: socketPath)
            return true
        } catch {
            return false
        }
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
            // Plugin-era detect: resolve the standard path host-side and
            // probe it with a REAL broker hello. A broker answering at
            // the standard path means the plugin already owns a live one
            // — the only question left is whether the Host record points
            // at it yet (the auto-configure or this flow writes it).
            guard let resolved = try await resolveHostSocketPath() else {
                phase = .failed(
                    message: "Could not resolve the Meadow socket path on the Host.")
                return
            }
            resolvedSocketPath = resolved
            if await brokerAnswers() {
                try writeHostRecord(socketPath: resolved)
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
    /// this Host?" confirmation. Re-targeted to the consolidation: the
    /// heeler PLUGIN owns the broker (single instance, standard path,
    /// `heeler.setup` action), so this step INVOKE'S THE PLUGIN'S SETUP
    /// SURFACE over the SSH exec seam — never an app-side package
    /// install (superseded). Then: re-probe the standard socket, write
    /// the Host record, land on the restart decision with the agent list.
    func provision() async {
        guard phase == .offering, let transport else { return }
        phase = .provisioning
        do {
            // 1. The plugin's one coherent setup surface: installs the
            //    runtime, starts the shared broker, installs adapter
            //    shims. herdr is on PATH through the exec wrapper's
            //    install prefixes; the plugin action blocks to
            //    completion and its exit code carries the verdict.
            let setup = try await transport.runProvisioningCommand(
                "herdr plugin action invoke heeler.setup")
            guard setup.exitStatus == 0 else {
                throw BrokerProvisioningError.commandFailed(
                    detail: "heeler.setup exited \(setup.exitStatus): \(setup.trimmedText)")
            }
            // 2. Re-probe: the standard path must answer a REAL hello.
            guard let resolved = try await resolveHostSocketPath() else {
                throw BrokerProvisioningError.commandFailed(
                    detail: "Could not resolve the Meadow socket path on the Host.")
            }
            resolvedSocketPath = resolved
            guard try await brokerAnswers() else {
                throw BrokerProvisioningError.commandFailed(
                    detail: "The broker did not come up at \(resolved).")
            }
            // 3. Publish to the Host record: the chat lane connects with
            //    no manual edit.
            try writeHostRecord(socketPath: resolved)
            let agents = try await restartableAgents()
            phase = .restartDecision(agents: agents)
        } catch let error as BrokerProvisioningError {
            phase = .failed(message: error.userMessage)
        } catch {
            phase = .failed(message: String(describing: error))
        }
    }

    /// Wire-level probe: a real broker hello at the resolved path through
    /// the flow's SSH transport (direct-streamlocal, the same channel the
    /// chat lane uses).
    private func brokerAnswers() async -> Bool {
        guard let resolved = resolvedSocketPath else { return false }
        return await brokerProbe(resolved, transport)
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
