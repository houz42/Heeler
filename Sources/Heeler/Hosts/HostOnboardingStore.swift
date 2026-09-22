import Foundation
import Observation

/// A verified mismatch awaiting the user's explicit decision to replace the
/// trusted pin. Merely observing a mismatch never mutates the known-hosts store.
struct HostKeyReplacement: Equatable, Sendable {
    let known: HostKeyFingerprint
    let presented: HostKeyFingerprint
}

/// Where one candidate address stands in an interactive probe sweep.
enum CandidateProbeState: Equatable, Sendable {
    /// Not probed yet in this sweep.
    case unknown
    /// The probe for this address is in flight.
    case probing
    /// The address answered an SSH handshake.
    case reachable
    /// The address did not answer within the probe budget.
    case unreachable
}

/// Drives one Host's onboarding preflight (#14): resolve credentials,
/// connect (surfacing the TOFU first-connect prompt), discover sessions,
/// ping the selected session, and render the outcome as the checklist.
///
/// Multi-path Hosts get an interactive probe sweep before connecting:
/// candidates are probed one by one (states published live), then exactly
/// one reachable address connects directly while several reachable ones
/// stop for the user's pick — the pick persists as the preferred dial order
/// (`PreferredAddressStore`) so the next run dials it first.
@MainActor
@Observable
final class HostOnboardingStore {
    enum Phase: Equatable {
        case idle
        case running
        /// Probing candidate addresses one by one before connecting.
        case probing
        case finished
    }

    private(set) var phase: Phase = .idle
    /// Set while the transport waits on the user's first-connect trust
    /// decision; the UI renders it as the fingerprint confirmation sheet.
    private(set) var pendingFingerprint: HostKeyCandidate?
    /// Set only after a hard-failed mismatch, for the UI's explicit re-trust
    /// flow. The old pin remains authoritative until the user confirms.
    private(set) var pendingHostKeyReplacement: HostKeyReplacement?
    private(set) var report: PreflightReport?
    private(set) var serverInfo: ServerInfo?
    /// Which candidate address the NEXT dial leads with: the persisted
    /// preferred path, falling back to the configured default. Published
    /// so the detail's route rows re-render the active mark the moment a
    /// tap lands. The live session's dialed route is a different fact —
    /// see the view's `connectedAddress`.
    private(set) var preferredRoute: String

    private(set) var workingAddress: CandidateDialResult?
    private(set) var availableSessions: [HerdrSession] = []
    private(set) var sessionDiscoveryError: String?
    /// Live state per candidate address during a probe sweep, in dialing
    /// order. Empty outside a sweep; the UI renders the Address section
    /// from it.
    private(set) var candidateStates: [String: CandidateProbeState] = [:]
    /// Set when a probe sweep found MORE THAN ONE reachable address and the
    /// user must choose one; the UI renders it as a tappable list.
    private(set) var pendingAddressChoice: [String]?

    let host: Host

    @ObservationIgnored private let connector: any TransportConnector
    @ObservationIgnored private let knownHosts: any KnownHostsStore
    @ObservationIgnored private let credentials: HostCredentialsProvider
    @ObservationIgnored private let preferredAddresses: PreferredAddressStore
    /// The transport deliberately has no confirmation timeout (#2); the UI
    /// layer owns it (spec #20). An unanswered candidate is declined.
    @ObservationIgnored private let fingerprintTimeout: Duration
    /// Broadcasts active-route writes so the Hosts list's marks re-render
    /// in the same turn (nil in tests/demo compositions — the store's own
    /// persistence still lands on the shared disk copy).
    @ObservationIgnored private let activeRouteBroadcaster: HostActiveRouteStore?
    @ObservationIgnored private var fingerprintDecision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var fingerprintTimeoutTask: Task<Void, Never>?

