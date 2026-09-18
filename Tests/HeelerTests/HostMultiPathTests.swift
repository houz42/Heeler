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

    @Test func draftParsesCommaSeparatedAddresses() throws {
        var draft = HostDraft()
        draft.address = "192.168.31.71"
        draft.username = "dev"
        draft.additionalAddresses = " CMF79KM7YF.local , vpn.example ,"

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
        #expect(draft.additionalAddresses == "CMF79KM7YF.local, vpn.example")
        #expect(try draft.makeHost(id: host.id) == host)
    }

    @Test func blankDraftFieldMeansSinglePath() throws {
        var draft = HostDraft()
        draft.address = "a.example"
        draft.username = "dev"
        draft.additionalAddresses = "  "

        #expect(try draft.makeHost()?.additionalAddresses == [])
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

    // MARK: Preflight reporting

    @Test func multiAddressPreflightRunStillGoesAllGreen() async throws {
        // FakeTransportConnector connects without candidate reporting (the
        // default protocol path), so workingAddress stays nil while every
        // check still passes. The winning-address value itself is exercised
        // by the dialer seam tests above.
        let store = HostOnboardingStore(
            host: Host(
                address: "lan.example", username: "dev",
                additionalAddresses: ["vpn.example"]),
            connector: FakeTransportConnector(
                outcome: .connects(pingResult: .success(
                    ServerInfo(version: "0.7.5", protocolVersion: 17)))),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()))

        await store.runChecks()

        #expect(store.report?.isFullyPassed == true)
        #expect(store.workingAddress == nil)
    }

    // MARK: Support

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-host-multipath-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}
