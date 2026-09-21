import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Per-agent (per-pane) detail-level persistence, namespaced in UserDefaults
// so it never collides with the app's own keys. Pure Foundation — no
// SwiftUI/@Observable here — so the views can bind it however they like.

/// Detail-level persistence keyed by pane id (one window shows one agent, so
/// pane id is agent id). Stored in a dedicated `dev.houz42.heeler.chat`
/// UserDefaults suite.
///
/// `UserDefaults` is documented thread-safe, hence `@unchecked Sendable`.
struct ChatDetailLevelStore: @unchecked Sendable {
    static let suiteName = "dev.houz42.heeler.chat"
    static let defaultKey = "detailLevel.default"

    private let defaults: UserDefaults

    /// The live store backed by the namespaced suite (`.standard` if the
    /// suite cannot be created — the levels are cosmetic, not load-bearing).
    static let shared = ChatDetailLevelStore(
        defaults: UserDefaults(suiteName: suiteName) ?? .standard)

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The saved level for `paneID` with the settings-driven default
    /// fallback (#A settings revision): a pane WITHOUT an explicit
    /// saved value falls back to the persisted default (the
    /// "default" pseudo-pane the Settings page writes), then to the
    /// contract default L0. A pane WITH an explicit save always wins —
    /// including an explicit L0 over a default L2.
    func level(paneID: String) -> DetailLevel {
        let key = Self.key(paneID: paneID)
        // `object(forKey:)` distinguishes an EXPLICIT 0 (saved L0) from
        // a missing key — `integer(forKey:)` collapses both to 0.
        if defaults.object(forKey: key) != nil {
            let raw = defaults.integer(forKey: key)
            return DetailLevel(rawValue: raw) ?? defaultFallback
        }
        // No per-pane value: the user's chosen default, else L0.
        return defaultFallback
    }

    /// The user's default conversation detail (Settings → Default
    /// Conversation Detail), L0 when never set. Defensive against
    /// hand-edited out-of-range values.
    private var defaultFallback: DetailLevel {
        let raw = defaults.integer(forKey: Self.defaultKey)
        return DetailLevel(rawValue: raw) ?? .l0
    }

    /// Persists the level for `paneID` immediately.
    func setLevel(_ level: DetailLevel, paneID: String) {
        defaults.set(level.rawValue, forKey: Self.key(paneID: paneID))
    }

    /// One key layout, defined once: pane ids come from the pairing layer and
    /// are arbitrary strings, so percent-encode them — they cannot forge the
    /// `default` key or collide with each other.
    static func key(paneID: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let escaped = paneID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "default"
        return escaped == "default" || escaped.isEmpty
            ? defaultKey
            : "detailLevel.\(escaped)"
    }
}
