import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0
//
// Sessions/Hosts blending (plan Phase 5): on a Host connect, ask the live
// transport which herdr sessions exist on that machine and offer the ones no
// catalog entry claims yet as quick-add entries. The decision logic is pure
// and network-free so it is unit-testable with plain fixture values; the
// store owns only the one `listSessions` round trip and the HostStore write.

/// Which discovered sessions are worth offering, given the Host catalog.
/// Pure: same inputs, same offers — no clock, no network, no device state.
enum SessionDiscovery: Sendable {
    /// One offer the Hosts list can show as a quick-add row.
    struct Offer: Sendable, Equatable, Identifiable {
        /// The herdr session name (never the default session — that is the
        /// blank-session Host shape, already covered by the Host itself).
        let sessionName: String
        /// Running state straight from discovery; a stopped session can be
        /// added but starts unreachable.
        let isRunning: Bool

        var id: String { sessionName }

        init(sessionName: String, isRunning: Bool) {
            self.sessionName = sessionName
            self.isRunning = isRunning
        }
    }

    /// The connection coordinates two Host entries share when they point at
    /// the same machine: address, port, and account. A jump-Host setup is
    /// part of the machine's identity too — quick-adds inherit it.
    struct MachineKey: Sendable, Equatable, Hashable {
        let address: String
        let port: Int
        let username: String

        init(host: Host) {
            address = host.address
            port = host.port
            username = host.username
        }
    }

    /// Sessions on `machine` that no catalog Host already claims. The
    /// default session is never offered: it is the blank-session Host shape,
    /// and the machine's original Host entry already covers it. Unknown
    /// session names typed into older Hosts count as claimed too, so a
    /// re-discovery never offers the same session twice.
    static func offers(
        discovered: [HerdrSession], machine: MachineKey, catalog: [Host]
    ) -> [Offer] {
        let claimed = Set(catalog
            .filter { MachineKey(host: $0) == machine }
            .map { $0.sessionName })
        return discovered
            .filter { !$0.isDefault && !claimed.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { Offer(sessionName: $0.name, isRunning: $0.isRunning) }
    }

    /// The catalog Host a quick-add produces: a copy of the template Host
    /// pointing at the named session. Identity is fresh — each session is
    /// its own Host entry with its own Keychain password account.
    static func quickAddHost(from template: Host, offer: Offer) -> Host {
        Host(
            id: UUID(),
            name: template.name,
            address: template.address,
            port: template.port,
            username: template.username,
            authMethod: template.authMethod,
            sessionName: offer.sessionName,
            jumpAddress: template.jumpAddress,
            jumpPort: template.jumpPort,
            jumpUsername: template.jumpUsername)
    }
}

/// Drives one Host's session discovery over its live Console connection.
/// The Console connects first; discovery rides that connection (ADR 0011's
/// one-transport rule — no second dial for the probe).
@MainActor
@Observable
final class SessionDiscoveryStore {
    /// Offers keyed by the Host whose machine they were discovered on.
    /// One entry per connected Host; absent means not refreshed (or no
    /// connection to probe with).
    private(set) var offersByHost: [Host.ID: [SessionDiscovery.Offer]] = [:]
    /// Hosts whose probe failed this refresh; surfaced as a footnote, never
    /// as an error gate.
    private(set) var unavailableHostIDs: Set<Host.ID> = []

    /// The live-machine sessions probe, mirroring the Console's
    /// projection(for:).session.withTransport pattern.
    private let listSessions: @MainActor (Host.ID) async throws -> [HerdrSession]

    init(
        listSessions: @escaping @MainActor (Host.ID) async throws -> [HerdrSession]
    ) {
        self.listSessions = listSessions
    }

    /// Refreshes offers for `host` after its connection settled: one probe
    /// over the live connection, then the pure diff against the catalog.
    func refresh(host: Host, catalog: [Host]) async {
        do {
            let discovered = try await listSessions(host.id)
            offersByHost[host.id] = SessionDiscovery.offers(
                discovered: discovered,
                machine: SessionDiscovery.MachineKey(host: host),
                catalog: catalog)
            unavailableHostIDs.remove(host.id)
        } catch {
            // Discovery is an enhancement, never a gate: a Host whose
            // server predates `session list` keeps its manual session field.
            offersByHost[host.id] = []
            unavailableHostIDs.insert(host.id)
        }
    }

    /// Persists a quick-add. The new entry reuses the template's connection
    /// coordinates and auth; the session name is the only difference.
    func add(_ offer: SessionDiscovery.Offer, from template: Host, to catalog: HostStore) throws {
        try catalog.add(SessionDiscovery.quickAddHost(from: template, offer: offer))
    }
}
