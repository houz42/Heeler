import Foundation

/// Opens a connected Transport for the given settings: the seam between UI
/// stores and real SSH. Production is `SSHTransportConnector`; tests inject
/// a scripted fake, so screen logic never touches an SSH library (ADR 0011).
protocol TransportConnector: Sendable {
    func connect(settings: SSHTransportSettings) async throws -> any Transport

    /// Connects, reporting the winning candidate address to `onCandidate`
    /// when the settings carry more than one way to reach the Host.
    /// Connectors that dial only `host` (every test fake) use the default,
    /// which connects without reporting.
    func connect(
        settings: SSHTransportSettings,
        onCandidate: (@Sendable (CandidateDialResult) -> Void)?
    ) async throws -> any Transport
}

extension TransportConnector {
    func connect(
        settings: SSHTransportSettings,
        onCandidate: (@Sendable (CandidateDialResult) -> Void)?
    ) async throws -> any Transport {
        _ = onCandidate
        return try await connect(settings: settings)
    }
}

/// One dial outcome: which candidate address actually answered. Preflight
/// reports it to the user; callers that only need a Transport may ignore it.
struct CandidateDialResult: Sendable, Equatable {
    /// The address whose connection attempt succeeded.
    let address: String
    /// How many addresses were tried before this one succeeded. 0 means the
    /// stored default connected on the first try.
    let failedAttempts: Int
}

/// The one production SSH backend: libssh2 reaching the herdr socket over
/// direct-streamlocal (ADR 0011). There is deliberately no second path — a
/// Host that denies stream-local forwarding is a server policy to fix, not a
/// case to fall back from.
///
/// Multi-candidate dials: when the settings carry more than one address,
/// each attempt is bounded by ``perCandidateTimeout`` so an unreachable
/// first path fails over in seconds instead of waiting out the full request
/// timeout. The first candidate that connects wins.
struct SSHTransportConnector: TransportConnector {
    /// Connection budget per candidate address, covering TCP establishment
    /// and the SSH handshake. Unreachable paths fail over in roughly this
    /// budget; a healthy path never feels it.
    var perCandidateTimeout: Duration = .seconds(4)

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        try await connect(settings: settings, onCandidate: nil)
    }

    func connect(
        settings: SSHTransportSettings,
        onCandidate: (@Sendable (CandidateDialResult) -> Void)?
    ) async throws -> any Transport {
        try await Self.dialFirstReachable(
            settings: settings,
            perCandidateTimeout: perCandidateTimeout,
            dialOne: { try await HeelerSSHTransport.connect(settings: $0) },
            onCandidate: onCandidate)
    }

    /// Dials `settings.dialCandidates` in order and returns the first
    /// transport that answers. `dialOne` is the one-address dial — real SSH
    /// in production, a scripted stub in tests — so ordering and failover
    /// are testable without a network.
    ///
    /// Reach-class failures (`TransportError.isReachFailure`) fail over to
    /// the next address; trust, authentication, and policy failures stop
    /// the loop, because retrying them on another address of the same
    /// machine cannot change the answer. When every candidate was tried and
    /// none answered, the failure names each path in one diagnostic line.
    static func dialFirstReachable(
        settings: SSHTransportSettings,
        perCandidateTimeout: Duration,
        dialOne: @escaping @Sendable (SSHTransportSettings) async throws -> any Transport,
        onCandidate: (@Sendable (CandidateDialResult) -> Void)?
    ) async throws -> any Transport {
        let candidates = settings.dialCandidates
        var attempts: [String] = []
        for (index, address) in candidates.enumerated() {
            var candidateSettings = settings
            candidateSettings.host = address
            candidateSettings.candidateAddresses = []
            // A multi-address Host dials each path with the short budget so
            // an unreachable path cannot eat the whole request timeout; a
            // single-address Host keeps the ordinary timeout.
            if candidates.count > 1 {
                candidateSettings.requestTimeout = perCandidateTimeout
            }
            do {
                let transport = try await dialOne(candidateSettings)
                onCandidate?(CandidateDialResult(
                    address: address,
                    failedAttempts: attempts.count))
                return transport
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TransportError where error.isReachFailure {
                attempts.append("\(address): \(error.dialFailureDetail)")
                continue
            }
        }
        throw TransportError.sshUnreachable(
            detail: attempts.isEmpty
                ? "No address to dial."
                : "None of this Host's addresses answered. "
                    + attempts.joined(separator: "; "))
    }
}

