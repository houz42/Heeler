#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import Observation
    import Testing

    @testable import Heeler

    @MainActor
    @Suite("Demo screenshot mode", .timeLimit(.minutes(1)))
    struct DemoScreenshotModeTests {
        @Test func launchArgumentIsExactAndOptIn() {
            #expect(!DemoScreenshotMode.isEnabled(arguments: []))
            #expect(!DemoScreenshotMode.isEnabled(arguments: ["--demo-screenshot"]))
            #expect(
                DemoScreenshotMode.isEnabled(
                    arguments: ["Heeler", "--demo-screenshots"]))
        }

        @Test func fixtureIsStablePrivateAndCoversProductStates() {
            let hosts = DemoScreenshotFixture.hosts
            let profiles = DemoScreenshotFixture.profiles
            let agents = hosts.flatMap { profiles[$0.id]?.snapshot.agents ?? [] }

            #expect(hosts.map(\.displayName)
                == ["Studio Mac", "Build Server", "Offline Server"])
            #expect(
                hosts.map(\.id) == [
                    DemoScreenshotFixture.studioHostID,
                    DemoScreenshotFixture.buildHostID,
                    DemoScreenshotFixture.offlineHostID,
                ])
            #expect(Set(agents.map(\.agentStatus)) == [.blocked, .working, .done, .idle])
            #expect(
                Set(agents.compactMap(\.agent))
                    == ["claude", "codex", "gemini", "opencode"])
            #expect(agents.map(\.paneID).contains("checkout:p3"))
            #expect(hosts.allSatisfy { $0.address.hasSuffix(".demo.invalid") })
        }

        @Test func compositionLoadsTheProductionConsolePipeline() async throws {
            let composition = DemoScreenshotComposition.make()
            composition.console.setHosts(composition.hosts.hosts)
            await composition.console.resume()
            defer { composition.console.setHosts([]) }

            // The Offline Server never connects (no demo profile), so
            // its snapshot legitimately never arrives — wait on the
            // connectable Hosts only.
            while composition.console.agents.count != 5
                || composition.hosts.hosts.contains(where: { host in
                    host.id != DemoScreenshotFixture.offlineHostID
                        && composition.console.sidebarSnapshots.snapshot(for: host.id) == nil
                })
            {
                let changes = AsyncStream<Void>.makeStream()
                withObservationTracking {
                    _ = composition.console.agents
                    _ = composition.console.sidebarSnapshots.states
                } onChange: {
                    changes.continuation.yield(())
                }
                for await _ in changes.stream { break }
                changes.continuation.finish()
            }

            #expect(composition.console.agents.count == 5)
            #expect(composition.console.agents.first?.agent.status == .blocked)
            #expect(composition.console.agents.first?.hostName == "Build Server")
            // The Offline Server never connects by design; the rest
            // must all be connected.
            #expect(composition.console.hostStatuses
                .filter { key, _ in key != DemoScreenshotFixture.offlineHostID }
                .values.allSatisfy { $0 == .connected })
            #expect(composition.console.hostStatuses[DemoScreenshotFixture.offlineHostID] != .connected)

            for host in composition.hosts.hosts
            where host.id != DemoScreenshotFixture.offlineHostID {
                let bytes = try await composition.console.withNotificationTransport(for: host.id) {
                    try await $0.readSidebarLayout()
                }
                #expect(bytes == DemoScreenshotFixture.sidebarLayoutData)
                // Both Hosts follow the seeded global default, not their
                // plugin rows: resolution is host override > global > plugin.
                #expect(composition.console.rowLayout(for: host.id)
                    == DemoScreenshotFixture.globalLayout)
                #expect(composition.console.rowLayouts.globalLayout
                    == DemoScreenshotFixture.globalLayout)
            }
            let row = try #require(composition.console.agents.first)
            let card = AgentCardPresentation(agent: row, layout: composition.console.rowLayout(for: row.hostID))
            // Row 1 is the seeded global default: workspace + agent + tab.
            // Row 2 is the directory.
            #expect(card.additionalRows.first == row.displayCwd)
        }
    }
#endif
