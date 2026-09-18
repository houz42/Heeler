import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0

/// The `@Sendable` onCandidate callback cannot capture a test-local var;
/// this box collects the report safely.
private final class CandidateReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: CandidateDialResult?

    func record(_ result: CandidateDialResult) {
        lock.lock()
        reported = result
        lock.unlock()
    }

    var value: CandidateDialResult? {
        lock.lock()
        defer { lock.unlock() }
        return reported
    }
}

/// A `TransportConnector` whose connect outcome depends on the dialed
/// address: addresses NOT in `reachable` throw `.sshUnreachable`
/// (probing marks them unreachable), reachable ones return a transport
/// that pings with `pingResult` (a full connect succeeds on them).
private struct AddressScriptedConnector: TransportConnector {
    let reachable: Set<String>
    let pingResult: Result<ServerInfo, TransportError>

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        guard reachable.contains(settings.host) else {
            throw TransportError.sshUnreachable(detail: "no route to host")
        }
        return FakeTransport(pingResult: pingResult)
    }
}

/// One Host, multiple candidate addresses: model shape, persistence
/// migration, the form field, and the dialer's ordering + fallback through
/// the `dialOne` stub seam (no real network).
@MainActor
@Suite("Host multi-path")
struct HostMultiPathTests {
    // MARK: Candidate ordering

    @Test func candidateAddressesLeadWithTheStoredDefault() {
        let host = Host(
            address: "192.168.31.71", username: "dev",
            additionalAddresses: ["CMF79KM7YF.local", "vpn.example"])

        #expect(host.candidateAddresses == ["192.168.31.71", "CMF79KM7YF.local", "vpn.example"])
    }

    @Test(arguments: [["", "  "], [" "], ["", ""]])
    func blankAndWhitespaceCandidatesAreDropped(raw: [String]) {
        let host = Host(address: "a.example", username: "dev", additionalAddresses: raw)

        #expect(host.candidateAddresses == ["a.example"])
    }

    @Test func whitespaceAroundCandidatesIsTrimmed() {
        let host = Host(address: "a.example", username: "dev", additionalAddresses: ["  b.example "])

        #expect(host.candidateAddresses == ["a.example", "b.example"])
    }

    @Test func singleAddressHostDialsItsOneAddress() {
        let host = Host.fixture()
        #expect(host.additionalAddresses == [])
        #expect(host.candidateAddresses == [host.address])
    }

    // MARK: Codable round-trip

    @Test func roundTripsThroughTheStore() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host(
            address: "192.168.31.71", username: "dev",
            additionalAddresses: ["CMF79KM7YF.local", "vpn.example"])

        try HostStore(defaults: defaults, secrets: InMemorySecretStore()).add(host)

