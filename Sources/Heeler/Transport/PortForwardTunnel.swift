import Darwin
import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The transport wiring of one known-port forward: a LOOPBACK-ONLY TCP
// listener on the phone, and for each accepted connection one direct-tcpip
// channel to the authenticated host's loopback target port (the SSH library's
// `SSHForwardChannel`, same short-turn discipline as Events' streamLocal
// channel — chat/terminal/SFTP traffic keeps flowing while a forward lives).
//
// "Active" is verified here, not assumed: a Start binds the listener and then
// opens one probe channel through the same machinery every accepted
// connection uses. sshd refuses the channel OPEN when the target port is not
// listening ("connect failed" → PortForwardError.targetUnreachable), so a
// successful probe proves both the tunnel route and the live target.
//
// No PWA/Web Push/background-liveness: when iOS suspends the app the listener
// and channels die with the process; the store surfaces the loss as `.stopped`
// on the next Start/query, never as silent success.

/// One live forward: owns the loopback listener, the probe result, and every
/// accepted connection's channel pump.
final class PortForwardTunnel: @unchecked Sendable {
    private let lock = NSLock()
    private var listenerDescriptor: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    /// Live pump ids — one per accepted connection. Task values carry no
    /// identity on this toolchain, so pumps register a UUID instead.
    private var pumpIDs: Set<UUID> = []
    private let targetPort: UInt16
    let localPort: UInt16
    private let channelTimeout: Duration

    /// Bound at Start: false until the probe channel verifies the tunnel and
    /// target, then true. `PortForwardStore` reads it to decide `.active`.
    private var verifiedActive = false

    private init(
        targetPort: UInt16,
        localPort: UInt16,
        listenerDescriptor: Int32,
        channelTimeout: Duration
    ) {
        self.targetPort = targetPort
        self.localPort = localPort
        self.listenerDescriptor = listenerDescriptor
        self.channelTimeout = channelTimeout
    }

    var isVerifiedActive: Bool {
        lock.withLock { verifiedActive }
    }

    /// Live connection count, for channel-accounting assertions.
    var liveConnectionCount: Int {
        lock.withLock { pumpIDs.count }
    }

