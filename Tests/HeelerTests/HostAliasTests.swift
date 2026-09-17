import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0

/// The user-assignable Host alias: resolution precedence, persistence,
/// normalization, and migration of Hosts saved before the field existed.
@Suite("Host alias")
@MainActor
struct HostAliasTests {
    // MARK: Resolution

    @Test func aliasWinsOverTheName() {
        let host = Host(address: "a.example", username: "dev", alias: "Laptop")
        #expect(host.displayAliasName == "Laptop")
    }

    @Test func nilAliasFallsBackToTheName() {
        let host = Host(name: "Workbox", address: "a.example", username: "dev")
        #expect(host.displayAliasName == "Workbox")
    }

    @Test func nilAliasFallsBackToUserAtAddressWhenTheNameIsBlank() {
        let host = Host(address: "a.example", username: "dev")
        #expect(host.displayAliasName == "dev@a.example")
    }

    // Decode and the form normalize stored aliases; the blank checks guard
    // Hosts constructed directly with a degenerate alias value.
    @Test(arguments: ["", "  "])
    func degenerateAliasFallsBackToTheName(alias: String) {
        let host = Host(name: "Workbox", address: "a.example", username: "dev", alias: alias)
        #expect(host.displayAliasName == "Workbox")
    }

    // MARK: Migration

    @Test func hostsSavedBeforeAliasesDecodeWithNilAlias() throws {
        let id = UUID()
        let legacy = """
            [{"id":"\(id.uuidString)","name":"Old","address":"old.example","port":22,
              "username":"dev","authMethod":"deviceKey"}]
            """
        let host = try JSONDecoder().decode([Host].self, from: Data(legacy.utf8)).first

        #expect(host?.alias == nil)
        #expect(host?.displayAliasName == "Old")
    }

    @Test func whitespaceOnlyPersistedAliasDecodesAsNil() throws {
        let id = UUID()
        let whitespace = """
            [{"id":"\(id.uuidString)","name":"Old","address":"old.example","port":22,
              "username":"dev","authMethod":"deviceKey","alias":"   "}]
            """
        let host = try JSONDecoder().decode([Host].self, from: Data(whitespace.utf8)).first

        #expect(host?.alias == nil)
        #expect(host?.displayAliasName == "Old")
    }

    // MARK: Draft normalization

    @Test func draftRoundTripsAnAlias() throws {
        let host = Host(
            id: UUID(), name: "Workbox", address: "box.example", port: 2222,
            username: "dev", authMethod: .password, sessionName: "work", alias: "Laptop")

        let draft = HostDraft(host: host)
        #expect(draft.alias == "Laptop")
        #expect(try draft.makeHost(id: host.id) == host)
    }

    @Test func blankDraftAliasNormalizesToNil() throws {
        let original = Host.fixture(alias: "Laptop")
        var draft = HostDraft(host: original)
        draft.alias = "   "

        let host = try #require(draft.makeHost(id: original.id))
        #expect(host.alias == nil)
        // Everything but the alias matches the original Host.
        var expected = original
        expected.alias = nil
        #expect(host == expected)
    }

    @Test func freshDraftHasNoAlias() throws {
        var draft = HostDraft()
        draft.address = "new.example"
        draft.username = "dev"

        #expect(try draft.makeHost()?.alias == nil)
    }

    // MARK: Store persistence

    @Test func aliasSurvivesAddAndReload() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let secrets = InMemorySecretStore()
        let host = Host.fixture(alias: "The Big Server")

        try HostStore(defaults: defaults, secrets: secrets).add(host)

        let reloaded = HostStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.hosts == [host])
        #expect(reloaded.hosts.first?.displayAliasName == "The Big Server")
    }

    @Test func aliasEditsSurviveUpdateRoundTrips() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        var host = Host.fixture(alias: "First")
        try store.add(host)

        host.alias = nil
        try store.update(host)
        #expect(HostStore(defaults: defaults, secrets: InMemorySecretStore()).hosts == [host])

        host.alias = "Renamed"
        try store.update(host)
        #expect(HostStore(defaults: defaults, secrets: InMemorySecretStore()).hosts == [host])
    }

    @Test func legacyCatalogWithoutAliasKeyLoadsCleanly() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let id = UUID()
        let legacy = """
            [{"id":"\(id.uuidString)","name":"Old","address":"old.example","port":22,
              "username":"dev","authMethod":"deviceKey"}]
            """
        defaults.set(Data(legacy.utf8), forKey: "hosts")

        let store = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let host = try #require(store.hosts.first)

        #expect(host.alias == nil)
        #expect(host.displayAliasName == "Old")
    }

    // MARK: Support

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-host-alias-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }
}

extension Host {
    /// Alias-friendly fixture: the shared `HostStoreTests.fixture` lives in
    /// that suite's file and does not take an alias.
    static func fixture(alias: String?) -> Host {
        Host(address: "host.example", username: "dev", alias: alias)
    }
}
