import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Per-pane macro-key persistence: the six slots of the tools keyboard's
// Macros page, each optionally bound to a Snippet plus literal argument
// text. Bindings are keyed by pane id (one window shows one agent, so
// pane id is agent id) and stored in the dedicated
// `dev.houz42.heeler.macros` UserDefaults suite so they never collide with
// the app's own keys. Pure Foundation — no SwiftUI/@Observable here — so
// the view binds it however it likes.
//
// `UserDefaults` is documented thread-safe, hence `@unchecked Sendable`.

/// A macro slot's binding: the Snippet the slot fires plus literal argument
/// text appended after its body when it fires.
struct MacroBinding: Codable, Equatable, Sendable {
    let slot: Int
    let snippetID: UUID
    let args: String
}

struct MacroKeyStore: @unchecked Sendable {
    static let suiteName = "dev.houz42.heeler.macros"
    /// The slot rows the Macros page renders: fixed, so a bound macro stays
    /// under the same thumb across panes and launches.
    static let slotRange = 1...6
    /// Args are appended to a Snippet body, so they follow the Snippet text
    /// policy's length bound.
    static let argsCharacterLimit = 4_000

    private static let blobVersion = 1

    private struct PersistedBlob: Codable {
        let version: Int
        let bindings: [MacroBinding]
    }

    private let defaults: UserDefaults

    /// The live store backed by the namespaced suite (`.standard` if the
    /// suite cannot be created — macros are convenience, not load-bearing).
    static let shared = MacroKeyStore(
        defaults: UserDefaults(suiteName: suiteName) ?? .standard)

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The pane's bindings by slot.
    func bindings(paneID: String) -> [Int: MacroBinding] {
        var bySlot: [Int: MacroBinding] = [:]
        for binding in rawBindings(paneID: paneID)
        where Self.slotRange.contains(binding.slot) {
            bySlot[binding.slot] = binding
        }
        return bySlot
    }

    func binding(slot: Int, paneID: String) -> MacroBinding? {
        bindings(paneID: paneID)[slot]
    }

    /// Binds (or rebinds) a slot. Args are normalized to the Snippet text
    /// policy on the way in — a binding that exists is a binding that is
    /// safe to fire. Returns false (and persists nothing) for an invalid
    /// slot or unsafe args.
    @discardableResult
    func setBinding(
        slot: Int, paneID: String, snippetID: UUID, args: String
    ) -> Bool {
        guard Self.slotRange.contains(slot) else { return false }
        let normalized = TerminalTextSafety.normalizingNewlines(args)
        guard Self.isValidArgs(normalized) else { return false }
        var all = rawBindings(paneID: paneID).filter { $0.slot != slot }
        all.append(MacroBinding(slot: slot, snippetID: snippetID, args: normalized))
        persist(all, paneID: paneID)
        return true
    }

    func clearBinding(slot: Int, paneID: String) {
        persist(
            rawBindings(paneID: paneID).filter { $0.slot != slot },
            paneID: paneID)
    }

    /// The Snippet policy for argument text: tab, LF, and CR aside, control
    /// characters would be read as commands by the remote terminal, and a
    /// CR in particular is a submit byte in disguise.
    static func isValidArgs(_ args: String) -> Bool {
        args.count <= argsCharacterLimit
            && TerminalTextSafety.containsOnlySafeScalars(args)
    }

    private func persist(_ bindings: [MacroBinding], paneID: String) {
        let blob = PersistedBlob(version: Self.blobVersion, bindings: bindings)
        guard let data = try? JSONEncoder().encode(blob) else { return }
        defaults.set(data, forKey: Self.key(paneID: paneID))
    }

    private func rawBindings(paneID: String) -> [MacroBinding] {
        guard let data = defaults.data(forKey: Self.key(paneID: paneID)) else {
            return []
        }
        guard let blob = try? JSONDecoder().decode(PersistedBlob.self, from: data),
            blob.version == Self.blobVersion
        else {
            // Macros are cheap to lose: unknown versions and undecodable
            // bytes start empty and the next write clobbers them, unlike
            // SnippetStore's deliberate no-write policy for authored text.
            return []
        }
        return blob.bindings
    }

    /// One key layout, defined once: pane ids come from the pairing layer
    /// and are arbitrary strings, so percent-encode them — the `macros.`
    /// prefix means no encoding can forge a collision with another key.
    static func key(paneID: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let escaped = paneID.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "macros.\(escaped)"
    }
}
