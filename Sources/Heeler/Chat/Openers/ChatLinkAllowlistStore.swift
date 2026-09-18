import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Per-domain open preference for chat links: does this domain open through
// the embedded Safari view? Persisted in the dedicated
// `dev.houz42.heeler.openers` UserDefaults suite, so nothing about the
// choice is ever sent anywhere — the domain opens locally or it doesn't.
// Pure Foundation; the sheet view reads and writes it through this store.

/// Per-domain "open in the embedded Safari view" decisions, keyed by the
/// link's host. `UserDefaults` is documented thread-safe, hence
/// `@unchecked Sendable`.
struct ChatLinkAllowlistStore: @unchecked Sendable {
    static let suiteName = "dev.houz42.heeler.openers"

    private let defaults: UserDefaults

    /// The live store backed by the namespaced suite (`.standard` when the
    /// suite cannot be created — decisions are convenience, not load-bearing).
    static let shared = ChatLinkAllowlistStore(
        defaults: UserDefaults(suiteName: suiteName) ?? .standard)

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The saved decision for `host`, or nil when no decision exists (the
    /// presentation asks). Hosts are stored lowercased so the lookup is
    /// case-insensitive. An explicit presence check (not `integer()`'s 0
    /// default) keeps "no decision" distinct from "refused".
    func allowsEmbeddedBrowse(host: String) -> Bool? {
        let key = Self.key(host: host)
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    /// Persists the decision for `host` immediately.
    func setAllowsEmbeddedBrowse(_ allowed: Bool, host: String) {
        defaults.set(allowed, forKey: Self.key(host: host))
    }

    /// One key layout, defined once; hosts are arbitrary strings, so
    /// percent-encode them — they cannot forge the `default` key or collide
    /// with each other.
    static func key(host: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let escaped = host.lowercased().addingPercentEncoding(
            withAllowedCharacters: allowed) ?? "default"
        return "embeddedBrowse.\(escaped)"
    }
}