    init(
        host: Host,
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        // Callers build this keyed to `host.id` (the UI from the Host, tests
        // from a volatile defaults suite); there is no default because the
        // key depends on the Host.
        preferredAddresses: PreferredAddressStore,
        /// The process-wide observable active-route store: detail taps
        /// broadcast through it so the Hosts list's marks re-render in
        /// the same turn. nil (tests, demo compositions) keeps the
        /// store's own persistence only.
        activeRouteBroadcaster: HostActiveRouteStore? = nil,
        fingerprintTimeout: Duration = .seconds(60)
    ) {
        self.host = host
        self.connector = connector
        self.knownHosts = knownHosts
        self.credentials = credentials
        self.preferredAddresses = preferredAddresses
        self.activeRouteBroadcaster = activeRouteBroadcaster
        self.fingerprintTimeout = fingerprintTimeout
        // The persisted pick, if any, is already on disk; read it once so
        // the detail renders the active mark without a probe first.
        self.preferredRoute =
            preferredAddresses.preferredOrder(for: host.candidateAddresses).first
            ?? host.address
    }

    /// The addresses to render and probe: the Host's candidates in the
    /// preferred dial order (a stored pick moves its address first).
    var orderedCandidates: [String] {
        preferredAddresses.preferredOrder(for: host.candidateAddresses)
    }

    /// Re-reads the persisted active route (the SAME source the Hosts
    /// list renders and the dial consumes). The list's route tap writes
    /// it out-of-band through the Console, so an open detail page
    /// reconciles against the shared store whenever its parent's
    /// console-derived active-route input changes — the two pages can
    /// never disagree for longer than one render.
    func syncPreferredRoute() {
        preferredRoute =
            preferredAddresses.preferredOrder(for: host.candidateAddresses).first
            ?? host.address
    }

    /// TAP = SWITCH, one half of the unified action (identical on the
    /// list and here): persists `address` as the Host's active route —
    /// the path the next dial leads with (the same `PreferredAddressStore`
    /// order the real dial consumes via `SSHTransportSettings.init(host:)`)
    /// — and broadcasts through the shared store. The dial itself is the
    /// VIEW's second half (the Console retry, the same path a list-card
    /// tap and a Reconnect press take); the store layer owns no Console.
    /// Reversible by tapping another route; a no-op on an address the
    /// Host no longer carries.
    func setActiveRoute(_ address: String) {
        guard host.candidateAddresses.contains(address) else { return }
        preferredAddresses.prefer(address, candidates: host.candidateAddresses)
        preferredRoute = address
        // Same write through the shared observable store: the Hosts
        // list's active-route marks re-render in this same turn.
        activeRouteBroadcaster?.setActiveRoute(
            address, hostID: host.id, candidates: host.candidateAddresses)
    }

    /// Runs the preflight once: probe when the Host has several candidates
    /// and no working state yet, then connect + ping, rendered into `report`.
    func runChecks() async {
        guard phase != .running, phase != .probing else { return }
        pendingAddressChoice = nil
        // Credential failures (no password, corrupt Device Key) fail every
        // candidate identically; surface them before a sweep so the hint
        // names the credential problem, not "unreachable addresses".
        if let failure = credentialsFailureReport() {
            phase = .running
            candidateStates = [:]
            report = failure
            phase = .finished
            return
        }
        let candidates = orderedCandidates
        if candidates.count > 1 {
            await probeThenConnect(candidates: candidates)
        } else {
            candidateStates = [:]
            await connectAndCheck(settingsHost: candidates.first ?? host.address)
        }
    }

    /// The user chose `address` — the initial pick between several
    /// reachable paths, or a later switch to a different reachable row
    /// (Use stays available on every reachable row that is not the live
    /// connection). Either way: persist it as the preferred order and
    /// connect through it.
    func chooseAddress(_ address: String) async {
        guard host.candidateAddresses.contains(address) else { return }
        pendingAddressChoice = nil
        preferredAddresses.prefer(address, candidates: orderedCandidates)
        preferredRoute = address
        // Same write through the shared observable store (see
        // `setActiveRoute`): the list's marks move in the same turn.
        activeRouteBroadcaster?.setActiveRoute(
            address, hostID: host.id, candidates: host.candidateAddresses)
        candidateStates[address] = .reachable
        await connectAndCheck(settingsHost: address)
    }

