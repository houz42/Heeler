import Foundation
import Testing

@testable import Heeler

/// The v2 automatic-route policy state machine on the reconciled model
/// (labels/eligibility keyed by address, the v1 hosts surface's
/// contract): priority order, Wi-Fi-only eligibility, stickiness (a
/// healthy live session is never preempted), pin semantics, probe
/// classification, honest display lines, cooldown backoff, and the
/// persistence/migration rules for the new Host fields.
@MainActor
@Suite("Host route selection")
struct HostRouteSelectionTests {
    // MARK: Fixtures

    /// Studio Mac over three paths: the design contract's example
    /// (Local network, Tailscale, Work VPN), labels carried in the
    /// Host's routeLabels.
    private func makeHost(
        labels: [String: String] = [
            "lan.example": "Local network",
            "tailnet.example": "Tailscale",
            "vpn.example": "Work VPN",
        ],
        eligibility: [String: HostRouteEligibility] = [:],
        selection: HostRouteSelection = .automatic
    ) -> Host {
        Host(
            address: "lan.example",
            username: "dev",
            additionalAddresses: ["tailnet.example", "vpn.example"],
            routeLabels: labels,
            routeEligibility: eligibility,
            routeSelection: selection)
    }

    // MARK: Priority order (Automatic = saved priority, latency never reorders)

    @Test func automaticDialPlanFollowsSavedPriority() {
        let host = makeHost()

        let plan = HostRoutePolicy.dialPlan(host: host, network: .wifi)

        #expect(plan == ["lan.example", "tailnet.example", "vpn.example"])
    }

    @Test func priorityWinsOverLatency() {
        // A probe found the last-priority route is the fastest; the plan
        // does not reorder — latency is diagnostic, priority wins.
        let host = makeHost()

        let plan = HostRoutePolicy.dialPlan(host: host, network: .wifi)

        #expect(plan.first == "lan.example")
    }

    @Test func unlabeledRoutesDialUnderTheirAddresses() {
        let host = Host(
            address: "lan.example", username: "dev",
            additionalAddresses: ["vpn.example"])

        let plan = HostRoutePolicy.dialPlan(host: host, network: .wifi)

        #expect(plan == ["lan.example", "vpn.example"])
    }

    // MARK: Eligibility (Wi-Fi only)

    @Test func wifiOnlyRoutesAreSkippedOffWiFi() {
        let host = makeHost(eligibility: ["lan.example": .wifiOnly])

        let plan = HostRoutePolicy.dialPlan(host: host, network: .nonWiFi)

        #expect(plan == ["tailnet.example", "vpn.example"])
    }

    @Test func wifiOnlyRoutesDialOnWiFi() {
        let host = makeHost(eligibility: ["lan.example": .wifiOnly])

        let plan = HostRoutePolicy.dialPlan(host: host, network: .wifi)

        #expect(plan.first == "lan.example")
    }

    @Test func anUnsatisfiedPathGatesOnlyWiFiOnlyRoutes() {
        // Any-network routes dial regardless of the path hint — the
        // dial itself is the honest proof (a truly pathless dial fails
        // fast as a reach failure). The Wi-Fi-only route is gated.
        let host = makeHost(eligibility: ["lan.example": .wifiOnly])

        let plan = HostRoutePolicy.dialPlan(host: host, network: .offline)

        #expect(plan == ["tailnet.example", "vpn.example"])
    }

    @Test func ineligibleRoutesDisplayTheirHonestSkip() {
        let host = makeHost(eligibility: ["lan.example": .wifiOnly])

        let status = HostRoutePolicy.rowStatus(
            address: "lan.example",
            host: host,
            liveAddress: nil,
            probes: [:],
            network: .nonWiFi)

        #expect(status == "Skipped · Wi-Fi only")
    }

