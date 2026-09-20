import Foundation

/// Remembers which address the user last chose for a multi-path Host, so the
/// next dial tries that path first instead of re-probing from the stored
/// default. A pick updates the *order*: the chosen address moves to the
/// front, the rest keep their relative order (stability matters — it keeps
/// the fallback chain unchanged behind the pick).
///
/// Deliberately not part of `Host`: reordering the stored `address` on a
/// background probe would silently rewrite the user's Host catalog, and the
/// catalog is the user's explicit configuration. This is per-device
/// preference state, so it lives in UserDefaults keyed by Host id.
///
/// `@unchecked Sendable`: UserDefaults is documented thread-safe; the same
/// promise `HostStore` relies on for its own `nonisolated(unsafe)` reference.
struct PreferredAddressStore: @unchecked Sendable {
    private let defaults: UserDefaults?
    private let defaultsKey: String

    init(defaults: UserDefaults = .standard, hostID: Host.ID) {
        self.defaults = defaults
        self.defaultsKey = Self.key(for: hostID)
    }

    /// The preferred dialing order for `candidates`, or `candidates` itself
    /// when no pick has been made: the picked address first, the rest in
    /// their original relative order. Addresses not in `candidates` (a Host
    /// edited since the pick) are ignored, so an edited catalog is never
    /// resurrected with stale addresses.
    func preferredOrder(for candidates: [String]) -> [String] {
        guard
            let picked = defaults?.stringArray(forKey: defaultsKey),
            let first = picked.first,
            candidates.contains(first)
        else { return candidates }
        return [first] + candidates.filter { $0 != first }
    }

    /// Records `address` as the Host's preferred path, moving it ahead of
    /// every other candidate.
    func prefer(_ address: String, candidates: [String]) {
        defaults?.set([address] + candidates.filter { $0 != address }, forKey: defaultsKey)
    }

    /// Drops the stored preference (a Host whose candidates no longer match
    /// keeps dialing from its configured order).
    func clear() {
        defaults?.removeObject(forKey: defaultsKey)
    }

    private static func key(for hostID: Host.ID) -> String {
        "host-preferred-address-\(hostID.uuidString)"
    }
}
