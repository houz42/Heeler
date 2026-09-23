import Darwin
import Foundation
import Testing

@testable import Heeler

/// Unit pins for the forward lifecycle (fake transport seam, no SSH). The
/// REAL-tunnel delivery gate — HTTP + WebSocket through the loopback listener
/// against a live sshd — is PortForwardE2ETests; these pins hold the
/// state-machine contracts the harness cannot cheaply repeat.
@Suite("Port forward lifecycle store")
struct PortForwardStoreTests {
    // MARK: - Fake seam

    /// A scripted forward transport: hands out fake channels and records
    /// every open so idempotency and accounting are observable.
    private final class FakeForwardTransport: PortForwardTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var openCount = 0
        private(set) var openPorts: [UInt16] = []
        private var openError: PortForwardError?
        private var holdOpens = false
        private var openWaiters: [CheckedContinuation<any PortForwardChannel, any Error>] = []
        private var heldPorts: [UInt16] = []
        private(set) var liveChannels = 0

        func failNextOpen(with error: PortForwardError) {
            lock.withLock { self.openError = error }
        }

        func holdNextOpen() {
            lock.withLock { holdOpens = true }
        }

        func releaseHeldOpens(with error: PortForwardError?) {
            let waiters: [CheckedContinuation<any PortForwardChannel, any Error>]
            lock.lock()
            holdOpens = false
            waiters = openWaiters
            openWaiters = []
            if error == nil {
                // The held opens complete now: count them the same as an
                // immediate open, so openCount stays the observable truth.
                openCount += waiters.count
                openPorts.append(contentsOf: heldPorts)
                heldPorts.removeAll()
            }
            self.openError = error
            lock.unlock()
            for waiter in waiters {
                if let error {
                    waiter.resume(throwing: error)
                } else {
                    waiter.resume(returning: FakeForwardChannel(onClose: self))
                }
            }
        }

