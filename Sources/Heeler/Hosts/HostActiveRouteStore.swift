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
/// The broadcast is REAL observation, not incidental: `revision` is the
/// observable heartbeat. Every read touches it (registering the
/// observation), and every write bumps it — so a preference change
/// re-renders every reader on its own, with no connection-status change
/// needed to mask it.
@MainActor
@Observable
final class HostActiveRouteStore {
    /// Bumped on every preference write. Readers touch it in
    /// `activeRoute(hostID:candidates:)` so the observation registers;
    /// a write re-renders them without any unrelated state change.
    private(set) var revision: UInt64 = 0

    private let preferred: (Host.ID) -> PreferredAddressStore

    /// Injected so tests (and the demo) can point at a volatile suite.
    init(defaults: UserDefaults = .standard) {
        // A fresh read per Host id: no cached map to invalidate, so an
        // out-of-band write (the detail's own store persisting a pick)
        // is still picked up on the next render pass.
        preferred = { PreferredAddressStore(defaults: defaults, hostID: $0) }
    }

    /// The address a Host's next dial leads with: the persisted pick, or
    /// nil when `candidates` is empty. Touches `revision` so the caller's
    /// observation registers — this is what makes a write re-render the
    /// reader, the whole point of the shared store.
    func activeRoute(hostID: Host.ID, candidates: [String]) -> String? {
        _ = revision
        return preferred(hostID).preferredOrder(for: candidates).first
    }

    /// THE route switch (identical on every surface): persists `address`
    /// as the Host's active route and broadcasts the change. The dial
    /// itself is the caller's one step — the Console's `retryHost`, the
    /// same path a Reconnect press takes — so the connect status,
    /// animation, and any failure surface through the Console's
    /// single-source map. Guarded by the caller's candidate list, so an
    /// edited catalog is never resurrected with a stale address.
    func setActiveRoute(_ address: String, hostID: Host.ID, candidates: [String]) {
        guard candidates.contains(address) else { return }
        preferred(hostID).prefer(address, candidates: candidates)
        revision &+= 1
    }
}
