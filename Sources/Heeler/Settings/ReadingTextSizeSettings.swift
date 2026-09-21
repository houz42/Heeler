import Foundation
import Observation
import SwiftUI

/// The reading-text-size preference (#A settings revision). `system` (the
/// default) follows Dynamic Type with NO override; an explicit choice
/// clamps the app's dynamic type size at the root via `.dynamicTypeSize`.
/// This is a READING size — it must never rescale the compact chrome's
/// own geometry, only which type sizes text renders at.
enum ReadingTextSize: String, CaseIterable, Identifiable, Sendable {
    /// Follows the system Dynamic Type setting; no override is applied.
    case system
    case small
    case medium
    case large
    case xLarge
    case xxLarge

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .xLarge: "Extra Large"
        case .xxLarge: "Extra Extra Large"
        }
    }

    /// The EXACT dynamic-type size reading views render at (review
    /// finding 4: an upper-bound clamp cannot ENLARGE a system-large
    /// text to a chosen XL — the explicit choice pins the size
    /// directly). nil = System: no override, the device setting flows
    /// through.
    var readingSize: DynamicTypeSize? {
        switch self {
        case .system: nil
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .xLarge
        case .xxLarge: .xxLarge
        }
    }
}

/// The persisted choice, applied once at the app root so every surface —
/// reading text in chat, lists, and detail pages — follows one value.
@MainActor
@Observable
final class ReadingTextSizeSettings {
    private static let defaultsKey = "reading-text-size"

    private(set) var selection: ReadingTextSize
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection =
            defaults.string(forKey: Self.defaultsKey)
            .flatMap(ReadingTextSize.init(rawValue:)) ?? .system
    }

    /// The process-wide instance the roots and the Settings page share
    /// (review finding 4: ONE store; the demo root injects its own
    /// through the SettingsView initializer instead).
    static let shared = ReadingTextSizeSettings()

    /// nil when following the system: the reading views apply nothing.
    var readingSize: DynamicTypeSize? {
        selection.readingSize
    }

    func select(_ size: ReadingTextSize) {
        guard size != selection else { return }
        selection = size
        defaults.set(size.rawValue, forKey: Self.defaultsKey)
    }
}

/// The default-conversation-detail preference's own persistence. The
/// per-agent levels live in `ChatDetailLevelStore` (namespaced suite,
/// pane-keyed); this store only holds the DEFAULT that new conversations
/// and panes without a saved choice start at — the same namespaced suite,
/// under the store's own `detailLevel.default` key, so the default and
/// per-pane levels can never drift apart in format or location.
@MainActor
@Observable
final class DefaultDetailLevelSettings {
    private let store: ChatDetailLevelStore

    init(store: ChatDetailLevelStore = .shared) {
        self.store = store
    }

    /// The default level, read through the same store the per-pane
    /// levels use: the shared "default" pseudo-pane key.
    var level: DetailLevel {
        get { store.level(paneID: "default") }
        set { store.setLevel(newValue, paneID: "default") }
    }
}
/// Applies the reading-text-size to READING views (review finding 4:
/// chat/reading text only — never the window root, so the compact
/// chrome's semantic fonts keep the design's scale). Nothing when the
/// choice is System: the device's Dynamic Type flows through.
struct ReadingTextSizeModifier: ViewModifier {
    let size: DynamicTypeSize?

    func body(content: Content) -> some View {
        if let size {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}
