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

    // MARK: Title guard (addresses never label the Host)

    @Test func aliasMatchingACandidateAddressNeverTitlesTheHost() {
        // The device-found shape: the .local address was typed into the
        // Alias field. The title must fall to the name, never show the
        // address in the label slot.
        let host = Host(
            name: "Mac", address: "192.168.31.71", username: "jhou",
            additionalAddresses: ["CMF79KM7YF.local"],
            alias: "CMF79KM7YF.local")

        #expect(host.displayAliasName == "Mac")
    }

    @Test func nameMatchingACandidateAddressFallsBackToUserAtAddress() {
        let host = Host(
            name: "CMF79KM7YF.local", address: "192.168.31.71", username: "jhou",
            additionalAddresses: ["CMF79KM7YF.local"])

        #expect(host.displayAliasName == "jhou@192.168.31.71")
    }

    @Test func nonAddressAliasAndNameStillTitleTheHost() {
        // The guard must not eat legitimate labels: a real alias or name
        // that merely RESEMBLES a hostname still wins.
        let aliased = Host(
            name: "Mac", address: "192.168.31.71", username: "jhou",
            additionalAddresses: ["CMF79KM7YF.local"],
            alias: "Studio Laptop")
        #expect(aliased.displayAliasName == "Studio Laptop")

        let named = Host(
            name: "Mac", address: "192.168.31.71", username: "jhou",
            additionalAddresses: ["CMF79KM7YF.local"])
        #expect(named.displayAliasName == "Mac")

        let primaryAddressLabel = Host(
            name: "192.168.31.71", address: "192.168.31.71", username: "jhou")
        #expect(primaryAddressLabel.displayAliasName == "jhou@192.168.31.71")
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

    @Test func editingInASecondAddressSurvivesSaveAndReload() throws {
        // The device-found defect's exact repro: an existing one-address
        // Host gains a second address in the Edit form; after save + reload
        // (what the detail page's store reads), BOTH candidates must be
        // there — the save path cannot drop the additional rows.
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let original = Host(address: "192.168.31.71", username: "jhou")
        try store.add(original)

        var draft = HostDraft(host: original)
        draft.addAddress("CMF79KM7YF.local")
        let saved = try #require(draft.makeHost(id: original.id))
        try store.update(saved)

        // The detail page's model reads a freshly loaded store's host.
        let reloadedHost = try #require(
            HostStore(defaults: defaults, secrets: InMemorySecretStore())
                .hosts.first)
        #expect(
            reloadedHost.candidateAddresses == ["192.168.31.71", "CMF79KM7YF.local"])
        #expect(reloadedHost.additionalAddresses == ["CMF79KM7YF.local"])
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

    @Test func intermediateEraCatalogDecodesWithoutTrapping() throws {
        // The device's store carries records written by the comma-field and
        // keyboard-bug era builds: multi-address + an alias polluted with
        // an address string. Every intermediate build persisted the same
        // shape (the comma parsing lived in the draft, not the model), so
        // this pins that a first read of that data cannot trap or fail —
        // including through the store's versioned envelope.
        let id = UUID()
        let intermediate = """
            {"version":1,"hosts":[{"id":"\(id.uuidString)",
              "name":"Mac","address":"192.168.31.71","port":22,
              "username":"jhou","authMethod":"deviceKey",
              "sessionName":"","additionalAddresses":["CMF79KM7YF.local"],
              "jumpAddress":"","jumpPort":22,"jumpUsername":"",
              "alias":"CMF79KM7YF.local"}]}
            """
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(Data(intermediate.utf8), forKey: "hosts")

        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        #expect(store.catalogLoadError == nil)
        let host = try #require(store.hosts.first)
        #expect(host.additionalAddresses == ["CMF79KM7YF.local"])
        #expect(host.candidateAddresses == ["192.168.31.71", "CMF79KM7YF.local"])
        // The polluted alias (an exact candidate match) never titles the
        // Host; the name wins.
        #expect(host.displayAliasName == "Mac")
    }

    // MARK: Draft (form) normalization

    @Test func draftRowsNormalizeToCandidates() throws {
        var draft = HostDraft()
        draft.username = "dev"
        draft.addresses = [
            AdditionalAddressRow(address: "192.168.31.71"),
            AdditionalAddressRow(address: "  CMF79KM7YF.local "),
            AdditionalAddressRow(address: "vpn.example"),
            AdditionalAddressRow(address: "  "),
        ]

        let host = try #require(draft.makeHost())
        #expect(host.address == "192.168.31.71")
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
        #expect(draft.normalizedAddresses == host.candidateAddresses)
        #expect(try draft.makeHost(id: host.id) == host)
    }

    @Test func freshDraftStartsWithOnePrimaryRow() throws {
        var draft = HostDraft()
        draft.addresses[0].address = "a.example"
        draft.username = "dev"

        #expect(try draft.makeHost()?.additionalAddresses == [])
    }

    // MARK: Draft row editing (the edit form's dynamic list)

    @Test func addRowAppendsAnAddress() {
        var draft = HostDraft()
        draft.addresses[0].address = "vpn.example"

        draft.addAddress()

        #expect(draft.addresses.map(\.address) == ["vpn.example", ""])
    }

    @Test func removingThePrimaryPromotesTheNextRow() throws {
        var draft = HostDraft()
        draft.username = "dev"
        draft.addresses = [
            AdditionalAddressRow(address: "lan.example"),
            AdditionalAddressRow(address: "vpn.example"),
        ]

        let removedID = draft.addresses[0].id
        draft.removeAddress(id: removedID)

        // The primary address is removable: the next remaining row takes
        // its place as the stored default.
        let host = try #require(draft.makeHost())
        #expect(host.address == "vpn.example")
        #expect(host.additionalAddresses == [])
        #expect(host.candidateAddresses == ["vpn.example"])
    }

    @Test func removingDownToTheLastRowIsBlocked() throws {
        var draft = HostDraft()
        draft.username = "dev"
        draft.addresses[0].address = "only.example"

        let removedID = draft.addresses[0].id
        draft.removeAddress(id: removedID)

        // A Host must always keep at least one addressable row.
        #expect(draft.addresses.map(\.address) == ["only.example"])
        #expect(try draft.makeHost()?.candidateAddresses == ["only.example"])
    }

    @Test func removingAnUnknownRowIDIsIgnored() {
        var draft = HostDraft()
        draft.addresses = [
            AdditionalAddressRow(address: "a.example"),
            AdditionalAddressRow(address: "b.example"),
        ]

        draft.removeAddress(id: UUID())

        #expect(draft.addresses.map(\.address) == ["a.example", "b.example"])
    }

    @Test func movingARowToTheFrontPromotesItToPrimary() throws {
        var draft = HostDraft()
        draft.username = "dev"
        draft.addresses = [
            AdditionalAddressRow(address: "a.example"),
            AdditionalAddressRow(address: "b.example"),
            AdditionalAddressRow(address: "c.example"),
        ]

        draft.moveAddresses(from: IndexSet(integer: 2), to: 0)

        let host = try #require(draft.makeHost())
        #expect(
            host.candidateAddresses == ["c.example", "a.example", "b.example"])
    }

    @Test func rowIdentitySurvivesEditsToItsAddress() {
        // The defect this pins: the row's SwiftUI identity (its id) must
        // not depend on the typed value. Editing the text — every keystroke
        // in the form — must leave the row's id untouched, or the field is
        // torn down and the keyboard dismissed per character.
        var draft = HostDraft()
        let originalID = draft.addresses[0].id

        for character in "vpn.example" {
            draft.addresses[0].address.append(character)
        }

        #expect(draft.addresses[0].id == originalID)
        #expect(draft.addresses[0].address == "vpn.example")
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

    @Test func switchingToAnotherReachableAddressWorksAfterTheInitialPick() async throws {
        // The device-found defect: after picking A, the Use controls
        // vanished, so the user could never switch to B. The store must
        // accept a later chooseAddress for ANY candidate (the view keeps
        // Use on reachable rows), re-dial through it, and move the mark.
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host(
            address: "lan.example", username: "dev",
            additionalAddresses: ["vpn.example"])
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: .success(
                ServerInfo(version: "0.7.5", protocolVersion: 17))))
        let store = makeOnboardingStore(host: host, connector: connector, defaults: defaults)

        await store.runChecks()
        // Both reachable → the pick list appears.
        #expect(store.pendingAddressChoice?.contains("vpn.example") == true)
        await store.chooseAddress("lan.example")
        #expect(store.workingAddress?.address == "lan.example")

        // After the initial pick the choice is gone — but choosing the
        // other reachable address must still work, dialing it and moving
        // the working-address mark.
        await store.chooseAddress("vpn.example")
        #expect(store.pendingAddressChoice == nil)
        #expect(store.report?.isFullyPassed == true)
        #expect(store.workingAddress?.address == "vpn.example")

        // The later pick REPLACED the earlier preference.
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

    // MARK: Live connection address (single source of truth)

    /// Records (host id, address) pairs the way the Console store folds
    /// them: REPLACE by host id, never accumulate.
    private final class ConnectedAddressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var marks: [Host.ID: String] = [:]

        func record(_ hostID: Host.ID, _ address: String) {
            lock.lock()
            marks[hostID] = address
            lock.unlock()
        }

        subscript(hostID: Host.ID) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return marks[hostID]
        }
    }

    private struct ReportingSweepConnector: TransportConnector {
        let reachable: Set<String>

        func connect(settings: SSHTransportSettings) async throws -> any Transport {
            try await connect(settings: settings, onCandidate: nil)
        }

        func connect(
            settings: SSHTransportSettings,
            onCandidate: (@Sendable (CandidateDialResult) -> Void)?
        ) async throws -> any Transport {
            for address in settings.dialCandidates where reachable.contains(address) {
                onCandidate?(
                    CandidateDialResult(address: address, failedAttempts: 0))
                return ScriptedTransport()
            }
            throw TransportError.sshUnreachable(detail: "no candidate answered")
        }
    }

    @Test func redialingThroughAnotherCandidateReplacesTheInUseMark() async throws {
        // The user invariant: at most ONE address may read as in use. The
        // production factory reports the winning address per dial, and the
        // store's map is keyed by Host — so a redial through candidate 2
        // after a connection via candidate 1 leaves ONLY candidate 2
        // marked; candidate 1's mark cannot survive its own replacement.
        let host = Host(
            address: "lan.example", username: "dev",
            additionalAddresses: ["vpn.example"])
        let marks = ConnectedAddressBox()
        let factory = ConsoleStore.sshSessionFactory(
            connector: ReportingSweepConnector(reachable: ["lan.example", "vpn.example"]),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            onConnectedAddress: { hostID, address in
                marks.record(hostID, address)
            })
        // Dial 1: LAN (first candidate) wins.
        let session1 = factory(host, [])
        await session1.resume()
        try await waitUntilMarked(marks, host: host, equals: "lan.example")
        try? await session1.end()

        // Dial 2 — LAN now down, VPN wins. The second dial REPLACES the
        // mark: only candidate 2 reads as in use.
        let reconnecting = ConsoleStore.sshSessionFactory(
            connector: ReportingSweepConnector(reachable: ["vpn.example"]),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            onConnectedAddress: { hostID, address in
                marks.record(hostID, address)
            })
        let session2 = reconnecting(host, [])
        await session2.resume()
        try await waitUntilMarked(marks, host: host, equals: "vpn.example")
        try? await session2.end()
    }

    /// The EventsSession dials on its own run task; poll until the store
    /// fold lands the winning address (bounded — a stuck dial fails the
    /// test instead of hanging it).
    private func waitUntilMarked(
        _ marks: ConnectedAddressBox, host: Host, equals expected: String
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while marks[host.id] != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(marks[host.id] == expected)
    }

    // MARK: Support

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-host-multipath-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}
