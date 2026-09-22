import Foundation
import Observation

/// The observable face of a Host's persisted active route
/// (`PreferredAddressStore`): one instance per process, shared by the
/// Hosts list page, the Hosts sheet, and the Host detail page, so every
/// surface renders the SAME active route and any write (a list tap, a
/// detail tap, the onboarding pick) re-renders them all. The underlying
/// persistence stays `PreferredAddressStore` — the exact order the
/// production dial consumes via `SSHTransportSettings.init(host:)` — so
/// the disk copy and the on-screen marks cannot drift apart either.
///
/// Writes are broadcast in the same turn: `activeRoute(for:)` reads
/// through UserDefaults on every access (cheap, and it keeps a fresh
/// store instance honest against a write made by a surface that does
/// not hold this instance — the onboarding store's own picks, say).
@MainActor
@Observable
final class HostActiveRouteStore {
    private let preferred: (Host.ID) -> PreferredAddressStore

    /// Injected so tests (and the demo) can point at a volatile suite.
    init(
        defaults: UserDefaults = .standard,
        hostIDs: @escaping () -> [Host.ID] = { [] }
    ) {
        // A fresh read per Host id: no cached map to invalidate, so an
        // out-of-band write (the detail's own store persisting a pick)
        // is still picked up on the next render pass.
        preferred = { PreferredAddressStore(defaults: defaults, hostID: $0) }
    }

    /// The address a Host's next dial leads with: the persisted pick, or
    /// the configured default. `candidates` is passed rather than read
    /// from a catalog so the store never needs the Host record itself.
    func activeRoute(hostID: Host.ID, candidates: [String]) -> String? {
        guard let first = preferred(hostID).preferredOrder(for: candidates).first
        else { return nil }
        return first
    }

    /// TAP = SWITCH: persists `address` as the Host's active route and
    /// broadcasts the change. Guarded by the caller's candidate list, so
    /// an edited catalog is never resurrected with a stale address.
    func setActiveRoute(_ address: String, hostID: Host.ID, candidates: [String]) {
        guard candidates.contains(address) else { return }
        preferred(hostID).prefer(address, candidates: candidates)
    }
}