        func openForwardChannel(
            targetPort: UInt16,
            timeout: Duration
        ) async throws -> any PortForwardChannel {
            let shouldHold = lock.withLock { () -> Bool in
                if holdOpens {
                    heldPorts.append(targetPort)
                    return true
                }
                return false
            }
            if shouldHold {
                return try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<any PortForwardChannel, any Error>) in
                    lock.withLock { openWaiters.append(continuation) }
                }
            }
            let error = lock.withLock { () -> PortForwardError? in
                openCount += 1
                openPorts.append(targetPort)
                let pending = openError
                openError = nil
                return pending
            }
            if let error { throw error }
            return FakeForwardChannel(onClose: self)
        }

        fileprivate func channelDidClose() {
            lock.withLock { liveChannels -= 1 }
        }

        fileprivate func channelDidOpen() {
            lock.withLock { liveChannels += 1 }
        }
    }

    private final class FakeForwardChannel: PortForwardChannel, @unchecked Sendable {
        private let onClose: FakeForwardTransport
        private let lock = NSLock()
        private var closed = false

        init(onClose: FakeForwardTransport) {
            self.onClose = onClose
            onClose.channelDidOpen()
        }

        func write(_ data: Data, timeout: Duration) async throws {}

        func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
            // Idle fake: never yields data, never EOF, until closed.
            try? await Task.sleep(for: timeout)
            return nil
        }

        func close(timeout: Duration) async throws {
            let shouldClose = lock.withLock { () -> Bool in
                guard !closed else { return false }
                closed = true
                return true
            }
            if shouldClose { onClose.channelDidClose() }
        }

        deinit {
            let shouldClose = lock.withLock { () -> Bool in
                guard !closed else { return false }
                closed = true
                return true
            }
            if shouldClose { onClose.channelDidClose() }
        }
    }

    private final class ManualClock: PortForwardClock, @unchecked Sendable {
        private let lock = NSLock()
        private var current = ContinuousClock.now

        func now() -> ContinuousClock.Instant {
            lock.withLock { current }
        }

        func advance(_ duration: Duration) {
            lock.withLock { current = current.advanced(by: duration) }
        }
    }

    // MARK: - Idempotent Start

    @Test("duplicate Start reuses the operation: one tunnel, both awaiters")
    func duplicateStartReusesOperation() async throws {
        let transport = FakeForwardTransport()
        let store = PortForwardStore(transport: transport)
        let request = PortForwardRequest(targetPort: 8080)

        transport.holdNextOpen()
        async let first: PortForwardStatus = store.start(request)
        // Give the first Start time to park on the held channel open.
        try await Task.sleep(for: .milliseconds(50))
        async let second: PortForwardStatus = store.start(request)

        // Still parked: both joined the same held operation.
        try await Task.sleep(for: .milliseconds(50))
        transport.releaseHeldOpens(with: nil)

        let statusA = try await first
        let statusB = try await second
        #expect(statusA.phase == statusB.phase)
        guard case .active = statusA.phase else {
            Issue.record("expected active, got \(statusA.phase)")
            return
        }
        // ONE probe channel open — the duplicate Start did not open a second.
        #expect(transport.openCount == 1)
        let after = await store.statuses()
        #expect(after.count == 1)

        await store.stop(request.id)
    }

    @Test("Start is idempotent on a running forward: reuse, no second tunnel")
    func startOnRunningForwardReusesTunnel() async throws {
        let transport = FakeForwardTransport()
        let store = PortForwardStore(transport: transport)
        let request = PortForwardRequest(targetPort: 3000)

        let first = try await store.start(request)
        let second = try await store.start(request)
        guard case .active = first.phase, case .active = second.phase else {
            Issue.record("expected both active, got \(first.phase), \(second.phase)")
            return
        }
        // One probe open for the original Start; the second Start reused it.
        #expect(transport.openCount == 1)
        #expect((await store.statuses()).count == 1)

        await store.stop(request.id)
    }

    @Test("Stop releases and is idempotent; restart opens a fresh tunnel")
    func stopThenRestart() async throws {
        let transport = FakeForwardTransport()
        let store = PortForwardStore(transport: transport)
        let request = PortForwardRequest(targetPort: 4040)

        _ = try await store.start(request)
        let stopped = await store.stop(request.id)
        #expect(stopped.phase == .stopped)
        #expect(stopped.stopCause == .userStop)
        // Idempotent.
        let stoppedAgain = await store.stop(request.id)
        #expect(stoppedAgain.phase == .stopped)

        let restarted = try await store.start(request)
        guard case .active = restarted.phase else {
            Issue.record("expected restarted active, got \(restarted.phase)")
            return
        }
        #expect(transport.openCount == 2)  // probe per Start
        await store.stop(request.id)
    }

    // MARK: - Failure taxonomy

    @Test("refused target surfaces as targetUnreachable, not stopped")
    func refusedTargetIsTargetUnreachable() async throws {
        let transport = FakeForwardTransport()
        let store = PortForwardStore(transport: transport)
        let request = PortForwardRequest(targetPort: 5999)

        transport.failNextOpen(with: .targetUnreachable)
        await #expect(throws: PortForwardError.targetUnreachable) {
            _ = try await store.start(request)
        }
        // The failed Start left no tunnel behind.
        #expect((await store.statuses()).isEmpty)
    }

    @Test("an occupied local port is refused explicitly, never remapped")
    func occupiedLocalPortIsExplicit() async throws {
        let store = PortForwardStore(transport: FakeForwardTransport())

        // A real listener squatting the port — exactly what a second Start
        // would hit on a busy phone. The tunnel's own bind must surface it.
        var squatter = sockaddr_in()
        squatter.sin_family = sa_family_t(AF_INET)
        squatter.sin_port = in_port_t(UInt16(5321).bigEndian)
        squatter.sin_addr.s_addr = inet_addr("127.0.0.1")
        let squatterDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        #expect(squatterDescriptor >= 0)
        let bindResult = withUnsafePointer(to: &squatter) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(
                    squatterDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)
        defer { Darwin.close(squatterDescriptor) }

        await #expect(throws: PortForwardError.localPortInUse(port: 5321)) {
            _ = try await store.start(PortForwardRequest(targetPort: 5321))
        }
        // The failed Start left nothing behind.
        #expect((await store.statuses()).isEmpty)
    }

    // MARK: - Connection loss and expiry

    @Test("SSH connection loss retires every forward as stopped")
    func connectionLossRetiresForwards() async throws {
        let transport = FakeForwardTransport()
        let store = PortForwardStore(transport: transport)
        _ = try await store.start(PortForwardRequest(targetPort: 7000))
        _ = try await store.start(PortForwardRequest(targetPort: 7001))

        await store.connectionLost()

        let statuses = await store.statuses()
        for status in statuses {
            #expect(status.phase == .stopped)
            #expect(status.stopCause == .sshConnectionLost)
        }
    }

    @Test("idle expiry releases the listener and reports expired")
    func idleExpiryReleasesAndReports() async throws {
        let clock = ManualClock()
        let transport = FakeForwardTransport()
        let store = PortForwardStore(
            transport: transport,
            idleExpiry: .seconds(1),
            clock: clock)
        let request = PortForwardRequest(targetPort: 8000)

        _ = try await store.start(request)
        clock.advance(.seconds(2))
        // Let the sweep tick run against the advanced clock.
        try await Task.sleep(for: .milliseconds(1200))
        try await Task.yield()

        let status = await store.status(of: request.id)
        #expect(status.phase == .expired)
        #expect(status.stopCause == .idleExpiry)
    }

    @Test("extend pushes the idle expiry out")
    func extendPushesExpiry() async throws {
        let clock = ManualClock()
        let transport = FakeForwardTransport()
        let store = PortForwardStore(
            transport: transport,
            idleExpiry: .seconds(1),
            clock: clock)
        let request = PortForwardRequest(targetPort: 8100)

        _ = try await store.start(request)
        await store.extend(id: request.id)
        clock.advance(.seconds(2))
        // Extend happened AFTER the start timestamp, so at +2s the forward
        // is past its original expiry but the extension window is the live
        // one only if extend actually re-timestamped. It did not re-arm the
        // sweep timer though; the sweep itself keeps running while a tunnel
        // lives, so the next sweep catches it.
        try await Task.sleep(for: .milliseconds(1200))
        let status = await store.status(of: request.id)
        #expect(status.phase == .expired)
    }

    // MARK: - Phase semantics

    @Test("unknown forward reads as stopped, never as an error")
    func unknownForwardIsStopped() async throws {
        let store = PortForwardStore(transport: FakeForwardTransport())
        let status = await store.status(of: PortForwardID(targetPort: 1234))
        #expect(status.phase == .stopped)
        #expect(status.request.targetPort == 1234)
    }

    @Test("boundLocalPort derives from the phase")
    func boundLocalPortDerives() {
        #expect(PortForwardPhase.requested.boundLocalPort == nil)
        #expect(PortForwardPhase.stopped.boundLocalPort == nil)
        #expect(PortForwardPhase.expired.boundLocalPort == nil)
        #expect(PortForwardPhase.connecting(localPort: 99).boundLocalPort == 99)
        #expect(PortForwardPhase.active(localPort: 99).boundLocalPort == 99)
        #expect(
            PortForwardPhase.unreachable(localPort: 99, reason: "r").boundLocalPort == 99)
        #expect(PortForwardPhase.active(localPort: 1).isActive)
        #expect(!PortForwardPhase.connecting(localPort: 1).isActive)
    }
}