extension TransportError {
    /// Whether a failed dial of one candidate address justifies trying the
    /// next path. Reach-class failures do — the machine is simply not
    /// answering on this path. Trust, authentication, and policy failures
    /// are about the Host itself and stop failover: retrying them on another
    /// address of the same machine cannot change the answer.
    var isReachFailure: Bool {
        switch self {
        case .sshUnreachable, .timedOut:
            return true
        case .jumpHostFailed(let underlying):
            // The Jump Host is part of the path; an unreachable first hop
            // says nothing about the Host on the other address.
            return underlying.isReachFailure
        default:
            return false
        }
    }

    /// One diagnostic line for a failed candidate dial, shared by the
    /// attempt log and the aggregate unreachable detail.
    var dialFailureDetail: String {
        switch self {
        case .sshUnreachable(let detail):
            return detail
        case .timedOut:
            return "did not answer within the per-address budget"
        case .jumpHostFailed(let underlying):
            return "jump host: \(underlying.dialFailureDetail)"
        default:
            return String(describing: self)
        }
    }
}

extension SSHTransportSettings {
    /// The dialing order: `host` first, then each additional address in
    /// order, trimmed; empty entries dropped.
    var dialCandidates: [String] {
        ([host] + candidateAddresses)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension SSHTransportSettings {
    /// Transport settings for a catalog Host, given resolved credentials and
    /// the TOFU policy the UI wires up. The Host's port applies to every
    /// candidate address: they name the same sshd on the same machine.
    ///
    /// v2 route selection — THE dial plan, applied to every real dial:
    /// a manual pin narrows the dial to exactly the pinned address
    /// (honored VERBATIM, never silently overridden; its failure is the
    /// pinned route's failure, surfaced as Try another route / Return to
    /// automatic, never a failover); under Automatic the dialing order is
    /// the saved priority (the v1 preferred pick still leads it) with
    /// eligibility gates applied against the CURRENT network hint — a
    /// Wi-Fi-only route is skipped while the path does not classify as
    /// Wi-Fi. The hint is a gate, not a proof; the dial remains the real
    /// proof.
    init(host: Host, credentials: SSHCredentials, hostKeyPolicy: HostKeyPolicy) {
        let preferred = PreferredAddressStore(hostID: host.id)
        let network = HostRouteNetworkSnapshot.current
        // Automatic's order: the v1 preferred pick leads the saved
        // priority; eligibility prunes. A pin replaces the whole list.
        let automaticOrder = preferred
            .preferredOrder(
                forCandidates: host.candidateAddresses, pinnedAddress: nil)
            .filter { address in
                HostRoutePolicy.isEligible(
                    host.routeEligibility(for: address), network: network)
            }
        let order =
            if let pinned = host.pinnedRouteAddress {
                [pinned]
            } else {
                automaticOrder
            }
        self.init(
            host: order.first ?? host.address,
            candidateAddresses: Array(order.dropFirst()),
            port: host.port,
            username: host.username,
            credentials: credentials,
            hostKeyPolicy: hostKeyPolicy,
            socket: host.socketLocation,
            // Both hops use the Host's resolved credential. Device Key is the
            // normal case; password Hosts require the same password at both hops.
            jump: host.usesJumpHost
                ? SSHJumpSettings(
                    host: host.jumpAddress.trimmingCharacters(in: .whitespaces),
                    port: host.jumpPort,
                    username: host.resolvedJumpUsername,
                    credentials: credentials)
                : nil)
    }
}
