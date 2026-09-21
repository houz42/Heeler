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
    /// The re-evaluation cooldown in force (the policy's bounded
    /// backoff: doubling while no route answers, reset on a reachable
    /// verdict). Consumed by the path-change re-evaluation so a burst
    /// of transitions yields one evaluation, and consecutive failing
    /// evaluations back off instead of flapping.
    @ObservationIgnored private var cooldown = HostRoutePolicy.baseCooldown
    /// Observes the shared monitor's coalesced path changes while this
    /// store lives; cancelled in deinit.
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
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

    deinit {
        monitorTask?.cancel()
    }

    /// Syncs the store's network state from the process-wide snapshot —
    /// the route surface's rows and result line always read the CURRENT
    /// hint, never a stale `.offline`. Runs on appear and on every
    /// coalesced path change. Demo stores (no monitor) keep their
    /// seeded state: the demo never starts the shared monitor, so the
    /// pre-first-event `.offline` snapshot must not clobber the fixture.
    func syncNetworkFromMonitor() {
        guard monitor != nil else { return }
        network = HostRouteNetworkSnapshot.current
    }

    /// Starts observing the shared monitor's COALESCED path changes:
    /// each transition updates `network` (the surface re-renders its
    /// Skipped/eligible rows honestly) and, per the policy's
    /// re-evaluation gate, an UNCONNECTED host re-evaluates with the
    /// cooldown backoff — this is also the recovery path for the
    /// all-ineligible off-Wi-Fi state: when Wi-Fi arrives, the gated
    /// routes become eligible and the host redials through the plan.
    /// A CONNECTED host never re-evaluates (stickiness). No continuous
    /// background promises — the monitor is passive and the store lives
    /// only while a route surface is on screen.
    func observePathChanges(isConnected: @escaping @MainActor () -> Bool) {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.monitorPathStream() {
                self.syncNetworkFromMonitor()
                guard HostRoutePolicy.shouldReevaluateOnPathChange(
                    isConnected: isConnected(), network: self.network)
                else { continue }
                try? await Task.sleep(for: self.cooldown)
                guard !Task.isCancelled else { return }
                await self.evaluateAndMaybeRedial(isConnected: isConnected)
            }
        }
    }

    /// The monitor's coalesced change stream: its `changeRevision`
    /// increments once per debounced path transition. Demo builds with
    /// no monitor yield an empty stream (the demo stores script state).
    private func monitorPathStream() -> AsyncStream<Void> {
        guard let monitor else {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    let tick = { @MainActor in monitor.changeRevision }
                    _ = await tick()
                    continuation.yield(())
                    // Poll the coalesced revision — one yield per
                    // coalesced transition, no busy loop.
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One re-evaluation: sweep, apply the policy's cooldown backoff
    /// (reset on a reachable verdict, doubled otherwise), and redial
    /// through the plan when unconnected and a route carries SSH.
    func evaluateAndMaybeRedial(isConnected: @escaping @MainActor () -> Bool) async {
        await checkRoutes()
        let foundReachable = probes.values.contains {
            $0.outcome.provesPathCarriesSSH
        }
        cooldown = HostRoutePolicy.nextCooldown(
            afterPrevious: cooldown, foundReachable: foundReachable)
        guard !isConnected(), foundReachable, let retryConnection else { return }
        await retryConnection()
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
        // Pinning adopts the v2 surface; any legacy v1 preferred pick is
        // cleared once, here — the pin is now the single dialing truth.
        PreferredAddressStore(hostID: host.id).clear()
    }

    /// "Return to automatic": drops the pin. The next connect follows the
    /// saved priority order.
    func returnToAutomatic() throws {
        guard let catalog else { return }
        var updated = host
        updated.routeSelection = .automatic
        try catalog.update(updated)
        // TEMP probe: surface the catalog state post-update.
        checkFailedExplanation = "PROBE after update: \(catalog.hosts.first(where: { $0.id == host.id })?.routeSelection ?? .automatic)"
        // Pinning adopts the v2 surface; any legacy v1 preferred pick is
        // cleared once, here — the pin is now the single dialing truth.
        PreferredAddressStore(hostID: host.id).clear()
    }

    /// "Try another route": pin the choice and retry the Host connection.
    /// The retry observes the pin through the dial plan — a pinned dial
    /// never fails over.
    func tryRoute(_ address: String) async throws {
        try pin(address)
        await retryConnection?()
    }

}