        let reloaded = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        #expect(reloaded.hosts == [host])
        #expect(reloaded.hosts.first?.candidateAddresses == host.candidateAddresses)
    }

    @Test func hostsSavedBeforeTheFieldDecodeWithNoAdditionalAddresses() throws {
        let id = UUID()
        let legacy = """
            [{"id":"\(id.uuidString)","name":"Old","address":"old.example","port":22,
              "username":"dev","authMethod":"deviceKey"}]
            """
        let host = try JSONDecoder().decode([Host].self, from: Data(legacy.utf8)).first

        #expect(host?.additionalAddresses == [])
        #expect(host?.candidateAddresses == ["old.example"])
    }

    @Test func catalogsSavedWithTheFieldDecodeItBack() throws {
        let id = UUID()
        let current = """
            [{"id":"\(id.uuidString)","name":"New","address":"new.example","port":22,
              "username":"dev","authMethod":"deviceKey",
              "additionalAddresses":["lan.example","vpn.example"]}]
            """
        let host = try JSONDecoder().decode([Host].self, from: Data(current.utf8)).first

        #expect(host?.additionalAddresses == ["lan.example", "vpn.example"])
        #expect(host?.candidateAddresses == ["new.example", "lan.example", "vpn.example"])
    }

    // MARK: Draft (form) normalization

    @Test func draftRowsNormalizeToCandidates() throws {
        var draft = HostDraft()
        draft.address = "192.168.31.71"
        draft.username = "dev"
        draft.additionalAddresses = ["  CMF79KM7YF.local ", "vpn.example", "  "]

        let host = try #require(draft.makeHost())
        #expect(host.additionalAddresses == ["CMF79KM7YF.local", "vpn.example"])
        #expect(
            host.candidateAddresses == ["192.168.31.71", "CMF79KM7YF.local", "vpn.example"])
    }

    @Test func draftRoundTripsThroughEdit() throws {
        let host = Host(
            id: UUID(), name: "Studio Mac", address: "192.168.31.71", port: 22,
            username: "dev", authMethod: .deviceKey,
            additionalAddresses: ["CMF79KM7YF.local", "vpn.example"])

        let draft = HostDraft(host: host)
        #expect(draft.additionalAddresses == ["CMF79KM7YF.local", "vpn.example"])
        #expect(try draft.makeHost(id: host.id) == host)
    }

    @Test func freshDraftHasNoAdditionalRows() throws {
        var draft = HostDraft()
        draft.address = "a.example"
        draft.username = "dev"

        #expect(try draft.makeHost()?.additionalAddresses == [])
    }

    // MARK: Draft row editing (the edit form's dynamic list)

    @Test func addRowAppendsAnAdditionalAddress() {
        var draft = HostDraft()
        draft.additionalAddresses = ["vpn.example"]

        draft.addAdditionalAddress()

        #expect(draft.additionalAddresses == ["vpn.example", ""])
    }

    @Test func removingTheLastAdditionalRowLeavesThePrimaryAddress() throws {
        var draft = HostDraft()
        draft.address = "a.example"
        draft.username = "dev"
        draft.additionalAddresses = ["vpn.example"]

        draft.removeAdditionalAddress(at: 0)

        // The floor is one TOTAL address: the primary row is not part of
        // the additional list, so the Host still dials it.
        let host = try #require(draft.makeHost())
        #expect(host.additionalAddresses == [])
        #expect(host.candidateAddresses == ["a.example"])
    }

    @Test func removingOutOfRangeIndexIsIgnored() {
        var draft = HostDraft()
        draft.additionalAddresses = ["vpn.example"]

        draft.removeAdditionalAddress(at: 3)

        #expect(draft.additionalAddresses == ["vpn.example"])
    }

    @Test func movingRowsReordersCandidatesButKeepsPrimaryFirst() throws {
        var draft = HostDraft()
        draft.address = "a.example"
        draft.username = "dev"
        draft.additionalAddresses = ["b.example", "c.example"]

        draft.moveAdditionalAddress(from: IndexSet(integer: 1), to: 0)

        let host = try #require(draft.makeHost())
        #expect(
            host.candidateAddresses == ["a.example", "c.example", "b.example"])
    }

    // MARK: Dial order and fallback (stub seam, no network)

    /// The `dialOne` stub: scripts per-address outcomes. Unreachable
    /// addresses throw `.sshUnreachable`; the reachable one returns a
    /// transport. Records the order it was dialed.
    private actor ScriptedDialer {
        let reachableAddresses: Set<String>
        private(set) var dialed: [String] = []
        private(set) var timeoutsUsed: [Duration] = []

        init(reachableAddresses: Set<String>) {
            self.reachableAddresses = reachableAddresses
        }

        func dialOne(_ settings: SSHTransportSettings) async throws -> any Transport {
            dialed.append(settings.host)
            timeoutsUsed.append(settings.requestTimeout)
            guard reachableAddresses.contains(settings.host) else {
                throw TransportError.sshUnreachable(detail: "no route to host")
            }
            return ScriptedTransport()
        }
    }

    /// Throws one scripted `TransportError` on the first dial and records it.
    private actor OneShotDialer {
        let error: TransportError
        private(set) var dialed: [String] = []

        init(error: TransportError) {
            self.error = error
        }

        func dialOne(_ settings: SSHTransportSettings) async throws -> any Transport {
            dialed.append(settings.host)
            throw error
        }
    }

    private func makeSettings(candidates: [String]) -> SSHTransportSettings {
        var settings = SSHTransportSettings(
            host: "", port: 22, username: "dev",
            credentials: .password("pw"),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false },
            socket: .defaultSession)
        settings.candidateAddresses = candidates
        return settings
    }

    @Test func dialsCandidatesInOrderAndFallsOverOnUnreachableFirst() async throws {
        let dialer = ScriptedDialer(reachableAddresses: ["vpn.example"])
        let reports = CandidateReportBox()
        _ = try await SSHTransportConnector.dialFirstReachable(
            settings: makeSettings(candidates: ["lan.example", "vpn.example"]),
            perCandidateTimeout: .seconds(4),
            dialOne: { try await dialer.dialOne($0) },
            onCandidate: { reports.record($0) })

        // The unreachable LAN path was dialed first, then the VPN path won.
        #expect(await dialer.dialed == ["lan.example", "vpn.example"])
        #expect(
            reports.value == CandidateDialResult(address: "vpn.example", failedAttempts: 1))
    }

    @Test func firstCandidateSuccessSkipsTheRest() async throws {
        let dialer = ScriptedDialer(reachableAddresses: ["lan.example"])

        _ = try await SSHTransportConnector.dialFirstReachable(
            settings: makeSettings(candidates: ["lan.example", "vpn.example"]),
            perCandidateTimeout: .seconds(4),
            dialOne: { try await dialer.dialOne($0) },
            onCandidate: nil)

        #expect(await dialer.dialed == ["lan.example"])
    }

    @Test func allCandidatesUnreachableReportsEveryAttempt() async throws {
        let dialer = ScriptedDialer(reachableAddresses: [])
        let reports = CandidateReportBox()
        await #expect(throws: TransportError.self) {
            _ = try await SSHTransportConnector.dialFirstReachable(
                settings: makeSettings(candidates: ["lan.example", "vpn.example"]),
                perCandidateTimeout: .seconds(4),
                dialOne: { try await dialer.dialOne($0) },
                onCandidate: { reports.record($0) })
        }
        #expect(await dialer.dialed == ["lan.example", "vpn.example"])
        #expect(reports.value == nil)
    }

    @Test func authenticationFailuresStopFailover() async throws {
        // Auth is about the machine, not the path: dialing the same Host's
        // other address cannot change the answer, so the loop stops.
        let dialer = OneShotDialer(error: TransportError.authenticationFailed)
        await #expect(throws: TransportError.authenticationFailed) {
            _ = try await SSHTransportConnector.dialFirstReachable(
                settings: makeSettings(candidates: ["lan.example", "vpn.example"]),
                perCandidateTimeout: .seconds(4),
                dialOne: dialer.dialOne,
                onCandidate: nil)
        }
        #expect(await dialer.dialed == ["lan.example"])
    }

    @Test func multiCandidateDialUsesTheShortPerAddressBudget() async throws {
        let dialer = ScriptedDialer(reachableAddresses: ["vpn.example"])

        _ = try await SSHTransportConnector.dialFirstReachable(
            settings: makeSettings(candidates: ["lan.example", "vpn.example"]),
            perCandidateTimeout: .seconds(4),
            dialOne: { try await dialer.dialOne($0) },
            onCandidate: nil)

        #expect(await dialer.timeoutsUsed == [.seconds(4), .seconds(4)])
    }

    @Test func singleCandidateDialKeepsTheOrdinaryRequestTimeout() async throws {
        let dialer = ScriptedDialer(reachableAddresses: ["lan.example"])
        var settings = makeSettings(candidates: ["lan.example"])
        settings.requestTimeout = .seconds(15)

        _ = try await SSHTransportConnector.dialFirstReachable(
            settings: settings,
            perCandidateTimeout: .seconds(4),
            dialOne: { try await dialer.dialOne($0) },
            onCandidate: nil)

        #expect(await dialer.timeoutsUsed == [.seconds(15)])
    }

    // MARK: Preflight probe sweep and pick flow

    /// FakeTransportConnector connects (and pings) every address it is
    /// handed, so a multi-address sweep finds every candidate reachable.
    private func makeOnboardingStore(
        host: Host,
        connector: any TransportConnector,
        defaults: UserDefaults
    ) -> HostOnboardingStore {
        HostOnboardingStore(
            host: host,
            connector: connector,
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(defaults: defaults, hostID: host.id))
    }

    @Test func sweepProbesEveryCandidateAndStopsForThePickWhenSeveralAnswer() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = makeOnboardingStore(
            host: Host(address: "lan.example", username: "dev", additionalAddresses: ["vpn.example"]),
            connector: FakeTransportConnector(
                outcome: .connects(pingResult: .success(
                    ServerInfo(version: "0.7.5", protocolVersion: 17)))),
            defaults: defaults)

        await store.runChecks()

        // Both paths answered; the run stops for the user's pick.
        #expect(store.pendingAddressChoice == ["lan.example", "vpn.example"])
        #expect(store.report == nil)
        #expect(store.candidateStates["lan.example"] == .reachable)
        #expect(store.candidateStates["vpn.example"] == .reachable)
    }

    @Test func pickingAnAddressConnectsThroughItAndPersistsThePreference() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: .success(
                ServerInfo(version: "0.7.5", protocolVersion: 17))))
        let host = Host(
            address: "lan.example", username: "dev",
            additionalAddresses: ["vpn.example"])
        let store = makeOnboardingStore(host: host, connector: connector, defaults: defaults)

        await store.runChecks()
        await store.chooseAddress("vpn.example")

        #expect(store.pendingAddressChoice == nil)
        #expect(store.report?.isFullyPassed == true)
        #expect(store.workingAddress?.address == "vpn.example")

        // The pick persists as the preferred order: the next run probes the
        // VPN path first.
        let reloadedStore = makeOnboardingStore(
            host: host, connector: connector, defaults: defaults)
        #expect(reloadedStore.orderedCandidates == ["vpn.example", "lan.example"])
    }

    @Test func exactlyOneReachableCandidateAutoConnects() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        // Scripted per-address outcomes through the TransportConnector
        // seam: lan throws unreachable, vpn connects.
        let connector = AddressScriptedConnector(
            reachable: ["vpn.example"],
            pingResult: .success(ServerInfo(version: "0.7.5", protocolVersion: 17)))
        let store = makeOnboardingStore(
            host: Host(address: "lan.example", username: "dev", additionalAddresses: ["vpn.example"]),
            connector: connector,
            defaults: defaults)

        await store.runChecks()

        #expect(store.pendingAddressChoice == nil)
        #expect(store.report?.isFullyPassed == true)
        #expect(store.workingAddress?.address == "vpn.example")
        #expect(store.candidateStates["lan.example"] == .unreachable)
        #expect(store.candidateStates["vpn.example"] == .reachable)
    }

    @Test func noReachableCandidateFailsTheConnectionCheck() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let connector = AddressScriptedConnector(reachable: [], pingResult: .failure(.timedOut))
        let store = makeOnboardingStore(
            host: Host(address: "lan.example", username: "dev", additionalAddresses: ["vpn.example"]),
            connector: connector,
            defaults: defaults)

        await store.runChecks()

        #expect(store.pendingAddressChoice == nil)
        guard case .failed(let hint) = try #require(store.report)[.connection] else {
            Issue.record("an all-unreachable sweep should fail the connection check")
            return
        }
        #expect(hint.contains("None of this Host's addresses"))
    }

    @Test func preferredPickMovesItsAddressFirstForDialing() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host(
            address: "lan.example", username: "dev",
            additionalAddresses: ["vpn.example", "tailnet.example"])

        let store = PreferredAddressStore(defaults: defaults, hostID: host.id)
        store.prefer("tailnet.example", candidates: host.candidateAddresses)

        #expect(
            store.preferredOrder(for: host.candidateAddresses)
                == ["tailnet.example", "lan.example", "vpn.example"])
    }

    @Test func stalePickForAnEditedHostIsIgnored() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host(address: "lan.example", username: "dev")

        let store = PreferredAddressStore(defaults: defaults, hostID: host.id)
        store.prefer("removed.example", candidates: ["lan.example", "removed.example"])

        // The Host no longer carries the picked address; the configured
        // order wins.
        #expect(store.preferredOrder(for: host.candidateAddresses) == ["lan.example"])
    }

    // MARK: Support

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-host-multipath-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}