    /// The user's verdict on the pending fingerprint.
    func confirmFingerprint(trusted: Bool) {
        resolveFingerprint(trusted)
    }

    /// Persists a discovered session through the Host catalog. The enclosing
    /// navigation destination is keyed by the Host value, so this recreates
    /// onboarding and immediately checks the selected socket.
    func selectSession(_ session: HerdrSession, in catalog: HostStore) throws {
        var updated = host
        updated.sessionName = session.isDefault ? "" : session.name
        try catalog.update(updated)
    }

    /// Replaces a mismatched pin only after the UI has obtained an explicit
    /// confirmation, then immediately proves the new pin by rerunning preflight.
    func trustPresentedHostKey() async {
        guard phase != .running, phase != .probing,
            let replacement = pendingHostKeyReplacement
        else { return }
        try? await knownHosts.setFingerprint(
            replacement.presented, host: host.address, port: host.port)
        await runChecks()
    }

    // MARK: Probe sweep

    /// Probes candidates one by one, publishing live states, then either
    /// auto-connects (exactly one reachable), stops for the user's pick
    /// (more than one), or fails (none).
    private func probeThenConnect(candidates: [String]) async {
        phase = .probing
        report = nil
        serverInfo = nil
        workingAddress = nil
        availableSessions = []
        sessionDiscoveryError = nil
        pendingHostKeyReplacement = nil
        candidateStates = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0, CandidateProbeState.unknown) })

        var reachable: [String] = []
        for address in candidates {
            candidateStates[address] = .probing
            if await probeOne(address: address) {
                candidateStates[address] = .reachable
                reachable.append(address)
            } else {
                candidateStates[address] = .unreachable
            }
        }

        switch reachable.count {
        case 0:
            phase = .finished
            report = .failure(
                check: .connection,
                hint: "None of this Host's addresses could be reached. "
                    + "Check the addresses and the network path to them.")
        case 1:
            // Exactly one path works: use it, like the automatic dialer.
            await connectAndCheck(settingsHost: reachable[0])
        default:
            // Several paths work: the user knows which one they want (the
            // cheap LAN hop over the metered VPN, say). Stop and ask.
            phase = .finished
            pendingAddressChoice = reachable
        }
    }

    /// One connect-only probe of `address`. True when the SSH handshake
    /// answered; failures of any other class (auth, trust) still prove the
    /// path itself works, so they count as reachable too — the subsequent
    /// full connect reports them with proper guidance.
    private func probeOne(address: String) async -> Bool {
        guard let resolved = try? credentials.credentials(for: host) else { return false }
        // No TOFU prompt from a probe: keys not already trusted fail the
        // probe quietly; the full connect owns the trust conversation.
        let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in false }
        var settings = SSHTransportSettings(
            host: host, credentials: resolved, hostKeyPolicy: policy)
        settings.host = address
        settings.candidateAddresses = []
        do {
            let transport = try await connector.connect(settings: settings)
            try? await transport.close()
            return true
        } catch is CancellationError {
            return false
        } catch {
            // Reach-class failures mean the path is down; anything else
            // (auth rejected, unknown host key) still proves the path
            // carries SSH traffic, so the address is reachable.
            if let transportError = error as? TransportError,
                transportError.isReachFailure
            {
                return false
            }
            return true
        }
    }

    // MARK: Full connect + checks

    private func connectAndCheck(settingsHost: String) async {
        phase = .running
        report = nil
        serverInfo = nil
        workingAddress = nil
        availableSessions = []
        sessionDiscoveryError = nil
        pendingHostKeyReplacement = nil
        defer { phase = .finished }

        guard let resolved = resolveCredentials() else { return }

        let policy = HostKeyPolicy(knownHosts: knownHosts) { [weak self] candidate in
            await self?.awaitFingerprintDecision(for: candidate) ?? false
        }
        var settings = SSHTransportSettings(
            host: host, credentials: resolved, hostKeyPolicy: policy)
        settings.host = settingsHost
        settings.candidateAddresses = []
        do {
            let transport = try await connector.connect(settings: settings)
            workingAddress = CandidateDialResult(
                address: settingsHost, failedAttempts: 0)
            do {
                availableSessions = try await transport.listSessions()
            } catch {
                sessionDiscoveryError = "Could not discover herdr sessions. You can still enter a session name manually."
            }
            do {
                serverInfo = try await transport.ping()
                report = .allPassed
            } catch {
                captureHostKeyReplacement(error)
                report = failureReport(error)
            }
            // Preflight only probes; the Console owns long-lived connections.
            try? await transport.close()
        } catch {
            captureHostKeyReplacement(error)
            report = failureReport(error)
        }
    }

    /// Resolves credentials, or nil with `report` set to the credential
    /// failure. Shared by the sweep pre-check and the full connect: the
    /// failure report proves `credentials(for:)` succeeds before the second
    /// call runs, so the fallback is unreachable in practice.
    @discardableResult
    private func resolveCredentials() -> SSHCredentials? {
        if let failure = credentialsFailureReport() {
            report = failure
            return nil
        }
        do {
            return try credentials.credentials(for: host)
        } catch {
            report = .failure(
                check: .connection,
                hint: "Could not load this Host's credentials. (\(error))")
            return nil
        }
    }

    /// The credential failure that blocks any candidate from connecting, or
    /// nil when credentials resolve. Same hints as the pre-multi-path flow.
    private func credentialsFailureReport() -> PreflightReport? {
        do {
            _ = try credentials.credentials(for: host)
            return nil
        } catch HostCredentialsError.passwordNotSet {
            return .failure(
                check: .connection,
                hint: "No password is saved for this Host. Edit the Host and enter one.")
        } catch DeviceKeyStoreError.storedKeyCorrupt {
            return .failure(.deviceKeyCorrupt, authMethod: host.authMethod)
        } catch {
            return .failure(
                check: .connection,
                hint: "Could not load this Host's credentials. (\(error))")
        }
    }

    private func captureHostKeyReplacement(_ error: any Error) {
        guard case let TransportError.hostKeyMismatch(known, presented) = error else { return }
        pendingHostKeyReplacement = HostKeyReplacement(known: known, presented: presented)
    }

    private func failureReport(_ error: any Error) -> PreflightReport {
        if let transportError = error as? TransportError {
            .failure(transportError, authMethod: host.authMethod)
        } else {
            .failure(
                check: .connection,
                hint: "The connection failed unexpectedly. (\(error))")
        }
    }

    private func awaitFingerprintDecision(for candidate: HostKeyCandidate) async -> Bool {
        // One connect per run means one candidate at a time; decline a
        // second defensively instead of leaking the first continuation.
        guard fingerprintDecision == nil else { return false }
        pendingFingerprint = candidate
        return await withCheckedContinuation { continuation in
            fingerprintDecision = continuation
            fingerprintTimeoutTask = Task { [fingerprintTimeout] in
                try? await Task.sleep(for: fingerprintTimeout)
                guard !Task.isCancelled else { return }
                self.resolveFingerprint(false)
            }
        }
    }

    private func resolveFingerprint(_ trusted: Bool) {
        guard let decision = fingerprintDecision else { return }
        fingerprintDecision = nil
        fingerprintTimeoutTask?.cancel()
        fingerprintTimeoutTask = nil
        pendingFingerprint = nil
        decision.resume(returning: trusted)
    }

    #if DEBUG && targetEnvironment(simulator)
        /// Screenshot-only: pins the candidate probe states so the demo
        /// capture shows a deterministic mid-sweep or resolved list. Never
        /// compiled into device or Release builds.
        func scriptProbeStatesForDemo(_ states: [String: CandidateProbeState]) {
            candidateStates = states
            phase = states.values.contains(.probing) ? .probing : .finished
        }

        /// Screenshot-only: pins the pick-between-reachable stop state.
        func scriptAddressChoiceForDemo(_ choices: [String]) {
            pendingAddressChoice = choices
            phase = .finished
        }
    #endif
}
