import Observation
import SwiftUI

/// Drives one Host's route surface: the selection setting, the priority
/// list with probe statuses, the manual pin, the "Check routes" sweep,
/// and the failure offer (Try another route / Return to automatic).
///
/// Rendering is pure policy (`HostRoutePolicy`); this store owns the
/// imperative edges: probing (bounded, configured endpoints only),
/// retrying the Host through the Console, and persisting pin/unpin.
@MainActor
@Observable
final class HostRouteStatusStore {
    let host: Host
    private(set) var probes: [String: HostRouteProbeResult] = [:]
    private(set) var network: HostRouteNetworkState
    private(set) var isProbing = false
    private(set) var lastFailure: TransportError?

    @ObservationIgnored private let prober: HostRouteProber
    @ObservationIgnored private let monitor: HostRouteMonitor?
    @ObservationIgnored private let retryConnection: (@MainActor @Sendable () async -> Void)?
    @ObservationIgnored private let catalog: HostStore?

    init(
        host: Host,
        network: HostRouteNetworkState = .offline,
        prober: HostRouteProber,
        monitor: HostRouteMonitor? = nil,
        catalog: HostStore? = nil,
        retryConnection: (@MainActor @Sendable () async -> Void)? = nil,
        /// Pre-seeded probe results (demo screenshots; empty in
        /// production, where results only ever come from real probes).
        seededProbes: [String: HostRouteProbeResult] = [:]
    ) {
        self.host = host
        self.network = network
        self.prober = prober
        self.monitor = monitor
        self.catalog = catalog
        self.retryConnection = retryConnection
        self.probes = seededProbes
    }

    /// The design contract's "Check routes": one bounded sweep of the
    /// configured routes in priority order.
    func checkRoutes() async {
        await prober.probe(addresses: host.candidateAddresses, host: host)
        probes = prober.results
        isProbing = false
    }

    /// "Choose manually" → pin one route. Persists immediately; the pin
    /// is never silently overridden, and it dials exactly its address
    /// through the dial plan.
    func pin(_ address: String) throws {
        guard let catalog else { return }
        var updated = host
        updated.routeSelection = .manual(address: address)
        try catalog.update(updated)
    }

    /// "Return to automatic": drops the pin. The next connect follows the
    /// saved priority order.
    func returnToAutomatic() throws {
        guard let catalog else { return }
        var updated = host
        updated.routeSelection = .automatic
        try catalog.update(updated)
    }

    /// "Try another route": pin the choice and retry the Host connection.
    /// The retry observes the pin through the dial plan — a pinned dial
    /// never fails over.
    func tryRoute(_ address: String) async throws {
        try pin(address)
        await retryConnection?()
    }

    /// The foreground/reconnect recheck: one sweep while the surface is
    /// visible. No continuous background promises — the sweep runs
    /// because the user is looking at the surface or came back to it.
    func recheckOnForeground() async {
        guard !isProbing else { return }
        await checkRoutes()
    }

}
