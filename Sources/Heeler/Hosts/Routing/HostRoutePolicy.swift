import Foundation

/// What the network layer currently reports, reduced to the two facts
/// route decisions may consume. An interface classification is a HINT,
/// never proof of which VPN is active — the design contract is explicit
/// that `other` does not name a VPN and the app does not infer provider
/// state from interface names or IP ranges.
struct HostRouteNetworkState: Equatable, Sendable {
    /// A satisfied path exists (NWPathMonitor `.satisfied`). False means
    /// no network path at all; true means a path exists, NOT that any
    /// particular SSH endpoint is reachable.
    var isSatisfied: Bool
    /// The current path classifies as Wi-Fi (`.wifi`). "Wi-Fi only"
    /// eligibility keys on exactly this hint; cellular, wired, and
    /// `other` (which a VPN interface typically reports) all read as
    /// not-Wi-Fi, which is honest: the hint cannot prove the VPN is not
    /// wrapping a Wi-Fi path, so the gate stays conservative in what it
    /// claims and the dial remains the real proof.
    var isWiFiHint: Bool

    static let offline = HostRouteNetworkState(isSatisfied: false, isWiFiHint: false)
    static let wifi = HostRouteNetworkState(isSatisfied: true, isWiFiHint: true)
    static let nonWiFi = HostRouteNetworkState(isSatisfied: true, isWiFiHint: false)
}

/// One route's most recent verified probe outcome, with when it was
/// checked. A probe is the existing SSH reach probe semantics (a bounded
/// connect-only dial of exactly this address): reach-class failure =
/// unreachable; auth/trust failures prove the path carries SSH traffic
/// and are surfaced as the failure they are — never as "unreachable",
/// never weakened. `nil` latency = not measured; latency is diagnostic
/// only, priority wins.
struct HostRouteProbeResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The address answered the bounded probe.
        case reachable
        /// A reach-class failure: connection refused, no route, timeout.
        /// DNS resolution failure lands here too — name resolution is a
        /// dial, not authenticated reachability.
        case unreachable
        /// The path answered SSH but rejected authentication.
        case authenticationRejected
        /// The host key was rejected on first connect, or differed from
        /// the trusted pin. Trust failures are themselves; no host-key
        /// check is ever weakened to make a route "work".
        case hostKeyProblem
        /// Never probed on this device, or the record predates the last
        /// catalog edit.
        case unknown

        /// Auth/trust outcomes still prove the network path carries SSH
        /// traffic; the design contract keeps them distinct from both
        /// reachable and unreachable.
        var provesPathCarriesSSH: Bool {
            switch self {
            case .reachable, .authenticationRejected, .hostKeyProblem: true
            case .unreachable, .unknown: false
            }
        }
    }

    var outcome: Outcome
    /// When the probe concluded; nil for `.unknown`.
    var checkedAt: Date?
    /// Round trip of the probe dial, diagnostic only — priority wins, a
    /// live healthy session never hops to a marginally faster route.
    var latency: Duration?

    static let unknown = HostRouteProbeResult(
        outcome: .unknown, checkedAt: nil, latency: nil)

    init(outcome: Outcome, checkedAt: Date?, latency: Duration? = nil) {
        self.outcome = outcome
        self.checkedAt = checkedAt
        self.latency = latency
    }
}

/// The pure decision core of automatic route selection: given a Host's
/// route metadata (labels/eligibility keyed by address, the v1 hosts
/// surface's contract), the network hint, and per-address probe records,
/// decide what to dial next and what each saved route should display. No
/// clocks, no I/O, no NWPathMonitor — those live in `HostRouteMonitor`
/// and the prober, which feed this state machine and render from it.
///
/// Stickiness lives HERE as a rule, not in a timer: every dial-plan entry
/// point answers "what should a NEW connect attempt dial", and the caller
/// only asks while unconnected (initial connect, redial after failure,
/// foreground recheck that found the link dead). A healthy live session
/// is never preempted because nothing asks for a plan while it stands —
/// and an automatic plan never demotes the in-use address on the grounds
/// that another answered faster.
enum HostRoutePolicy {
    // MARK: Dial plans (the Automatic policy)

    /// The full dial plan for one connect attempt: the manual pin alone
    /// when pinned (the pin is honored VERBATIM — even one that no longer
    /// matches a saved route; surfacing a stale pin is the UI's job,
    /// reinterpreting it is forbidden), else the eligible saved routes in
    /// priority order. Latency never reorders this list; priority wins.
    static func dialPlan(host: Host, network: HostRouteNetworkState) -> [String] {
        if let pinned = host.pinnedRouteAddress {
            return [pinned]
        }
        return host.candidateAddresses
            .filter { isEligible(host.routeEligibility(for: $0), network: network) }
    }

