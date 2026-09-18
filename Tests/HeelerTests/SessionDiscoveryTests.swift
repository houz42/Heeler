import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Sessions/Hosts blending (Phase 5): the pure decision logic — which
// discovered herdr sessions are new versus already added — plus the store's
// refresh and quick-add paths over a stub listSessions closure.

// MARK: - Pure diff

@MainActor
@Suite("Session discovery diff")
struct SessionDiscoveryTests {
    private func host(
        name: String = "",
        address: String = "host.example",
        port: Int = 22,
        username: String = "dev",
        sessionName: String = ""
    ) -> Host {
        Host(
            name: name, address: address, port: port, username: username,
            sessionName: sessionName)
    }

    private func session(
        _ name: String, isDefault: Bool = false, isRunning: Bool = true
    ) -> HerdrSession {
        HerdrSession(name: name, isDefault: isDefault, isRunning: isRunning)
    }

    @Test func defaultSessionIsNeverOffered() {
        // The default session is the blank-session Host shape; the machine's
        // original Host entry already covers it.
        let offers = SessionDiscovery.offers(
            discovered: [session("default", isDefault: true)],
            machine: SessionDiscovery.MachineKey(host: host()),
            catalog: [])
        #expect(offers.isEmpty)
    }

    @Test func newNamedSessionsAreOfferedSortedByName() {
        let offers = SessionDiscovery.offers(
            discovered: [
                session("devbox", isRunning: false), session("main"),
                session("default", isDefault: true), session("archive"),
            ],
            machine: SessionDiscovery.MachineKey(host: host()),
            catalog: [host()])
        #expect(offers.map(\.sessionName) == ["archive", "devbox", "main"])
        #expect(offers.map(\.isRunning) == [true, false, true])
    }

    @Test func sessionsClaimedByCatalogHostsAreNotOffered() {
        let machine = SessionDiscovery.MachineKey(host: host())
        let catalog = [
            host(sessionName: "main"),           // claimed by a same-machine Host
            host(address: "other.example", sessionName: "devbox"),  // other machine
        ]
        let offers = SessionDiscovery.offers(
            discovered: [session("main"), session("devbox"), session("scratch")],
            machine: machine,
            catalog: catalog)
        // "main" is claimed; "devbox" is only claimed on a different machine,
        // so this machine may still offer it.
        #expect(offers.map(\.sessionName) == ["devbox", "scratch"])
    }

    @Test func machineKeyIgnoresDisplayNameAndSessionName() {
        // Two entries for the same machine with different labels and sessions
        // share one machine identity; what matters is address/port/account.
        let a = host(name: "Work laptop", sessionName: "main")
        let b = host(address: "host.example", sessionName: "scratch")
        #expect(
            SessionDiscovery.MachineKey(host: a)
                == SessionDiscovery.MachineKey(host: b))
        #expect(
            SessionDiscovery.MachineKey(host: a)
                != SessionDiscovery.MachineKey(
                    host: host(address: "elsewhere.example")))
        #expect(
            SessionDiscovery.MachineKey(host: a)
                != SessionDiscovery.MachineKey(host: host(port: 2222)))
        #expect(
            SessionDiscovery.MachineKey(host: a)
                != SessionDiscovery.MachineKey(host: host(username: "root")))
    }

    @Test func quickAddHostKeepsEverythingButIdentityAndSession() {
        let template = host(
            name: "Work laptop", address: "host.example", port: 2222,
            username: "root", sessionName: "main")
        let offer = SessionDiscovery.Offer(sessionName: "scratch", isRunning: true)
        let added = SessionDiscovery.quickAddHost(from: template, offer: offer)

        #expect(added.id != template.id)
        #expect(added.sessionName == "scratch")
        #expect(added.address == "host.example")
        #expect(added.port == 2222)
        #expect(added.username == "root")
        #expect(added.authMethod == template.authMethod)
        // A re-discovery after the add must not offer the same session again.
        let offers = SessionDiscovery.offers(
            discovered: [session("scratch")],
            machine: SessionDiscovery.MachineKey(host: template),
            catalog: [template, added])
        #expect(offers.isEmpty)
    }

    @Test func refreshPublishesOffersKeyedByHost() async {
        let first = host()
        let second = host()
        let sessionList: [Host.ID: [HerdrSession]] = [
            first.id: [HerdrSession(name: "main", isDefault: false, isRunning: true)],
        ]
        let store = SessionDiscoveryStore(listSessions: { sessionList[$0] ?? [] })

        await store.refresh(host: first, catalog: [first, second])
        await store.refresh(host: second, catalog: [first, second])

        #expect(store.offersByHost[first.id]?.map(\.sessionName) == ["main"])
        #expect(store.offersByHost[second.id] == [])
        #expect(store.unavailableHostIDs.isEmpty)
    }

    @Test func failedProbeMarksTheHostUnavailableAndKeepsOffersEmpty() async {
        struct ProbeUnavailable: Error {}
        let store = SessionDiscoveryStore { _ in throw ProbeUnavailable() }
        let host = self.host()

        await store.refresh(host: host, catalog: [host])

        #expect(store.offersByHost[host.id] == [])
        #expect(store.unavailableHostIDs == [host.id])
    }

    @Test func addPersistsAQuickAddHostThroughTheCatalog() throws {
        let suiteName = "SessionDiscoveryStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        let template = host()
        try catalog.add(template)

        let store = SessionDiscoveryStore { _ in [] }
        let offer = SessionDiscovery.Offer(sessionName: "main", isRunning: true)
        try store.add(offer, from: template, to: catalog)

        #expect(catalog.hosts.count == 2)
        #expect(catalog.hosts[1].sessionName == "main")
        #expect(catalog.hosts[1].address == template.address)
        #expect(catalog.hosts[1].id != template.id)
    }
}
