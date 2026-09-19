import Foundation
import Testing

@testable import Heeler

/// The failed-Host retry policy: a Host that fails to *connect* goes
/// terminally Failed — no backoff loop, no re-dial — and comes back only
/// through an explicit Retry (row button, Host detail, or one attempt on a
/// foreground return, which #147 already pins elsewhere). A Host that
/// connected and then *dropped* keeps the automatic backoff reconnect.
@MainActor
@Suite("Host retry policy")
struct HostRetryPolicyTests {
    private static nonisolated let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    private func makeStore(
        connector: SequencedTransportConnector,
        reconnectPolicy: ReconnectPolicy = HostRetryPolicyTests.fastPolicy
    ) -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { try await connector.connect() },
                reconnectPolicy: reconnectPolicy,
                keepalive: .default)
        }
    }

    private static func oneAgentSession() -> SessionSnapshot {
        SessionSnapshot.fixture(
            agents: [.fixture(paneID: "w1:p1")],
            workspaces: [.fixture(workspaceID: "w1", label: "work")])
    }

    /// A Host that never connected fails terminally: no `.reconnecting`, no
    /// second dial — one attempt, then stopped.
    @Test func failToConnectIsTerminalNotABackoffLoop() async throws {
        let host = Host.fixture()
        let unreachable = ScriptedTransport(snapshot: Self.oneAgentSession())
        await unreachable.failPing(atCall: 1, with: .sshUnreachable(detail: "no route"))
        let connector = SequencedTransportConnector([unreachable])
        let store = makeStore(connector: connector)

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the unreachable Host should fail, not loop") {
            store.hostStatuses[host.id] == .failed(.sshUnreachable(detail: "no route"))
        }
        await settle()
        // No scheduling: the one dial the activation announced, and nothing more.
        #expect(await connector.connectCount == 1)
        #expect(store.hostStandingFailures[host.id] == .sshUnreachable(detail: "no route"))
        store.setHosts([])
    }

    /// Manual Retry dials exactly once: the failed Host connects on the
    /// follow-up dial and the standing failure clears with `.connected`.
    @Test func manualRetryDialsOnceAndSuccessClearsTheFailedState() async throws {
        let host = Host.fixture()
        let failure = TransportError.sshUnreachable(detail: "no route")
        let unreachable = ScriptedTransport(snapshot: Self.oneAgentSession())
        await unreachable.failPing(atCall: 1, with: failure)
        let reachable = ScriptedTransport(snapshot: Self.oneAgentSession())
        let connector = SequencedTransportConnector([unreachable, reachable])
        let store = makeStore(connector: connector)

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should fail its first dial") {
            store.hostStatuses[host.id] == .failed(failure)
        }

        await store.retryHost(host.id)
        try await waitUntil("the retry should connect") {
            store.hostStatuses[host.id] == .connected
        }
        #expect(store.hostStandingFailures[host.id] == nil)
        #expect(await connector.connectCount == 2)
        store.setHosts([])
    }

    /// A manual Retry against a Host that is still unreachable makes one
    /// dial and lands back on `.failed` — the press does not become a loop.
    @Test func manualRetryOfAStillUnreachableHostFailsAgainWithoutLooping() async throws {
        let host = Host.fixture()
        let failure = TransportError.sshUnreachable(detail: "no route")
        let first = ScriptedTransport(snapshot: Self.oneAgentSession())
        let second = ScriptedTransport(snapshot: Self.oneAgentSession())
        await first.failPing(atCall: 1, with: failure)
        await second.failPing(atCall: 1, with: failure)
        let connector = SequencedTransportConnector([first, second])
        let store = makeStore(connector: connector)

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should fail its first dial") {
            store.hostStatuses[host.id] == .failed(failure)
        }

        await store.retryHost(host.id)
        try await waitUntil("the retry should fail again") {
            store.hostStatuses[host.id] == .failed(failure)
        }
        await settle()
        #expect(await connector.connectCount == 2)
        store.setHosts([])
    }

    /// The drop case keeps its automatic recovery: a Host that connected
    /// and then lost the link still reconnects through backoff.
    @Test func aConnectedHostThatDropsKeepsItsAutomaticReconnect() async throws {
        let host = Host.fixture()
        let first = ScriptedTransport(snapshot: Self.oneAgentSession())
        let second = ScriptedTransport(snapshot: Self.oneAgentSession())
        let connector = SequencedTransportConnector([first, second])
        let store = makeStore(connector: connector)

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should come up connected") {
            store.hostStatuses[host.id] == .connected
        }
        try await waitUntilPaneResubscribeSettles(on: first)

        try await first.close()
        try await waitUntil("the dropped Host should be reconnecting, not failed") {
            if case .reconnecting = store.hostStatuses[host.id] { true } else { false }
        }
        try await waitUntil("and it should reconnect by itself") {
            store.hostStatuses[host.id] == .connected
        }
        #expect(await connector.connectCount == 2)
        store.setHosts([])
    }

    /// A Retry pressed while a *connected-then-dropped* Host is mid-backoff
    /// stays in the drop regime: if its dial still fails, the Host goes back
    /// to backoff reconnecting rather than being converted to terminal.
    @Test func aRetryDuringAnOutageKeepsTheDropHostOnBackoff() async throws {
        let host = Host.fixture()
        let alive = ScriptedTransport(snapshot: Self.oneAgentSession())
        let refusing = ScriptedTransport(snapshot: Self.oneAgentSession())
        for ordinal in 1...3 {
            await refusing.failPing(atCall: ordinal, with: .timedOut)
        }
        let connector = SequencedTransportConnector([alive, refusing])
        let store = makeStore(connector: connector)

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should come up connected") {
            store.hostStatuses[host.id] == .connected
        }
        try await waitUntilPaneResubscribeSettles(on: alive)

        try await alive.close()
        try await waitUntil("the dropped Host should be reconnecting") {
            if case .reconnecting = store.hostStatuses[host.id] { true } else { false }
        }
        await store.retryHost(host.id)
        try await waitUntil("the retry's failed dial should re-enter backoff") {
            if case .reconnecting = store.hostStatuses[host.id] { true } else { false }
        }
        store.setHosts([])
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
    }

    private func waitUntilPaneResubscribeSettles(
        on transport: ScriptedTransport
    ) async throws {
        try await waitUntil("the pane resubscribe should settle") {
            await transport.snapshotFetchCount >= 2
        }
    }

    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}
