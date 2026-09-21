import Foundation
import Synchronization
import Network

/// Runs the bounded route probes and folds their results. One probe =
/// the v1 reach-probe semantics: a connect-only dial of EXACTLY the
/// configured address (a `SSHTransportConnector` dial with the short
/// per-candidate budget), never a network scan. Auth/trust failures
/// classify as themselves via `HostRoutePolicy.classifyProbeOutcome`.
///
/// `@MainActor` because it publishes live state for the route surface
/// and serializes its sweeps; the dials themselves run inside the
/// connector's task.
@MainActor
@Observable
final class HostRouteProber {
    /// Published live results per address.
    private(set) var results: [String: HostRouteProbeResult] = [:]
    /// True while a sweep is in flight.
    private(set) var isProbing = false

    private let connector: any TransportConnector
    private let credentials: HostCredentialsProvider
    private let knownHosts: any KnownHostsStore
    private let now: @MainActor @Sendable () -> Date
    private let probeTimeout: Duration
    // (No sweep task: the sweep runs inline inside `probe`, so a caller
    // observing `results` never sees a half-finished set.)

    init(
        connector: any TransportConnector = SSHTransportConnector(),
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        probeTimeout: Duration = .seconds(4),
        now: @escaping @MainActor @Sendable () -> Date = { Date() }
    ) {
        self.connector = connector
        self.credentials = credentials
        self.knownHosts = knownHosts
        self.probeTimeout = probeTimeout
        self.now = now
    }

    /// Probes the configured routes in priority order, reporting each
    /// result to `onResult` THE MOMENT it concludes (per-route
    /// freshness), and returning only when every bounded dial has
    /// concluded. Probes ONLY configured endpoints — the routes the Host
    /// names, never a discovered network range. Throws the Host's
    /// credential error BEFORE dialing anything when credentials do not
    /// resolve: a credential failure is about the Host, not the path,
    /// and must surface as the sweep's explanation, not as three
    /// identical "unknown" rows.
    func probe(
        addresses: [String],
        host: Host,
        onResult: (@Sendable (String, HostRouteProbeResult) -> Void)? = nil
    ) async throws {
        results = [:]
        isProbing = true
        let resolved = try credentials.credentials(for: host)
        let clock = ContinuousClock()
        for address in addresses {
            let start = clock.now
            let outcome = await probeOne(
                address: address, host: host, credentials: resolved)
            let result = HostRouteProbeResult(
                outcome: outcome,
                checkedAt: now(),
                latency: outcome == .reachable ? clock.now - start : nil)
            results[address] = result
            onResult?(address, result)
        }
        isProbing = false
    }

    /// One bounded probe of one configured address. Reach-class failures
    /// are unreachable; auth/trust failures prove the path and are
    /// reported as themselves.
    private func probeOne(
        address: String, host: Host, credentials resolved: SSHCredentials
    ) async -> HostRouteProbeResult.Outcome {
        // No TOFU prompt from a probe: keys not already trusted fail the
        // probe quietly; the full connect owns the trust conversation.
        let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in false }
        var settings = SSHTransportSettings(
            host: host, credentials: resolved, hostKeyPolicy: policy)
        settings.host = address
        settings.candidateAddresses = []
        settings.requestTimeout = probeTimeout
        do {
            let transport = try await connector.connect(settings: settings)
            try? await transport.close()
            return .reachable
        } catch is CancellationError {
            return .unknown
        } catch {
            return HostRoutePolicy.classifyProbeOutcome(error: error)
        }
    }
}

/// Watches the network path and hands route consumers a coalesced
/// `HostRouteNetworkState`. NWPathMonitor semantics per the design
/// contract: a satisfied path means a network path exists, not that any
/// particular SSH endpoint is reachable; interface types are hints, not
/// proofs of VPN state. Path changes are coalesced with a debounced
/// notification so a burst of transitions yields one state update.
@MainActor
@Observable
final class HostRouteMonitor {
    /// Latest observed state; starts offline until the first path event.
    private(set) var network: HostRouteNetworkState = .offline
    /// Increments once per coalesced path-change notification.
    private(set) var changeRevision: UInt64 = 0

    private let pathUpdate: (@MainActor @Sendable (HostRouteNetworkState) -> Void)?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?
    @ObservationIgnored private let coalesceWindow: Duration

    init(
        coalesceWindow: Duration = .milliseconds(500),
        onPathUpdate: (@MainActor @Sendable (HostRouteNetworkState) -> Void)? = nil
    ) {
        self.coalesceWindow = coalesceWindow
        self.pathUpdate = onPathUpdate
    }

    /// Starts observing the default path. Idempotent.
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let state = Self.state(from: path)
            Task { @MainActor [weak self] in
                self?.handle(state)
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.houz42.heeler.route-monitor"))
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        coalesceTask?.cancel()
        coalesceTask = nil
    }

    private func handle(_ state: HostRouteNetworkState) {
        guard state != network else { return }
        network = state
        // Coalesce bursts: one trailing notification per window.
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.coalesceWindow ?? .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            // The dial path (any executor) reads this snapshot; keep it
            // in lockstep with the published state.
            HostRouteNetworkSnapshot.update(self.network)
            self.changeRevision &+= 1
            self.pathUpdate?(self.network)
        }
    }

    /// Reduces an NWPath to the two facts route decisions may consume.
    /// `other` classifies as not-Wi-Fi — deliberately: the design
    /// contract forbids inferring which VPN is active from the interface
    /// type, and "not provably Wi-Fi" is the honest hint.
    nonisolated static func state(from path: NWPath) -> HostRouteNetworkState {
        HostRouteNetworkState(
            isSatisfied: path.status == .satisfied,
            isWiFiHint: path.usesInterfaceType(.wifi))
    }
}

/// The process-wide latest network state, readable from ANY executor
/// (the dial path runs off the main actor). Written only by
/// `HostRouteMonitor`; read by `SSHTransportSettings(host:)` so every
/// real dial is eligibility-gated against the CURRENT network hint.
/// Offline until the first path event lands — the conservative default:
/// a Wi-Fi-only route does not dial before the hint says Wi-Fi, and an
/// Any-network route is unaffected (the gate only restricts wifiOnly).
enum HostRouteNetworkSnapshot {
    private static let state = Mutex<HostRouteNetworkState>(.offline)

    /// The latest coalesced network state.
    static var current: HostRouteNetworkState {
        state.withLock { $0 }
    }

    static func update(_ new: HostRouteNetworkState) {
        state.withLock { $0 = new }
    }
}

extension HostRouteMonitor {
    /// The shared process monitor. Started by the app model; the route
    /// surface observes it, and every dial reads its snapshot.
    @MainActor static let shared = HostRouteMonitor()
}
