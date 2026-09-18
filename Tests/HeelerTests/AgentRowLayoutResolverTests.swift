import Testing

@testable import Heeler

@Suite("Agent row layout resolver")
struct AgentRowLayoutResolverTests {
    @Test func initializationImportsTwoPluginRowsAndDefaultsThirdToDirectory() {
        let first: AgentRow = [.init(.workspace, bold: true), .init(.custom("branch"))]
        let second: AgentRow = [.init(.terminalTitle, dim: true)]
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(
            rows: [[.init(.stateIcon)] + first, second, [.init(.tab)]], rowGap: 2))
        let initial = AgentRowLayoutResolver.resolve(
            hostLayout: nil, globalLayout: nil, pluginSnapshot: plugin)
        #expect(initial.rows == [first, second, [.init(.directory)]])
        #expect(initial.rowGap == 2)

        // An explicitly emptied third row stays empty after initialization.
        let saved = AgentRowLayout(rows: [first, second, []])
        #expect(AgentRowLayoutResolver.resolve(
            hostLayout: saved, globalLayout: nil, pluginSnapshot: plugin) == saved)
        #expect(AgentRowLayoutResolver.resolve(
            hostLayout: nil, globalLayout: nil, pluginSnapshot: nil).rows
            == [[.init(.workspace), .init(.tab)], [.init(.agent)], [.init(.directory)]])
    }

    @Test func savedLayoutsTakePrecedenceOverGlobalPluginRowsAndBuiltinDefault() {
        let host = AgentRowLayout(rows: [[.init(.pane)]], rowGap: 3)
        let global = AgentRowLayout(rows: [[.init(.host)]], rowGap: 4)
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(
            rows: [[.init(.workspace)]], rowGap: 1,
            rowsByAgent: ["claude": [[.init(.custom("pin_icon"))]]]), agentPanelSort: .priority)
        // Host override wins over global, plugin, and the built-in default.
        #expect(AgentRowLayoutResolver.resolve(
            hostLayout: host, globalLayout: global, pluginSnapshot: plugin) == host)
        let resolvedPlugin = AgentRowLayoutResolver.resolve(
            hostLayout: nil, globalLayout: nil, pluginSnapshot: plugin)
        #expect(resolvedPlugin == plugin.layout.withHeelerRow())
        #expect(resolvedPlugin.rows == [[.init(.workspace)], [], [.init(.directory)]] && resolvedPlugin.rowGap == 1)
        #expect(resolvedPlugin.rowsByAgent.isEmpty)
        // The global default wins over plugin rows and the built-in default.
        #expect(AgentRowLayoutResolver.resolve(
            hostLayout: nil, globalLayout: global, pluginSnapshot: plugin) == global)
        #expect(AgentRowLayoutResolver.resolve(
            hostLayout: nil, globalLayout: global, pluginSnapshot: nil) == global)
        #expect(AgentRowLayoutResolver.resolve(
            hostLayout: nil, globalLayout: nil, pluginSnapshot: nil) == .consoleDefault)
        // An empty override is still a whole-layout choice, not inheritance.
        #expect(AgentRowLayoutResolver.resolve(
            hostLayout: AgentRowLayout(rows: []), globalLayout: global,
            pluginSnapshot: plugin).rows.isEmpty)
        #expect(AgentRowLayoutResolver.resolve(
            hostLayout: nil, globalLayout: AgentRowLayout(rows: []),
            pluginSnapshot: plugin).rows.isEmpty)
    }
}
