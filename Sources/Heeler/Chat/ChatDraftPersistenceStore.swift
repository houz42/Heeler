import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Per-pane chat draft persistence (item 18): a half-typed message
// survives leaving and returning to a chat (surface switches, agent
// switches, background/foreground). Same shape as ChatDetailLevelStore
// — UserDefaults-backed, keyed by pane id, pure Foundation.

/// One pane's saved composer state. `items` is the DRAFT-ITEM rail in
/// a Codable form (attachments' remote paths + quotes; preview image
/// BYTES deliberately never persist — a tile reloads its thumbnail on
/// demand, and a multi-MB blob in UserDefaults would jank the main
/// thread on every write).
struct ChatPaneDraft: Codable, Equatable, Sendable {
    var text: String
    /// UTF-16 selection so a restored draft can put the caret back where
    /// it was.
    var caretLocation: Int
    var items: [Item]

    struct Item: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case image
            case file
            case quote
        }
        var kind: Kind
        var id: String
        var remotePath: String?
        var name: String?
        var text: String?
        var author: String?
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && items.isEmpty
    }
}

/// Draft persistence keyed by pane id, in the same namespaced
/// `dev.houz42.heeler.chat` suite as the detail levels ( UserDefaults
/// is documented thread-safe, hence `@unchecked Sendable`).
struct ChatDraftPersistenceStore: @unchecked Sendable {
    static let suiteName = "dev.houz42.heeler.chat"

    private let defaults: UserDefaults

    static let shared = ChatDraftPersistenceStore(
        defaults: UserDefaults(suiteName: suiteName) ?? .standard)

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The saved draft for `paneID`, or nil when none was ever saved
    /// (or the stored value was hand-corrupted — an honest miss, never
    /// a crash).
    func draft(paneID: String) -> ChatPaneDraft? {
        guard let data = defaults.data(forKey: Self.key(paneID: paneID))
        else { return nil }
        return try? JSONDecoder().decode(
            ChatPaneDraft.self, from: data)
    }

    /// Persists the draft for `paneID` immediately. An empty draft
    /// REMOVES the entry (a cleared composer stays cleared).
    func save(_ draft: ChatPaneDraft, paneID: String) {
        let key = Self.key(paneID: paneID)
        if draft.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(
            (try? JSONEncoder().encode(draft)) ?? Data(),
            forKey: key)
    }

    /// Clears the saved draft (a successful Send; the next message
    /// starts clean — item 7's persistence-side twin).
    func clear(paneID: String) {
        defaults.removeObject(forKey: Self.key(paneID: paneID))
    }

    /// One key layout, percent-encoded pane ids — same discipline as
    /// ChatDetailLevelStore so pane ids cannot forge or collide keys.
    static func key(paneID: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let escaped = paneID.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "draft.\(escaped)"
    }
}
