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
    /// The Host's LIVE connection state, kept current by the presenting
    /// view (onChange of the console status). Evaluations and the
    /// retry-adjacent gate read THIS — never a captured snapshot.
    private(set) var isConnectedNow = false
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

    /// The presenting view keeps this current (onChange of the console
    /// status). All evaluation gates read it LIVE.
    func updateConnectionState(_ connected: Bool) {
        isConnectedNow = connected
    }


    /// Starts observing the shared monitor's COALESCED path changes.
    /// The `changeRevision` counter increments once per DEBOUNCED path
    /// transition; the observer compares revisions and evaluates only
    /// on an actual increment, so the cooldown gates REAL transitions,
    /// not a tick. Each transition updates `network` (the surface
    /// re-renders its Skipped/eligible rows honestly) and, per the
    /// policy's re-evaluation gate, an UNCONNECTED host re-evaluates
    /// with the cooldown backoff — the recovery path for the
    /// all-ineligible off-Wi-Fi state. A CONNECTED host never
    /// re-evaluates (stickiness).
    ///
    /// Lifetime: `stopObservingPathChanges()` cancels explicitly (the
    /// presenting view calls it on disappearance); this method is
    /// idempotent and restarts cleanly. The loop holds only a weak self.
    func observePathChanges() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            var lastRevision = await self?.monitor?.changeRevision ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, let monitor = self.monitor
                else { return }
                let revision = await monitor.changeRevision
                // Coalesce: one evaluation per actual debounced
                // transition — ticks without a revision change are
                // discarded.
                guard revision != lastRevision else { continue }
                lastRevision = revision
                self.syncNetworkFromMonitor()
                guard HostRoutePolicy.shouldReevaluateOnPathChange(
                    isConnected: self.isConnectedNow, network: self.network)
                else { continue }
                try? await Task.sleep(for: self.cooldown)
                guard !Task.isCancelled else { return }
                await self.evaluateAndMaybeRedial()
            }
        }
    }

    /// Cancels the path-change observer (the presenting view calls this
    /// on disappearance). Restartable: `observePathChanges` re-arms.
    func stopObservingPathChanges() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// One re-evaluation: sweep, apply the policy's cooldown backoff
    /// (reset on a reachable verdict, doubled otherwise), and redial
    /// through the plan when unconnected and a route carries SSH. The
    /// connection state is read AGAIN immediately before the retry —
    /// a host that connected mid-sweep (another surface's redial, say)
    /// is never yanked into a second dial.
    func evaluateAndMaybeRedial() async {
        await checkRoutes()
        let foundReachable = probes.values.contains {
            $0.outcome.provesPathCarriesSSH
        }
        cooldown = HostRoutePolicy.nextCooldown(
            afterPrevious: cooldown, foundReachable: foundReachable)
        guard !isConnectedNow, foundReachable, let retryConnection else { return }
        await retryConnection()
    }

    /// The design contract's "Check routes": one bounded sweep of the
    /// ELIGIBLE configured routes in priority order — eligibility is
    /// applied BEFORE probing, so a Wi-Fi-only route is never CONTACTED
    /// while off Wi-Fi (the same gate the dial plan enforces; probing a
    /// gated route would bypass the user's setting). Gated routes show
    /// their honest "Skipped · Wi-Fi only" row state instead. The busy
    /// state is owned HERE (overlapping presses are refused rather than
    /// serialized), and results land per-route as the sweep goes.
    func checkRoutes() async {
        guard !isProbing else { return }
        isProbing = true
        checkFailedExplanation = nil
        // The CURRENT catalog host: an edit made since this store was
        // built is honored — the sweep probes what is saved NOW.
        let currentHost = currentCatalogHost
        let eligible = currentHost.candidateAddresses
            .filter { address in
                HostRoutePolicy.isEligible(
                    currentHost.routeEligibility(for: address),
                    network: network)
            }
        do {
            try await prober.probe(addresses: eligible, host: currentHost) {
                [weak self] address, result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // A result for an address this Host no longer
                    // carries (edited mid-sweep) is dropped, never
                    // resurrected.
                    guard self.currentCatalogHost.candidateAddresses.contains(address)
                    else { return }
                    self.probes[address] = result
                }
            }
        } catch HostCredentialsError.passwordNotSet {
            checkFailedExplanation =
                "The check could not run: no password is saved for \(currentHost.displayAliasName)."
        } catch DeviceKeyStoreError.storedKeyCorrupt {
            checkFailedExplanation =
                "The check could not run: the Device Key could not be loaded. "
                + "Open Edit and replace it if it is corrupt."
        } catch {
            checkFailedExplanation =
                "The check could not run: \(currentHost.displayAliasName)'s credentials "
                + "could not be loaded."
        }
        isProbing = false
    }

    /// The CURRENT catalog host — the saved state right now, not the
    /// snapshot captured when this store was built. Pin, unpin, and the
    /// sweep all mutate and read THROUGH this, so a concurrent edit can
    /// never be overwritten by a stale copy.
    private var currentCatalogHost: Host {
        catalog?.hosts.first(where: { $0.id == host.id }) ?? host
    }

    /// "Choose manually" → pin one route. Persists immediately; the pin
    /// is never silently overridden, and it dials exactly its address
    /// through the dial plan. Mutates the CURRENT catalog host — a
    /// concurrent edit (name change, address reorder) is preserved,
    /// never overwritten by this store's older snapshot.
    func pin(_ address: String) throws {
        guard let catalog else { return }
        var updated = currentCatalogHost
        updated.routeSelection = .manual(address: address)
        try catalog.update(updated)
        // Pinning adopts the v2 surface; any legacy v1 preferred pick is
        // cleared once, here — the pin is now the single dialing truth.
        PreferredAddressStore(hostID: host.id).clear()
    }

    /// "Return to automatic": drops the pin. The next connect follows the
    /// saved priority order. Mutates the CURRENT catalog host.
    func returnToAutomatic() throws {
        guard let catalog else { return }
        var updated = currentCatalogHost
        updated.routeSelection = .automatic
        try catalog.update(updated)
        // Unpinning keeps the v2 surface adopted; any legacy v1
        // preferred pick stays cleared — the saved order governs.
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
