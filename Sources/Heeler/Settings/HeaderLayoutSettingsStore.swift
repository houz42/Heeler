import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0

/// Which layout the in-Agent header (the nav-bar principal on the chat and
/// terminal detail surfaces) shows: the Host's agent-list layout, or the
/// separately configured global one.
enum HeaderLayoutMode: String, Equatable, Sendable {
    case sameAsList
    case custom
}

/// In-Agent header layout persistence in the `dev.houz42.heeler.headerLayout`
/// UserDefaults suite: the `sameAsList`/`custom` mode plus the custom global
/// layout. The layout itself lives in a nested `AgentRowLayoutStore` under one
/// fixed Host identity, so the lenient-decode discipline, validation, and the
/// token editing components (`AgentListFieldsEditor`, the Add Field sheet) are
/// the catalog's own, not a second implementation of them.
@MainActor
@Observable
final class HeaderLayoutSettingsStore {
    static let suiteName = "dev.houz42.heeler.headerLayout"
    private static let modeKey = "header-layout-mode"

    /// The fixed identity the custom layout is stored under in the nested
    /// per-Host catalog — a global preference wearing the catalog's shape so
    /// every catalog guarantee (lenient decode, atomic validated writes,
    /// unreadable-bytes handling) applies to it unchanged.
    static let customLayoutHostID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2
    ))

    /// The nested catalog the custom layout is persisted through.
    let layouts: AgentRowLayoutStore
    /// Defaults to `sameAsList`, preserving the previous behavior: the
    /// header follows the Host's agent-list layout (Settings → Agent list
    /// fields). An unknown stored value falls back the same way.
    private(set) var mode: HeaderLayoutMode
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    /// The live store backed by the dedicated suite (`.standard` when the
    /// suite cannot be created — the header layout is cosmetic, not
    /// load-bearing).
    static let shared = HeaderLayoutSettingsStore(
        defaults: UserDefaults(suiteName: suiteName) ?? .standard)

    init(defaults: UserDefaults) {
        self.defaults = defaults
        layouts = AgentRowLayoutStore(defaults: defaults)
        mode = defaults.string(forKey: Self.modeKey)
            .flatMap(HeaderLayoutMode.init(rawValue:)) ?? .sameAsList
    }

    /// True when the nested catalog cannot be read: the stored custom layout
    /// is refused until `resetUnreadable` discards it. The mode itself is a
    /// plain string and never fails to read.
    var loadError: AgentRowLayoutStoreError? { layouts.catalogLoadError }

    /// The custom global layout: the stored choice, or the Console default
    /// when none was saved yet. Per-kind overrides never apply — the header
    /// renders one agent at a time.
    var customLayout: AgentRowLayout {
        layouts.resolvedLayout(for: Self.customLayoutHostID, pluginSnapshot: nil)
    }

    /// Sets the mode, persisting at once. A no-op writes nothing.
    func setMode(_ mode: HeaderLayoutMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }

    /// Saves the custom layout through the nested catalog, persisting at
    /// once. The header is a Console surface: at most three rows.
    func setCustomLayout(_ layout: AgentRowLayout) throws {
        try layout.validateForConsole()
        try layouts.setLayout(layout, for: Self.customLayoutHostID)
    }

    /// The header's layout for a Host: the Host's agent-list layout when
    /// `sameAsList` (the default), the custom global layout when `custom`.
    /// An unreadable catalog keeps the same-as-list default, which never
    /// reads the suspect bytes.
    func headerLayout(
        sameAsList: (Host.ID) -> AgentRowLayout, for hostID: Host.ID
    ) -> AgentRowLayout {
        mode == .sameAsList ? sameAsList(hostID) : customLayout
    }

    /// Discards an unreadable saved preference — both the mode and the
    /// custom layout — so the header follows the Host's agent-list layout
    /// again and writes are accepted. A readable preference is left alone.
    func resetUnreadable() {
        guard loadError != nil else { return }
        layouts.resetUnreadableCatalog()
        defaults.removeObject(forKey: Self.modeKey)
        mode = .sameAsList
    }
}
