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
    /// Actionable explanation when a check could not even start
    /// (credential failures are about the Host, not the path). nil while
    /// checks ran. The user's press must never appear to do nothing.
    private(set) var checkFailedExplanation: String?

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

    /// Syncs the store's network state from the shared monitor — the
    /// route surface's rows and result line always read the CURRENT
    /// hint, never a stale `.offline`.
    func syncNetworkFromMonitor() {
        guard monitor == nil else { return }
        network = HostRouteNetworkSnapshot.current
    }

    /// The design contract's "Check routes": one bounded sweep of the
    /// configured routes in priority order. The busy state is owned HERE
    /// (overlapping presses are refused rather than serialized), and
    /// results land per-route as the sweep goes — the caller observing
    /// `probes` sees each route's verdict the moment it concludes, never
    /// an all-or-nothing snapshot at the end.
    func checkRoutes() async {
        guard !isProbing else { return }
        isProbing = true
        checkFailedExplanation = nil
        do {
            try await prober.probe(addresses: host.candidateAddresses, host: host) {
                [weak self] address, result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // A result for an address this Host no longer
                    // carries (edited mid-sweep) is dropped, never
                    // resurrected.
                    guard self.host.candidateAddresses.contains(address) else { return }
                    self.probes[address] = result
                }
            }
        } catch HostCredentialsError.passwordNotSet {
            checkFailedExplanation =
                "The check could not run: no password is saved for \(host.displayAliasName)."
        } catch DeviceKeyStoreError.storedKeyCorrupt {
            checkFailedExplanation =
                "The check could not run: the Device Key could not be loaded. "
                + "Open Edit and replace it if it is corrupt."
        } catch {
            checkFailedExplanation =
                "The check could not run: \(host.displayAliasName)'s credentials "
                + "could not be loaded."
        }
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

    /// The foreground/reconnect recheck: refresh the network hint, run
    /// one bounded sweep, and — when the Host is NOT connected and the
    /// sweep found a route reachable — redial through the policy's dial
    /// plan (the retry runs through the same `SSHTransportSettings`
    /// every dial uses, so eligibility and the pin are honored). No
    /// continuous background promises: this fires because the user came
    /// back. A connected Host is never re-dialed — stickiness.
    func recheckOnForeground(isConnected: Bool) async {
        guard !isProbing else { return }
        syncNetworkFromMonitor()
        await checkRoutes()
        guard !isConnected,
            probes.values.contains(where: { $0.outcome.provesPathCarriesSSH }),
            let retryConnection
        else { return }
        await retryConnection()
    }
}