    /// Whether `eligibility` permits dialing under `network`. An
    /// unsatisfied path gates every route; a not-Wi-Fi hint gates the
    /// Wi-Fi-only ones. The hint is conservative in what it claims and
    /// the dial remains the real proof.
    static func isEligible(
        _ eligibility: HostRouteEligibility, network: HostRouteNetworkState
    ) -> Bool {
        guard network.isSatisfied else { return false }
        switch eligibility {
        case .anyNetwork:
            return true
        case .wifiOnly:
            return network.isWiFiHint
        }
    }

    // MARK: Probe result classification

    /// Maps a probe dial's thrown error onto the probe outcome taxonomy.
    static func classifyProbeOutcome(error: any Error) -> HostRouteProbeResult.Outcome {
        guard let transportError = error as? TransportError else {
            return .unreachable
        }
        if transportError.isReachFailure {
            return .unreachable
        }
        switch transportError {
        case .authenticationFailed, .deviceKeyCorrupt:
            return .authenticationRejected
        case .hostKeyRejected, .hostKeyMismatch:
            return .hostKeyProblem
        default:
            // Non-reach, non-auth/trust transport failures still prove
            // the path carried SSH traffic (the handshake got far enough
            // to produce them).
            return .reachable
        }
    }

    // MARK: Display (honest, never provider claims)

    /// The result line for the Host's route surface, per the design
    /// contract's example: "Using Local network", "Route pinned:
    /// Tailscale", "Route selection: Automatic". Route names describe
    /// saved endpoints; NEVER "Tailscale is on" — the app cannot see
    /// GlobalProtect/Tailscale state.
    static func resultLine(
        host: Host,
        liveAddress: String?,
        probes: [String: HostRouteProbeResult],
        network: HostRouteNetworkState
    ) -> String {
        if let pinned = host.pinnedRouteAddress {
            let name = host.routeName(for: pinned)
            return "Route pinned: \(name)"
        }
        guard let liveAddress else {
            return "Route selection: Automatic"
        }
        let name = host.routeName(for: liveAddress)
        switch probes[liveAddress]?.outcome {
        case .authenticationRejected:
            // Auth failures show as themselves; the design contract
            // forbids reading them as unreachable.
            return "Using \(name) · sign-in problem"
        case .hostKeyProblem:
            return "Using \(name) · host key problem"
        case .reachable, .unreachable, .unknown, nil:
            return "Using \(name)"
        }
    }

    /// The per-route status phrase for a route row: "In use", "Not
    /// checked", "Reachable", "Unreachable", the auth/trust failure as
    /// itself, or the honest skip for an ineligible route. Latency, when
    /// measured, appends as a diagnostic.
    static func rowStatus(
        address: String,
        host: Host,
        liveAddress: String?,
        probes: [String: HostRouteProbeResult],
        network: HostRouteNetworkState
    ) -> String {
        if address == liveAddress {
            return "In use"
        }
        let eligibility = host.routeEligibility(for: address)
        guard isEligible(eligibility, network: network) else {
            return "Skipped · \(eligibility.title)"
        }
        guard let probe = probes[address] else { return "Not checked" }
        switch probe.outcome {
        case .reachable:
            if let latency = probe.latency {
                return "Reachable · \(HostLatencyFormatting.formatted(latency))"
            }
            return "Reachable"
        case .unreachable:
            return "Unreachable"
        case .authenticationRejected:
            return "Sign-in rejected"
        case .hostKeyProblem:
            return "Host key problem"
        case .unknown:
            return "Not checked"
        }
    }

    // MARK: Re-evaluation coalescing

    /// The re-evaluation cooldown: after one network-change-triggered
    /// evaluation, further path updates within this window coalesce into
    /// the next one. NWPathMonitor bursts many updates per physical
    /// transition (interface up, DNS re-resolution, VPN attach); without a
    /// cooldown each burst would re-probe every route and the surface
    /// would flap. Bounded backoff: each evaluation that finds no
    /// reachable route doubles the next cooldown, capped; a success
    /// resets it.
    static let baseCooldown: Duration = .seconds(2)
    static let maxCooldown: Duration = .seconds(30)

    /// The cooldown in force AFTER an evaluation that found
    /// `foundReachable` routes, given the previous cooldown.
    static func nextCooldown(afterPrevious previous: Duration, foundReachable: Bool) -> Duration {
        guard !foundReachable else { return baseCooldown }
        let doubled = previous * 2
        return doubled > maxCooldown ? maxCooldown : doubled
    }

    /// Whether a network-state change should trigger re-evaluation at
    /// all. The design contract's "Network path updates trigger
    /// reevaluation only when needed": an unconnected Host wants
    /// re-evaluation on every satisfied-path transition (it may now be
    /// dialable); a Host with a healthy live session does not — probing
    /// alternatives while connected is what hops to marginally faster
    /// endpoints, and stickiness forbids it. The foreground recheck is
    /// the explicit user-driven exception and bypasses this gate.
    static func shouldReevaluateOnPathChange(
        isConnected: Bool, network: HostRouteNetworkState
    ) -> Bool {
        guard !isConnected else { return false }
        return network.isSatisfied
    }
}
