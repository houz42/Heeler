import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Header layout settings")
struct HeaderLayoutSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-header-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private let headerHost = HeaderLayoutSettingsStore.customLayoutHostID

    @Test func unsetDefaultsToSameAsListAndConsoleDefault() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HeaderLayoutSettingsStore(defaults: defaults)
        #expect(store.mode == .sameAsList)
        #expect(store.customLayout == .consoleDefault)
        #expect(store.loadError == nil)
        #expect(defaults.string(forKey: "header-layout-mode") == nil)
    }

    @Test func modeAndCustomLayoutRoundTrip() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HeaderLayoutSettingsStore(defaults: defaults)
        let layout = AgentRowLayout(rows: [
            [.init(.agent, bold: true), .init(.workspace, dim: true)],
            [.init(.host)],
        ])
        try store.setCustomLayout(layout)
        store.setMode(.custom)

        let reloaded = HeaderLayoutSettingsStore(defaults: defaults)
        #expect(reloaded.mode == .custom)
        #expect(reloaded.customLayout == layout)
        #expect(reloaded.loadError == nil)
    }

    @Test func headerLayoutFollowsTheMode() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HeaderLayoutSettingsStore(defaults: defaults)
        let hostID = UUID()
        let listLayout = AgentRowLayout(rows: [[.init(.workspace)]])
        let custom = AgentRowLayout(rows: [[.init(.session)]])
        try store.setCustomLayout(custom)

        #expect(store.headerLayout(sameAsList: { _ in listLayout }, for: hostID) == listLayout)
        store.setMode(.custom)
        #expect(store.headerLayout(sameAsList: { _ in listLayout }, for: hostID) == custom)
        store.setMode(.sameAsList)
        #expect(store.headerLayout(sameAsList: { _ in listLayout }, for: hostID) == listLayout)
    }

    /// A saved preference from a build that knew more field names than this
    /// one must not be discarded: unknown names drop individually on load
    /// and by the next write, same discipline as the agent-list catalog
    /// (#320). Raw bytes are seeded under the nested catalog's own key.
    @Test func unknownTokensDropOnLoadAndByTheNextWrite() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let captured = ##"{"hostLayouts":["00000000-0000-0000-0000-000000000002",{"rows":[[{"token":"agent"},{"token":"machine"},{"token":"future"}],[{"token":"tab","fg":"nothex"}]],"row_gap":0,"rows_by_agent":{"claude":[[{"token":"pane"}]]}}],"version":1}"##
        defaults.set(Data(captured.utf8), forKey: "agent-row-layouts")
        defaults.set("custom", forKey: "header-layout-mode")
        let store = HeaderLayoutSettingsStore(defaults: defaults)
        #expect(store.loadError == nil)
        #expect(store.mode == .custom)
        let expected = AgentRowLayout(rows: [
            [.init(.agent)],
            [.init(.tab)],
        ], rowsByAgent: ["claude": [[.init(.pane)]]])
        #expect(store.layouts.hostLayouts == [headerHost: expected])

        // The next write drops the unknown names.
        try store.setCustomLayout(AgentRowLayout(rows: [[.init(.host)]]))
        let written = try #require(defaults.data(forKey: "agent-row-layouts"))
        #expect(String(decoding: written, as: UTF8.self).contains("machine") == false)
        #expect(HeaderLayoutSettingsStore(defaults: defaults).customLayout
            == AgentRowLayout(rows: [[.init(.host)]]))
    }

    @Test func unreadableBytesRefuseWritesAndRetainData() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        for json in ["not json", #"{"version":2,"hostLayouts":[]}"#] {
            defaults.set(Data(json.utf8), forKey: "agent-row-layouts")
            let store = HeaderLayoutSettingsStore(defaults: defaults)
            #expect(store.loadError == .catalogUnreadable)
            #expect(store.mode == .sameAsList)
            #expect(throws: AgentRowLayoutStoreError.catalogUnreadable) {
                try store.setCustomLayout(AgentRowLayout(rows: [[.init(.agent)]]))
            }
            #expect(defaults.data(forKey: "agent-row-layouts") == Data(json.utf8))
        }
    }

    @Test func invalidLayoutsRefuseToSaveAndChangeNothing() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HeaderLayoutSettingsStore(defaults: defaults)
        try store.setCustomLayout(AgentRowLayout(rows: [[.init(.agent)]]))
        let before = defaults.data(forKey: "agent-row-layouts")
        #expect(throws: AgentRowLayoutError.tooManyRows) {
            try store.setCustomLayout(AgentRowLayout(rows: Array(repeating: [], count: 4)))
        }
        #expect(store.customLayout == AgentRowLayout(rows: [[.init(.agent)]]))
        #expect(defaults.data(forKey: "agent-row-layouts") == before)
    }

    @Test func resetDiscardsOnlyAnUnreadablePreference() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let good = HeaderLayoutSettingsStore(defaults: defaults)
        try good.setCustomLayout(AgentRowLayout(rows: [[.init(.host)]]))
        good.setMode(.custom)
        good.resetUnreadable()
        #expect(good.mode == .custom)
        #expect(good.customLayout == AgentRowLayout(rows: [[.init(.host)]]))
        #expect(defaults.data(forKey: "agent-row-layouts") != nil)

        defaults.set(Data("not json".utf8), forKey: "agent-row-layouts")
        let store = HeaderLayoutSettingsStore(defaults: defaults)
        #expect(store.loadError == .catalogUnreadable)
        store.resetUnreadable()
        #expect(store.loadError == nil)
        #expect(store.mode == .sameAsList && store.customLayout == .consoleDefault)
        #expect(defaults.data(forKey: "agent-row-layouts") == nil)
        #expect(defaults.string(forKey: "header-layout-mode") == nil)
        store.setMode(.custom)
        #expect(HeaderLayoutSettingsStore(defaults: defaults).mode == .custom)
    }
}
