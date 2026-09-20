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
        #expect(settings.dynamicTypeSizeClamp == nil,
            "System must apply NO override: the device Dynamic Type flows through")

        // A hand-edited or future-format value must not break the app: the
        // choice falls back to System rather than a garbage clamp.
        defaults.set("gigantic", forKey: "reading-text-size")
        let reread = ReadingTextSizeSettings(defaults: defaults)
        #expect(reread.selection == .system)
        #expect(reread.dynamicTypeSizeClamp == nil)
    }

    @Test func textSizePersistsSelectionAndClampMatchesCase() throws {
        let defaults = try freshDefaults()
        let settings = ReadingTextSizeSettings(defaults: defaults)
        settings.select(.large)
        #expect(settings.selection == .large)
        #expect(settings.dynamicTypeSizeClamp!.contains(DynamicTypeSize.large))
        // Survives a new store over the same defaults (relaunch).
        let reread = ReadingTextSizeSettings(defaults: defaults)
        #expect(reread.selection == .large)
        // Selecting the same case is a no-op, not a re-write.
        settings.select(.large)
        #expect(reread.selection == .large)
    }

    @Test func everyTextSizeCaseHasATitleAndACoherentClamp() {
        for size in ReadingTextSize.allCases {
            #expect(!size.title.isEmpty)
            if size == .system {
                #expect(size.dynamicTypeSizeClamp == nil)
            } else {
                #expect(size.dynamicTypeSizeClamp != nil,
                    "\(size.title) must clamp: an explicit choice that does nothing is a dead setting")
            }
        }
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
}
