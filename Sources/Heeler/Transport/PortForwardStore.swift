import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The forward-lifecycle store (design: "One Forwarded ports panel per
// host/agent … Request IDs make repeated Start idempotent"). One store per
// host connection owns the live tunnels; Start is idempotent per
// PortForwardID (duplicate Start reuses the operation), Stop releases
// listener and channels, and SSH connection loss retires every forward.
//
// Idle expiry is the design's forward-grant expiry: default 30 minutes idle,
// user-visible extension. The clock is injectable so the unit pins are
// deterministic.

/// One forward's observable state.
struct PortForwardStatus: Equatable, Sendable {
    let request: PortForwardRequest
    let phase: PortForwardPhase
    let stopCause: PortForwardStopCause?
}

/// Protocol-clock seam: production uses ContinuousClock; tests drive a fake.
protocol PortForwardClock: Sendable {
    func now() -> ContinuousClock.Instant
}

struct ContinuousPortForwardClock: PortForwardClock {
    func now() -> ContinuousClock.Instant { ContinuousClock.now }
}

/// The per-host forward lifecycle owner.
actor PortForwardStore {
    /// Design default: 30 minutes idle, user-visible extension.
    static let defaultIdleExpiry: Duration = .seconds(30 * 60)

    private let transport: any PortForwardTransport
    private var tunnels: [PortForwardID: PortForwardTunnel] = [:]
    private var requests: [PortForwardID: PortForwardRequest] = [:]
    private var causes: [PortForwardID: PortForwardStopCause] = [:]
    /// In-flight Starts, the idempotency key: a duplicate Start joins the
    /// running operation instead of binding a second listener.
    private var startingTasks: [PortForwardID: Task<PortForwardTunnel, any Error>] = [:]
    private let idleExpiry: Duration
    private let clock: any PortForwardClock
    private var lastActivity: [PortForwardID: ContinuousClock.Instant] = [:]
    private var expiryTask: Task<Void, Never>?
    private var sweepIsRunning = false

    init(
        transport: any PortForwardTransport,
        idleExpiry: Duration = PortForwardStore.defaultIdleExpiry,
        clock: any PortForwardClock = ContinuousPortForwardClock()
    ) {
        self.transport = transport
        self.idleExpiry = idleExpiry
        self.clock = clock
    }

    /// Explicit Start. Idempotent: a duplicate Start with the same id joins
    /// the in-flight operation or reuses the running tunnel — one listener,
    /// one probe, one set of channels, regardless of how many times it is
    /// requested. A conflicting local port for an already-running forward is
    /// an explicit error, not a remap.
    func start(_ request: PortForwardRequest) async throws -> PortForwardStatus {
        let id = request.id
        try checkConflict(existing: tunnels[id]?.localPort, request: request)
        try checkConflict(existing: runningLocalPort(of: id), request: request)

        if let tunnel = tunnels[id] {
            touch(id)
            return status(of: id)
        }
        if let starting = startingTasks[id] {
            // Duplicate Start: join the same operation. Its result (success
            // or failure) is this Start's result — the idempotent contract.
            let tunnel = try await starting.value
            return statusAfterStart(tunnel: tunnel, id: id)
        }

        let task = Task { [transport] in
            try await PortForwardTunnel.start(
                request: request,
                transport: transport,
                channelTimeout: .seconds(10))
        }
        startingTasks[id] = task
        defer { startingTasks[id] = nil }
        do {
            let tunnel = try await task.value
            tunnels[id] = tunnel
            requests[id] = request
            causes[id] = nil
            touch(id)
            scheduleExpirySweep()
            return status(of: id)
        } catch {
            causes[id] = nil
            throw error
        }
    }

    /// Explicit Stop: releases the listener and every channel. Idempotent.
    @discardableResult
    func stop(_ id: PortForwardID) async -> PortForwardStatus {
        if let starting = startingTasks[id] {
            starting.cancel()
            _ = try? await starting.value
            startingTasks[id] = nil
        }
        tunnels[id]?.stop()
        tunnels[id] = nil
        causes[id] = .userStop
        return PortForwardStatus(
            request: requests[id] ?? PortForwardRequest(targetPort: id.targetPort),
            phase: .stopped,
            stopCause: .userStop)
    }

    /// The observable state of one forward. An unknown id reads as stopped,
    /// never as an error: surfaces poll, and a never-started forward is
    /// honestly "not running".
    func status(of id: PortForwardID) -> PortForwardStatus {
        PortForwardStatus(
            request: requests[id] ?? PortForwardRequest(targetPort: id.targetPort),
            phase: phase(of: id),
            stopCause: causes[id])
    }

    func statuses() -> [PortForwardStatus] {
        var ids = Set(tunnels.keys)
        ids.formUnion(requests.keys)
        return ids
            .sorted { $0.targetPort < $1.targetPort }
            .map { status(of: $0) }
    }

    /// SSH connection lost: every forward retires as stopped (cause:
    /// connection lost). Called by the reconnect path; never silently
    /// relabels an active forward as healthy.
    func connectionLost() async {
        for (id, tunnel) in tunnels {
            tunnel.stop()
            causes[id] = .sshConnectionLost
        }
        tunnels.removeAll()
    }

    /// Target exit surfaced by the tunnel: the forward's phase reports
    /// unreachable while the listener stays bound (the design shows target
    /// exit, never silently relabeled success).
    func targetExited(id: PortForwardID) {
        causes[id] = .targetExit
    }

    /// Extends the idle-expiry grant (the panel's user-visible extension).
    func extend(id: PortForwardID) {
        if tunnels[id] != nil { touch(id) }
    }

    // MARK: - Internals

    private func phase(of id: PortForwardID) -> PortForwardPhase {
        guard let tunnel = tunnels[id] else {
            if causes[id] == .idleExpiry { return .expired }
            return .stopped
        }
        if tunnel.isVerifiedActive {
            return .active(localPort: tunnel.localPort)
        }
        return .connecting(localPort: tunnel.localPort)
    }

    private func statusAfterStart(
        tunnel: PortForwardTunnel,
        id: PortForwardID
    ) -> PortForwardStatus {
        if tunnels[id] == nil {
            tunnels[id] = tunnel
            touch(id)
        }
        return status(of: id)
    }

    private func runningLocalPort(of id: PortForwardID) -> UInt16? {
        guard let task = startingTasks[id], !task.isCancelled else { return nil }
        return requests[id]?.localPort ?? id.targetPort
    }

    private func checkConflict(
        existing: UInt16?,
        request: PortForwardRequest
    ) throws {
        guard let existing else { return }
        let requested = request.localPort ?? request.targetPort
        guard requested == existing else {
            throw PortForwardError.conflictingLocalPort(
                existing: existing,
                requested: requested)
        }
    }

    private func touch(_ id: PortForwardID) {
        lastActivity[id] = clock.now()
    }

    /// One sweep task serves every forward; it re-arms while any tunnel lives.
    /// `sweepIsRunning` is the manual completion flag — `Task.isCompleted`
    /// does not exist on this toolchain — and the sweep clears it when no
    /// tunnel remains, so the next Start re-arms a fresh timer.
    private func scheduleExpirySweep() {
        guard !sweepIsRunning else { return }
        sweepIsRunning = true
        expiryTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: self.idleExpiry)
                await self.sweepExpired()
                if await self.tunnels.isEmpty {
                    await self.sweepDidFinish()
                    break
                }
            }
        }
    }

    private func sweepDidFinish() {
        sweepIsRunning = false
        expiryTask = nil
    }

    private func sweepExpired() {
        let now = clock.now()
        for (id, tunnel) in tunnels {
            guard let last = lastActivity[id] else { continue }
            if now.duration(to: last + idleExpiry) <= .zero {
                tunnel.stop()
                tunnels.removeValue(forKey: id)
                causes[id] = .idleExpiry
            }
        }
    }
}