    /// Binds the LOOPBACK-ONLY listener and opens the verification probe.
    ///
    /// The listener binds 127.0.0.1 only — never all interfaces — per the
    /// design's security defaults. An occupied local port is an explicit
    /// `.localPortInUse` error, never a silent remap.
    static func start(
        request: PortForwardRequest,
        transport: any PortForwardTransport,
        channelTimeout: Duration
    ) async throws -> PortForwardTunnel {
        let requestedLocalPort = request.localPort ?? request.targetPort

        // Loopback-only bind. SO_REUSEADDR is deliberately NOT set: the
        // occupied-port case must surface, not race a dying listener.
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw PortForwardError.localPortInUse(port: requestedLocalPort)
        }
        var success = false
        defer {
            if !success { Darwin.close(descriptor) }
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(requestedLocalPort.bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw PortForwardError.localPortInUse(port: requestedLocalPort)
        }
        guard listen(descriptor, 16) == 0 else {
            throw PortForwardError.localPortInUse(port: requestedLocalPort)
        }

        // Report the actually-bound port.
        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &boundLength)
            }
        }
        var boundPort: UInt16 = requestedLocalPort
        withUnsafeBytes(of: boundAddress.sin_port) { raw in
            boundPort = UInt16(raw.load(as: UInt16.self).bigEndian)
        }

        let tunnel = PortForwardTunnel(
            targetPort: request.targetPort,
            localPort: boundPort,
            listenerDescriptor: descriptor,
            channelTimeout: channelTimeout)
        success = true

        // The verification probe: the same channel machinery every accepted
        // connection uses. A refused target fails the channel OPEN here, so
        // Start itself reports unreachable rather than reporting a listener
        // that cannot reach anything. The probe closes immediately after a
        // successful OPEN — the OPEN is the verification (sshd connects to
        // the target as part of establishing the direct-tcpip channel).
        do {
            let probe = try await transport.openForwardChannel(
                targetPort: request.targetPort,
                timeout: channelTimeout)
            try await probe.close(timeout: channelTimeout)
        } catch let error as PortForwardError {
            tunnel.stop()
            throw error
        } catch {
            tunnel.stop()
            throw PortForwardError.sshDisconnected
        }
        tunnel.lock.withLock { tunnel.verifiedActive = true }

        tunnel.acceptTask = Task { await tunnel.acceptLoop(transport: transport) }
        return tunnel
    }

    private func acceptLoop(transport: any PortForwardTransport) async {
        while true {
            var clientAddress = sockaddr_in()
            var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientDescriptor = withUnsafeMutablePointer(to: &clientAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    accept(listenerDescriptor, sockaddrPointer, &clientLength)
                }
            }
            guard clientDescriptor >= 0 else {
                // accept fails with EBADF once stop() closed the listener; any
                // other errno would loop hot, so the listener is dead either way.
                return
            }
            let pumpID = UUID()
            lock.withLock { pumpIDs.insert(pumpID) }
            Task { await pumpConnection(
                clientDescriptor: clientDescriptor,
                transport: transport,
                pumpID: pumpID) }
        }
    }

    /// Pumps one accepted connection: phone client ↔ host target, one
    /// direct-tcpip channel per connection.
    private func pumpConnection(
        clientDescriptor: Int32,
        transport: any PortForwardTransport,
        pumpID: UUID
    ) async {
        // The listener is up and verified, but this channel can still fail
        // (target exited since the probe, admission exhausted, connection
        // loss). Its connection is closed; the forward itself stays up —
        // per-connection failure is not forward failure.
        guard let channel = try? await transport.openForwardChannel(
            targetPort: targetPort,
            timeout: channelTimeout)
        else {
            Darwin.close(clientDescriptor)
            removePumpID(pumpID)
            return
        }

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await readLoop(channel: channel, to: clientDescriptor)
            }
            group.addTask { [self] in
                try await writeLoop(channel: channel, from: clientDescriptor)
            }
            // Whichever direction ends first wins; the sibling is cancelled.
            _ = try? await group.next()
            group.cancelAll()
        }
        try? await channel.close(timeout: .seconds(2))
        Darwin.close(clientDescriptor)
        removePumpID(pumpID)
    }

    private func readLoop(
        channel: any PortForwardChannel,
        to clientDescriptor: Int32
    ) async throws {
        while !Task.isCancelled {
            guard let chunk = try await channel.read(
                maximumBytes: 16 * 1024,
                timeout: .seconds(1))
            else { return }  // target closed the connection
            var offset = 0
            while offset < chunk.count {
                let written = chunk.withUnsafeBytes { raw in
                    Darwin.write(
                        clientDescriptor,
                        raw.baseAddress!.advanced(by: offset),
                        chunk.count - offset)
                }
                guard written > 0 else { return }  // phone client closed
                offset += written
            }
        }
    }

    private func writeLoop(
        channel: any PortForwardChannel,
        from clientDescriptor: Int32
    ) async throws {
        var scratch = [UInt8](repeating: 0, count: 16 * 1024)
        while !Task.isCancelled {
            let capacity = scratch.count
            let readCount = scratch.withUnsafeMutableBytes { raw in
                Darwin.read(clientDescriptor, raw.baseAddress, capacity)
            }
            guard readCount > 0 else { return }  // EOF: phone client closed
            let chunk = Data(scratch.prefix(readCount))
            try await channel.write(chunk, timeout: channelTimeout)
        }
    }

    private func removePumpID(_ pumpID: UUID) {
        lock.withLock { _ = pumpIDs.remove(pumpID) }
    }

    /// Explicit Stop / disconnect: releases the listener and every channel.
    /// Idempotent. The accept task dies on its next accept (EBADF) and every
    /// pump's channel read/write is cancellation-responsive, so this returns
    /// with at most a bounded teardown tail in flight.
    func stop() {
        lock.lock()
        let descriptor = listenerDescriptor
        listenerDescriptor = -1
        let task = acceptTask
        acceptTask = nil
        let pumps = pumpIDs
        pumpIDs = []
        verifiedActive = false
        lock.unlock()

        if descriptor >= 0 { Darwin.close(descriptor) }
        task?.cancel()
        // The pump tasks are unstructured; their channel close paths notice
        // cancellation, and each channel's deinit closes the native side.
        _ = pumps
    }

    deinit {
        // The hard resource: the listener socket. Channels close themselves
        // through their own deinit paths.
        if listenerDescriptor >= 0 { Darwin.close(listenerDescriptor) }
    }
}
