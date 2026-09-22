import SwiftUI
import Testing
import UIKit
@testable import Heeler

/// The two new Reading & Appearance stores (#A settings revision):
/// persistence contracts only — what a lost choice or a hand-edited
/// defaults file must do.
@MainActor
@Suite("Reading settings", .timeLimit(.minutes(1)))
struct ReadingSettingsTests {
    private func freshDefaults() throws -> UserDefaults {
        let suite = "reading-settings-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - Text size

    @Test func textSizeDefaultsToSystemAndNeverOverridesUnrecognizedValues() throws {
        let defaults = try freshDefaults()
        let settings = ReadingTextSizeSettings(defaults: defaults)
        #expect(settings.selection == .system)
        #expect(settings.readingSize == nil,
            "System must apply NO override: the device Dynamic Type flows through")

        // A hand-edited or future-format value must not break the app: the
        // choice falls back to System rather than a garbage size.
        defaults.set("gigantic", forKey: "reading-text-size")
        let reread = ReadingTextSizeSettings(defaults: defaults)
        #expect(reread.selection == .system)
        #expect(reread.readingSize == nil)
    }

    @Test func textSizePersistsSelectionAndSizeMatchesCase() throws {
        let defaults = try freshDefaults()
        let settings = ReadingTextSizeSettings(defaults: defaults)
        settings.select(.large)
        #expect(settings.selection == .large)
        #expect(settings.readingSize == .large)
        // The EXACT size pins directly (review finding 4: a clamp cannot
        // enlarge — .xLarge must be xLarge, not clamped below).
        settings.select(.xLarge)
        #expect(settings.readingSize == .xLarge)
        settings.select(.xxLarge)
        #expect(settings.readingSize == .xxLarge)
        // Back to large, then a relaunch must see large.
        settings.select(.large)
        let reread = ReadingTextSizeSettings(defaults: defaults)
        #expect(reread.selection == .large)
        // Selecting the same case is a no-op, not a re-write.
        settings.select(.large)
        #expect(reread.selection == .large)
    }

    @Test func everyTextSizeCaseHasATitleAndASize() {
        for size in ReadingTextSize.allCases {
            #expect(!size.title.isEmpty)
            if size == .system {
                #expect(size.readingSize == nil)
            } else {
                #expect(size.readingSize != nil,
                    "\(size.title) must set a size: an explicit choice that does nothing is a dead setting")
            }
        }
    }

    /// The shared-instance contract (review finding 4): the Settings
    /// page and the reading views must consume ONE store — the shared
    /// singleton is the default injected by every production root.
    @Test func sharedInstanceIsTheProcessWideDefault() {
        #expect(ReadingTextSizeSettings.shared === ReadingTextSizeSettings.shared,
            "the shared store must be a true singleton across injectors")
    }

    // MARK: - Default conversation detail

    @Test func defaultDetailLevelPersistsThroughTheExistingStore() throws {
        let suite = "reading-settings-detail-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatDetailLevelStore(defaults: defaults)
        let settings = DefaultDetailLevelSettings(store: store)

        // The untouched default is the store's contract default L0.
        #expect(settings.level == .l0)

        settings.level = .l2
        #expect(settings.level == .l2)
        // The write went through ChatDetailLevelStore's own key layout —
        // a reread through the SAME store sees it, and so does a per-pane
        // fallback path reading the default pseudo-pane.
        let reread = DefaultDetailLevelSettings(store: ChatDetailLevelStore(defaults: defaults))
        #expect(reread.level == .l2)
        #expect(store.level(paneID: "default") == .l2)
    }

    /// The consumer-level fallback contract (#A review finding 5): a
    /// fresh pane reads the SETTING's level; an explicit per-pane save
    /// — including L0 — wins over the default.
    @Test func freshPanesFallBackToTheSettingAndExplicitSavesWin() throws {
        let suite = "reading-settings-fallback-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatDetailLevelStore(defaults: defaults)

        // Default L2 set through the settings surface.
        store.setLevel(.l2, paneID: "default")
        // A FRESH pane (no explicit save) opens at the setting's level.
        #expect(store.level(paneID: "fresh-pane-1") == .l2,
            "a fresh conversation must start at the default level, not L0")

        // An EXPLICIT per-pane L0 wins over the default L2 — the user's
        // per-conversation choice takes precedence.
        store.setLevel(.l0, paneID: "fresh-pane-2")
        #expect(store.level(paneID: "fresh-pane-2") == .l0,
            "an explicit per-pane L0 must beat a default L2")

        // Changing the default later leaves explicit panes untouched.
        store.setLevel(.l3, paneID: "default")
        #expect(store.level(paneID: "fresh-pane-2") == .l0)
        #expect(store.level(paneID: "another-fresh-pane") == .l3)

        // Hand-edited garbage per-pane value falls back defensively.
        defaults.set(99, forKey: "detailLevel.garbage-pane")
        #expect(store.level(paneID: "garbage-pane") == .l3,
            "an out-of-range per-pane value falls back to the default")
    }
}