    @Test func unlistedEligibilityDialsUnderAnyNetwork() {
        // Addresses saved before gates existed have no entry; Any network
        // is the migration default.
        let host = makeHost()

        let eligibility = host.routeEligibility(for: "tailnet.example")

        #expect(eligibility == .anyNetwork)
        #expect(
            HostRoutePolicy.isEligible(eligibility, network: .nonWiFi))
    }

    // MARK: Stickiness

    @Test func aSatisfiedPathChangeNeverReevaluatesAConnectedHost() {
        // The stickiness half: a healthy live session is never preempted
        // by a path update — no probe sweep, no hop to a marginally
        // faster endpoint.
        #expect(
            !HostRoutePolicy.shouldReevaluateOnPathChange(
                isConnected: true, network: .wifi))
        #expect(
            !HostRoutePolicy.shouldReevaluateOnPathChange(
                isConnected: true, network: .nonWiFi))
    }

    @Test func anUnconnectedHostReevaluatesOnASatisfiedPath() {
        #expect(
            HostRoutePolicy.shouldReevaluateOnPathChange(
                isConnected: false, network: .wifi))
        #expect(
            HostRoutePolicy.shouldReevaluateOnPathChange(
                isConnected: false, network: .nonWiFi))
        #expect(
            !HostRoutePolicy.shouldReevaluateOnPathChange(
                isConnected: false, network: .offline))
    }

    // MARK: Pin semantics

    @Test func manualPinDialsExactlyItsAddress() {
        let host = makeHost(selection: .manual(address: "tailnet.example"))

        let plan = HostRoutePolicy.dialPlan(host: host, network: .wifi)

        #expect(plan == ["tailnet.example"])
    }

    @Test func pinIsHonoredVerbatimEvenWhenEligibilityWouldGateIt() {
        // The pin is never silently overridden — not even by the Wi-Fi
        // gate. The user asked for this route; if it cannot work, the
        // failure surfaces as the pinned route's failure.
        let host = makeHost(
            eligibility: ["tailnet.example": .wifiOnly],
            selection: .manual(address: "tailnet.example"))

        let plan = HostRoutePolicy.dialPlan(host: host, network: .nonWiFi)

        #expect(plan == ["tailnet.example"])
    }

    @Test func stalePinIsHonoredNotReinterpreted() {
        // The catalog was edited; the pinned address no longer matches a
        // saved route. The dial plan still pins it VERBATIM — the UI
        // surfaces the staleness honestly with Return to automatic; the
        // policy never reinterprets the pin.
        let host = makeHost(selection: .manual(address: "removed.example"))

        let plan = HostRoutePolicy.dialPlan(host: host, network: .wifi)

        #expect(plan == ["removed.example"])
    }

    @Test func pinWinsOverStoredV1PreferredPick() throws {
        // The v1 pick machinery (PreferredAddressStore) must not override
        // a v2 pin: pin beats preference.
        let suiteName = "HostRouteSelectionTests.pinOverPick.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let host = makeHost(selection: .manual(address: "vpn.example"))
        let preferred = PreferredAddressStore(defaults: defaults, hostID: host.id)
        // A stale v1 pick says the tailnet route is preferred.
        preferred.prefer("tailnet.example", candidates: host.candidateAddresses)

        let order = preferred.preferredOrder(
            forCandidates: host.candidateAddresses,
            pinnedAddress: host.pinnedRouteAddress)

        #expect(order.first == "vpn.example")
    }

    @Test func automaticKeepsTheV1PreferredPickLeading() throws {
        let suiteName = "HostRouteSelectionTests.autoPick.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let host = makeHost()
        let preferred = PreferredAddressStore(defaults: defaults, hostID: host.id)
        preferred.prefer("tailnet.example", candidates: host.candidateAddresses)

        let order = preferred.preferredOrder(
            forCandidates: host.candidateAddresses, pinnedAddress: nil)

        #expect(order.first == "tailnet.example")
    }

    // MARK: Probe classification

    @Test func reachClassFailuresAreUnreachable() {
        let outcome = HostRoutePolicy.classifyProbeOutcome(
            error: TransportError.sshUnreachable(detail: "connection refused"))
        #expect(outcome == .unreachable)

        let timeout = HostRoutePolicy.classifyProbeOutcome(
            error: TransportError.timedOut)
        #expect(timeout == .unreachable)
    }

    @Test func authFailuresAreThemselvesNotUnreachable() {
        let outcome = HostRoutePolicy.classifyProbeOutcome(
            error: TransportError.authenticationFailed)
        #expect(outcome == .authenticationRejected)
        // And they prove the path carries SSH traffic.
        #expect(outcome.provesPathCarriesSSH)
    }

    @Test func hostKeyFailuresAreThemselvesNotUnreachable() {
        let fingerprint = HostKeyFingerprint(publicKeyBlob: Data("k".utf8))
        #expect(
            HostRoutePolicy.classifyProbeOutcome(
                error: TransportError.hostKeyRejected(presented: fingerprint))
                == .hostKeyProblem)
        #expect(
            HostRoutePolicy.classifyProbeOutcome(
                error: TransportError.hostKeyMismatch(
                    known: fingerprint, presented: fingerprint))
                == .hostKeyProblem)
    }

    @Test func otherTransportFailuresProveThePath() {
        // e.g. streamLocalOpenFailed: the handshake completed, so the
        // path works; the failure is a server-policy matter.
        let outcome = HostRoutePolicy.classifyProbeOutcome(
            error: TransportError.streamLocalOpenFailed(path: "/run/herdr.sock"))
        #expect(outcome == .reachable)
    }

    // MARK: Honest display lines

    @Test func resultLineNamesTheInUseRouteNeverTheProvider() {
        let host = makeHost()
        var probes = [String: HostRouteProbeResult]()
        probes["lan.example"] = HostRouteProbeResult(
            outcome: .reachable, checkedAt: Date())

        let line = HostRoutePolicy.resultLine(
            host: host, liveAddress: "lan.example",
            probes: probes, network: .wifi)
        #expect(line == "Using Local network")

        // The forbidden phrasing — provider on/off claims — is never
        // produced for any probe combination.
        #expect(!line.contains("is on"))
        #expect(!line.contains("VPN is"))
    }

    @Test func pinnedResultLineNamesThePinnedRoute() {
        let host = makeHost(selection: .manual(address: "tailnet.example"))

        let line = HostRoutePolicy.resultLine(
            host: host, liveAddress: nil, probes: [:], network: .wifi)
        #expect(line == "Route pinned: Tailscale")
    }

    @Test func authFailureOnTheLiveRouteReadsAsASignInProblem() {
        let host = makeHost()
        var probes = [String: HostRouteProbeResult]()
        probes["lan.example"] = HostRouteProbeResult(
            outcome: .authenticationRejected, checkedAt: Date())

        let line = HostRoutePolicy.resultLine(
            host: host, liveAddress: "lan.example",
            probes: probes, network: .wifi)
        #expect(line == "Using Local network · sign-in problem")
    }

    @Test func unprobedRouteReadsNotChecked() {
        let host = makeHost()
        let status = HostRoutePolicy.rowStatus(
            address: "tailnet.example",
            host: host,
            liveAddress: nil,
            probes: [:],
            network: .wifi)
        #expect(status == "Not checked")
    }

    @Test func liveRouteReadsInUse() {
        let host = makeHost()
        let status = HostRoutePolicy.rowStatus(
            address: "lan.example",
            host: host,
            liveAddress: "lan.example",
            probes: [:],
            network: .wifi)
        #expect(status == "In use")
    }

    @Test func measuredLatencyAppendsAsDiagnostic() {
        let host = makeHost()
        var probes = [String: HostRouteProbeResult]()
        probes["tailnet.example"] = HostRouteProbeResult(
            outcome: .reachable, checkedAt: Date(), latency: .milliseconds(23))

        let status = HostRoutePolicy.rowStatus(
            address: "tailnet.example",
            host: host,
            liveAddress: nil,
            probes: probes,
            network: .wifi)
        #expect(status == "Reachable · 23 ms")
    }

    // MARK: Cooldown / backoff

    @Test func cooldownDoublesOnEmptySweepsAndResetsOnSuccess() {
        // A sweep that found nothing reachable backs off: doubling,
        // capped at max.
        var cooldown = HostRoutePolicy.baseCooldown
        cooldown = HostRoutePolicy.nextCooldown(
            afterPrevious: cooldown, foundReachable: false)
        #expect(cooldown == .seconds(4))
        cooldown = HostRoutePolicy.nextCooldown(
            afterPrevious: cooldown, foundReachable: false)
        #expect(cooldown == .seconds(8))
        // ... up to the cap.
        var capped = HostRoutePolicy.maxCooldown
        capped = HostRoutePolicy.nextCooldown(
            afterPrevious: capped, foundReachable: false)
        #expect(capped == HostRoutePolicy.maxCooldown)
        // A sweep that found a reachable route resets to base.
        let reset = HostRoutePolicy.nextCooldown(
            afterPrevious: .seconds(16), foundReachable: true)
        #expect(reset == HostRoutePolicy.baseCooldown)
    }

    // MARK: Persistence and migration

    @Test func legacyCatalogDecodesAutomaticWithNoGates() throws {
        let id = UUID()
        let legacy = """
            {"version":1,"hosts":[{"id":"\(id.uuidString)",
              "name":"Mac","address":"192.168.31.71","port":22,
              "username":"jhou","authMethod":"deviceKey",
              "sessionName":"","additionalAddresses":["CMF79KM7YF.local"],
              "jumpAddress":"","jumpPort":22,"jumpUsername":"","alias":""}]}
            """
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(Data(legacy.utf8), forKey: "hosts")

        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let host = try #require(store.hosts.first)
        #expect(host.routeSelection == .automatic)
        #expect(host.routeEligibility.isEmpty)
        // And the dialing keeps the v1 behavior.
        #expect(
            HostRoutePolicy.dialPlan(host: host, network: .wifi)
                == ["192.168.31.71", "CMF79KM7YF.local"])
    }

    @Test func routeSelectionRoundTripsThroughTheStore() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = makeHost(selection: .manual(address: "tailnet.example"))

        try HostStore(defaults: defaults, secrets: InMemorySecretStore()).add(host)

        let reloaded = try #require(
            HostStore(defaults: defaults, secrets: InMemorySecretStore())
                .hosts.first)
        #expect(reloaded.routeSelection == .manual(address: "tailnet.example"))
        #expect(reloaded.routeLabels == host.routeLabels)
        #expect(reloaded.routeEligibility == host.routeEligibility)
    }

    @Test func formEditCarriesGatesAndPinThrough() throws {
        // The defect this pins: a form edit (name change, say) must not
        // drop the Host's eligibility gates or silently reinterpret a
        // pin.
        let host = makeHost(
            eligibility: ["lan.example": .wifiOnly],
            selection: .manual(address: "tailnet.example"))

        var draft = HostDraft(host: host)
        draft.name = "Renamed"

        let saved = try #require(draft.makeHost(id: host.id))
        #expect(saved.routeSelection == .manual(address: "tailnet.example"))
        #expect(saved.routeEligibility == ["lan.example": .wifiOnly])
        #expect(saved.routeLabels == host.routeLabels)
        #expect(saved.candidateAddresses == host.candidateAddresses)
    }

    // MARK: Integration — the real dial path

    /// The `TransportConnector` recording the addresses the REAL dial
    /// path (`SSHTransportSettings(host:)` → `dialCandidates` →
    /// `dialFirstReachable`) actually dialed, in order.
    private actor DialRecordingConnector: TransportConnector {
        let reachable: Set<String>
        private(set) var dialed: [String] = []

        init(reachable: Set<String>) {
            self.reachable = reachable
        }

        func connect(settings: SSHTransportSettings) async throws -> any Transport {
            dialed.append(settings.host)
            guard reachable.contains(settings.host) else {
                throw TransportError.sshUnreachable(detail: "no route to host")
            }
            return ScriptedTransport()
        }
    }

    @Test func theRealDialPathIsEligibilityGatedAndPriorityOrdered() async throws {
        // Through the actual production dial seam (the same
        // `SSHTransportSettings(host:)` every real dial builds, driven
        // through `dialFirstReachable` — the multi-candidate loop the
        // Console's factory runs): a Wi-Fi-only first route, a non-Wi-Fi
        // network hint, and only the Any-network routes dialable — the
        // dial attempts ONLY the eligible priority order, never the
        // gated route, and the first answering candidate connects.
        HostRouteNetworkSnapshot.update(.nonWiFi)
        defer { HostRouteNetworkSnapshot.update(.offline) }
        let host = makeHost(eligibility: ["lan.example": .wifiOnly])
        let connector = DialRecordingConnector(reachable: ["vpn.example"])

        let settings = SSHTransportSettings(
            host: host,
            credentials: .password("pw"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false })
        _ = try await SSHTransportConnector.dialFirstReachable(
            settings: settings,
            perCandidateTimeout: .seconds(4),
            dialOne: { try await connector.connect(settings: $0) },
            onCandidate: nil)

        #expect(await connector.dialed == ["tailnet.example", "vpn.example"])
    }

    @Test func theRealDialPathDialsExactlyThePinnedRoute() async throws {
        // Through the actual production dial seam: the pin is honored
        // VERBATIM — one address, no failover, even when the pinned
        // route is unreachable and others would answer.
        HostRouteNetworkSnapshot.update(.wifi)
        defer { HostRouteNetworkSnapshot.update(.offline) }
        let host = makeHost(selection: .manual(address: "tailnet.example"))
        let connector = DialRecordingConnector(reachable: ["lan.example", "vpn.example"])

        let settings = SSHTransportSettings(
            host: host,
            credentials: .password("pw"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false })
        await #expect(throws: TransportError.self) {
            _ = try await SSHTransportConnector.dialFirstReachable(
                settings: settings,
                perCandidateTimeout: .seconds(4),
                dialOne: { try await connector.connect(settings: $0) },
                onCandidate: nil)
        }

        // Exactly one dial: the pinned (unreachable) route. The healthy
        // alternatives were never tried — the pin's failure is the
        // pinned route's failure.
        #expect(await connector.dialed == ["tailnet.example"])
    }

    @Test func stickinessHoldsThroughTheRealConsumer() {
        // The design contract's stickiness, at the consumer seam: a
        // CONNECTED host's dial plan is never re-evaluated on path
        // changes (no hop to a marginally faster endpoint), while an
        // unconnected host re-evaluates on a satisfied path.
        #expect(
            !HostRoutePolicy.shouldReevaluateOnPathChange(
                isConnected: true, network: .wifi))
        #expect(
            HostRoutePolicy.shouldReevaluateOnPathChange(
                isConnected: false, network: .nonWiFi))
    }

    // MARK: Support

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-route-selection-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}
