import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Heeler
@testable import HeelerSSH

/// The REAL-TUNNEL delivery gate for the v3 known-port forward. Everything
/// here crosses a real sshd on this machine's loopback: the phone's loopback
/// listener is the `PortForwardTunnel`'s own 127.0.0.1 bind (the simulator
/// shares the Mac's loopback with the sshd, which is exactly the
/// "authenticated host's loopback" the design mandates), and the remote
/// service is a real HTTP + WebSocket server the test starts on the same
/// loopback.
///
/// Proof matrix (the delivery gate):
///   1. A real remote loopback HTTP service reached through the phone's
///      loopback listener (real request/response bytes, not a scaffold).
///   2. WebSocket traffic through the same forward.
///   3. Duplicate Start (idempotent: one listener, one probe, reused).
///   4. Occupied local port (explicit error, no remap).
///   5. Refused remote target (channel OPEN refused → targetUnreachable).
///   6. SSH loss (forward retires; transport reports it; restart refuses).
///   7. Explicit Stop (listener released; port bindable again).
///   8. Concurrent chat/terminal traffic keeps flowing and accounting.
@Suite(
    "Port forward e2e (real tunnel)",
    .enabled(
        if: RealSSHFixture.gate(
            HeelerSSHTransportBehaviorEnvironment.current != nil
                || LocalSSHTestEnvironment.current != nil),
        "requires a real sshd (disposable CI fixture or local spike seed)"),
    .serialized,
    .timeLimit(.minutes(3)))
struct PortForwardE2ETests {
    // MARK: - Real remote loopback service (HTTP + WebSocket)

    /// A minimal real HTTP + WebSocket echo server. All handlers are static:
    /// only descriptors and value types cross isolation, so Swift 6 strict
    /// concurrency is satisfied by construction, not by suppression.
    private enum LoopbackHTTPWSServer {
        static func start() throws -> (listener: Int32, port: UInt16) {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw SocketError.setup }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0  // ephemeral
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0, listen(descriptor, 8) == 0 else {
                Darwin.close(descriptor)
                throw SocketError.setup
            }
            var bound = sockaddr_in()
            var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    getsockname(descriptor, sockaddrPointer, &boundLength)
                }
            }
            var port: UInt16 = 0
            withUnsafeBytes(of: bound.sin_port) { raw in
                port = UInt16(raw.load(as: UInt16.self).bigEndian)
            }
            return (descriptor, port)
        }

        /// Serves exactly `connectionCount` connections then returns, so the
        /// test controls the lifecycle deterministically.
        static func serve(
            listener: Int32,
            connectionCount: Int,
            stop: PortForwardE2EStopFlag
        ) async {
            var served = 0
            while served < connectionCount, !stop.isSet {
                var clientAddress = sockaddr_in()
                var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &clientAddress) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        accept(listener, sockaddrPointer, &clientLength)
                    }
                }
                guard client >= 0 else { return }
                served += 1
                await handle(client)
            }
        }

        private static func handle(_ client: Int32) async {
            defer { Darwin.close(client) }
            var buffer = [UInt8]()
            let capacity = 4096
            var scratch = [UInt8](repeating: 0, count: capacity)
            while !buffer.contains(where: { $0 == 0x0A }) {
                let readCount = scratch.withUnsafeMutableBytes { raw in
                    Darwin.read(client, raw.baseAddress, capacity)
                }
                guard readCount > 0 else { return }
                buffer.append(contentsOf: scratch.prefix(readCount))
            }
            let text = String(decoding: buffer, as: UTF8.self)

            if text.lowercased().contains("upgrade: websocket") {
                try? await serveWebSocket(client: client, request: text)
            } else {
                let body = "meadow-forward:ok\n"
                let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                response.withCString { pointer in
                    _ = Darwin.write(
                        client,
                        UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                        response.utf8.count)
                }
            }
        }

        private static func serveWebSocket(client: Int32, request: String) async throws {
            guard let keyLine = request
                .split(separator: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") })
            else { return }
            let key = keyLine.split(separator: ":", maxSplits: 1)[1]
                .trimmingCharacters(in: .whitespaces)
            let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            let accept = Data(Insecure.SHA1.hash(data: Data(magic.utf8)))
                .base64EncodedString()
            let handshake = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            try handshake.withCString { pointer in
                let written = Darwin.write(
                    client,
                    UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                    handshake.utf8.count)
                guard written == handshake.utf8.count else { throw SocketError.write }
            }
            while true {
                guard let (opcode, payload) = try await readFrame(client: client) else { return }
                if opcode == 0x8 {  // close
                    try? await writeFrame(client: client, opcode: 0x8, payload: Data())
                    return
                }
                try await writeFrame(client: client, opcode: opcode, payload: payload)
            }
        }

        static func readFrame(client: Int32) async throws -> (UInt8, Data)? {
            var header = [UInt8](repeating: 0, count: 2)
            guard try await readFully(client, into: &header) else { return nil }
            let opcode = header[0] & 0x0F
            let masked = (header[1] & 0x80) != 0
            var length = Int(header[1] & 0x7F)
            var mask = [UInt8](repeating: 0, count: 4)
            if length == 126 {
                var extended = [UInt8](repeating: 0, count: 2)
                guard try await readFully(client, into: &extended) else { return nil }
                length = Int(extended[0]) << 8 | Int(extended[1])
            }
            if masked {
                guard try await readFully(client, into: &mask) else { return nil }
            }
            var payload = [UInt8](repeating: 0, count: length)
            guard try await readFully(client, into: &payload) else { return nil }
            if masked {
                for index in payload.indices {
                    payload[index] ^= mask[index % 4]
                }
            }
            return (opcode, Data(payload))
        }

        static func writeFrame(client: Int32, opcode: UInt8, payload: Data) async throws {
            var frame = [UInt8]()
            frame.append(0x80 | opcode)
            if payload.count < 126 {
                frame.append(UInt8(payload.count))
            } else {
                frame.append(126)
                frame.append(UInt8(payload.count >> 8))
                frame.append(UInt8(payload.count & 0xFF))
            }
            frame.append(contentsOf: payload)
            try frame.withUnsafeBufferPointer { buffer in
                let written = Darwin.write(client, buffer.baseAddress, frame.count)
                guard written == frame.count else { throw SocketError.write }
            }
        }

        static func readFully(_ client: Int32, into buffer: inout [UInt8]) async throws -> Bool {
            var offset = 0
            while offset < buffer.count {
                let count = buffer.count - offset
                let readCount = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(client, raw.baseAddress! + offset, count)
                }
                guard readCount > 0 else { return false }
                offset += readCount
            }
            return true
        }

        enum SocketError: Error {
            case setup
            case write
        }
    }


    final class PortForwardE2EStopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isSet: Bool { lock.withLock { stopped } }
        func set() { lock.withLock { stopped = true } }
    }

    /// The environment the tests actually run against: whichever fixture is
    /// live (disposable CI config first, then the local sshd + spike seed).
    private struct LiveEnvironment {
        let settings: SSHTransportSettings

        static func current() throws -> LiveEnvironment {
            if let behavior = HeelerSSHTransportBehaviorEnvironment.current {
                return LiveEnvironment(settings: behavior.directSettings())
            }
            guard let local = LocalSSHTestEnvironment.current else {
                throw PortForwardE2EUnavailable.fixtureMissing
            }
            // The real herdr socket on the fixture host: chat RPCs (ping)
            // in this suite must hit a real one-request-per-connection
            // herdr API, exactly like production. The disposable CI fixture
            // carries its own fake-herdr socket; the local developer path
            // resolves the Mac home the same way LocalSSHTestEnvironment
            // does (the simulator's own HOME is its container, but the
            // user name sits in the container path).
            let components = URL(fileURLWithPath: NSHomeDirectory()).pathComponents
            guard components.count >= 3, components[1] == "Users" else {
                throw PortForwardE2EUnavailable.fixtureMissing
            }
            let hostHome = ("/Users/" + components[2] ) as NSString
            let herdrSocket = hostHome.appendingPathComponent(".config/herdr/herdr.sock")
            var settings = SSHTransportSettings(
                host: "127.0.0.1",
                port: local.port,
                username: local.username,
                credentials: .ed25519(local.privateKey),
                hostKeyPolicy: HostKeyPolicy(
                    knownHosts: InMemoryKnownHostsStore()) { _ in true },
                socket: .absolutePath(herdrSocket))
            settings.requestTimeout = .seconds(10)
            return LiveEnvironment(settings: settings)
        }
    }

    enum PortForwardE2EUnavailable: Error {
        case fixtureMissing
    }

    // MARK: - Helpers

    /// A raw loopback TCP client in the test process — the phone's
    /// user-space side of the forward (real bytes, no stack in between).
    private static func connectLocal(port: UInt16) throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LoopbackHTTPWSServer.SocketError.setup
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port.bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw LoopbackHTTPWSServer.SocketError.setup
        }
        return descriptor
    }

    /// One HTTP request/response through a connected socket.
    private static func exchangeHTTP(client: Int32) throws -> String {
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        let sent = request.withCString { pointer in
            Darwin.write(
                client,
                UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                request.utf8.count)
        }
        #expect(sent == request.utf8.count)
        var received = [UInt8]()
        let capacity = 4096
        var scratch = [UInt8](repeating: 0, count: capacity)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !received.contains(0x0A), ContinuousClock.now < deadline {
            let readCount = scratch.withUnsafeMutableBytes { raw in
                Darwin.read(client, raw.baseAddress, capacity)
            }
            guard readCount > 0 else { break }
            received.append(contentsOf: scratch.prefix(readCount))
        }
        return String(decoding: received, as: UTF8.self)
    }

    // MARK: - The delivery gate

    @Test("real remote loopback HTTP service through the phone's listener")
    func realHTTPThroughTheForward() async throws {
        let environment = try LiveEnvironment.current()
        let (listener, remotePort) = try LoopbackHTTPWSServer.start()
        defer { Darwin.close(listener) }
        let stop = PortForwardE2EStopFlag()
        let serverTask = Task {
            await LoopbackHTTPWSServer.serve(
                listener: listener,
                connectionCount: 2,  // probe + HTTP request
                stop: stop)
        }
        defer {
            stop.set()
            _ = serverTask
        }

        let transport = try await HeelerSSHTransport.connect(
            settings: environment.settings)
        defer { try? await transport.close() }
        let store = PortForwardStore(transport: transport)

        let status = try await store.start(PortForwardRequest(targetPort: remotePort, localPort: 5391))
        guard case .active(let localPort) = status.phase else {
            Issue.record("expected active, got \(status.phase)")
            return
        }
        // The listener bound the exact requested local port (the harness
        // pins one distinct from the co-located remote service; production
        // defaults to the target port).
        #expect(localPort == 5391)

        let client = try Self.connectLocal(port: localPort)
        defer { Darwin.close(client) }
        let body = try Self.exchangeHTTP(client: client)
        #expect(body.contains("HTTP/1.1 200 OK"))
        #expect(body.contains("meadow-forward:ok"))

        await store.stop(status.request.id)
    }

    @Test("WebSocket traffic flows through the forward")
    func webSocketThroughTheForward() async throws {
        let environment = try LiveEnvironment.current()
        let (listener, remotePort) = try LoopbackHTTPWSServer.start()
        defer { Darwin.close(listener) }
        let stop = PortForwardE2EStopFlag()
        let serverTask = Task {
            await LoopbackHTTPWSServer.serve(
                listener: listener,
                connectionCount: 2,  // probe + WS connection
                stop: stop)
        }
        defer {
            stop.set()
            _ = serverTask
        }

        let transport = try await HeelerSSHTransport.connect(
            settings: environment.settings)
        defer { try? await transport.close() }
        let store = PortForwardStore(transport: transport)
        let status = try await store.start(PortForwardRequest(targetPort: remotePort, localPort: 5392))
        guard case .active(let localPort) = status.phase else {
            Issue.record("expected active, got \(status.phase)")
            return
        }

        // A real RFC 6455 client (URLSession WebSocketTask) through the
        // forward's loopback listener.
        let url = URL(string: "ws://127.0.0.1:\(localPort)/")!
        let wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask.resume()
        defer { wsTask.cancel(with: .normalClosure, reason: nil) }

        try await wsTask.send(.string("forward-hello"))
        let reply = try await wsTask.receive()
        guard case .string(let echoed) = reply else {
            Issue.record("expected string echo, got \(reply)")
            return
        }
        #expect(echoed == "forward-hello")

        // A second exchange proves the connection stays live.
        try await wsTask.send(.string("second-frame"))
        let second = try await wsTask.receive()
        guard case .string(let echoedSecond) = second else {
            Issue.record("expected second echo, got \(second)")
            return
        }
        #expect(echoedSecond == "second-frame")

        await store.stop(status.request.id)
    }

    @Test("duplicate Start reuses the live tunnel against real sshd")
    func duplicateStartAgainstRealSSHD() async throws {
        let environment = try LiveEnvironment.current()
        let (listener, remotePort) = try LoopbackHTTPWSServer.start()
        defer { Darwin.close(listener) }
        let stop = PortForwardE2EStopFlag()
        let serverTask = Task {
            await LoopbackHTTPWSServer.serve(
                listener: listener,
                connectionCount: 2,  // probe + HTTP request
                stop: stop)
        }
        defer {
            stop.set()
            _ = serverTask
        }

        let transport = try await HeelerSSHTransport.connect(
            settings: environment.settings)
        defer { try? await transport.close() }
        let store = PortForwardStore(transport: transport)
        let request = PortForwardRequest(targetPort: remotePort, localPort: 5393)

        let first = try await store.start(request)
        let second = try await store.start(request)
        guard case .active = first.phase, case .active = second.phase else {
            Issue.record("expected both active, got \(first.phase), \(second.phase)")
            return
        }
        // One tunnel — the duplicate reused it.
        #expect((await store.statuses()).count == 1)

        // Traffic still flows after the duplicate Start.
        let client = try Self.connectLocal(port: request.localPort ?? request.targetPort)
        defer { Darwin.close(client) }
        let body = try Self.exchangeHTTP(client: client)
        #expect(body.contains("200 OK"))

        await store.stop(request.id)
    }

    @Test("occupied local port is an explicit failure against real sshd")
    func occupiedLocalPortAgainstRealSSHD() async throws {
        let environment = try LiveEnvironment.current()
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.settings)
        defer { try? await transport.close() }
        let store = PortForwardStore(transport: transport)

        // A real second listener on the port the Start will want.
        var squatter = sockaddr_in()
        squatter.sin_family = sa_family_t(AF_INET)
        squatter.sin_port = in_port_t(UInt16(5322).bigEndian)
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

        await #expect(throws: PortForwardError.localPortInUse(port: 5322)) {
            _ = try await store.start(PortForwardRequest(targetPort: 5322))
        }
        #expect((await store.statuses()).isEmpty)
    }

    @Test("refused remote target fails Start as targetUnreachable")
    func refusedRemoteTarget() async throws {
        let environment = try LiveEnvironment.current()
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.settings)
        defer { try? await transport.close() }
        let store = PortForwardStore(transport: transport)

        // A port with nothing listening on the host's loopback. Verify the
        // precondition FIRST so the assertion cannot pass on a busy port.
        var probeAddress = sockaddr_in()
        probeAddress.sin_family = sa_family_t(AF_INET)
        probeAddress.sin_port = in_port_t(UInt16(49527).bigEndian)
        probeAddress.sin_addr.s_addr = inet_addr("127.0.0.1")
        let probeSocket = socket(AF_INET, SOCK_STREAM, 0)
        let probeResult = withUnsafePointer(to: &probeAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probeSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(probeResult != 0)  // nothing is listening there
        Darwin.close(probeSocket)

        await #expect(throws: PortForwardError.targetUnreachable) {
            _ = try await store.start(PortForwardRequest(targetPort: 49527, localPort: 5398))
        }
        #expect((await store.statuses()).isEmpty)
        // The refused channel left the session intact: chat still works.
        _ = try await transport.ping()
    }

    @Test("SSH loss retires the forward and honest transport state")
    func sshLossRetiresForward() async throws {
        let environment = try LiveEnvironment.current()
        let transport = try await HeelerSSHTransport.connect(
            settings: environment.settings)
        let store = PortForwardStore(transport: transport)

        // Start against a target that exists so the tunnel is genuinely up.
        let (listener, remotePort) = try LoopbackHTTPWSServer.start()
        defer { Darwin.close(listener) }
        let stop = PortForwardE2EStopFlag()
        let serverTask = Task {
            await LoopbackHTTPWSServer.serve(
                listener: listener,
                connectionCount: 1,  // probe only
                stop: stop)
        }
        defer {
            stop.set()
            _ = serverTask
        }
        let request = PortForwardRequest(targetPort: remotePort, localPort: 5395)
        _ = try await store.start(request)

        // Sever the SSH connection (the real loss path).
        try await transport.close()

        // The store surfaces loss honestly when told (the reconnect path).
        await store.connectionLost()
        let status = await store.status(of: request.id)
        #expect(status.phase == .stopped)
        #expect(status.stopCause == .sshConnectionLost)

        // The transport reports itself disconnected: no silent success.
        #expect(await transport.isConnected == false)
        // A post-loss Start refuses rather than pretending.
        await #expect(throws: PortForwardError.sshDisconnected) {
            _ = try await store.start(request)
        }
    }

    @Test("explicit Stop releases the listener for the next Start")
    func explicitStopReleasesListener() async throws {
        let environment = try LiveEnvironment.current()
        let (listener, remotePort) = try LoopbackHTTPWSServer.start()
        defer { Darwin.close(listener) }
        let stop = PortForwardE2EStopFlag()
        // Two server rounds: probe for each of the two Starts.
        let serverTask = Task {
            await LoopbackHTTPWSServer.serve(
                listener: listener,
                connectionCount: 2,
                stop: stop)
        }
        defer {
            stop.set()
            _ = serverTask
        }

        let transport = try await HeelerSSHTransport.connect(
            settings: environment.settings)
        defer { try? await transport.close() }
        let store = PortForwardStore(transport: transport)
        let request = PortForwardRequest(targetPort: remotePort, localPort: 5396)

        _ = try await store.start(request)
        let stopped = await store.stop(request.id)
        #expect(stopped.phase == .stopped)
        #expect(stopped.stopCause == .userStop)

        // The local port is bindable again — the listener was truly
        // released, not just relabeled.
        let rebound = try await store.start(request)
        guard case .active = rebound.phase else {
            Issue.record("expected rebound active, got \(rebound.phase)")
            return
        }
        await store.stop(request.id)
    }

    @Test("concurrent chat and forward traffic keep the connection healthy")
    func concurrentChatAndForwardTraffic() async throws {
        let environment = try LiveEnvironment.current()
        let (listener, remotePort) = try LoopbackHTTPWSServer.start()
        defer { Darwin.close(listener) }
        let stop = PortForwardE2EStopFlag()
        let serverTask = Task {
            await LoopbackHTTPWSServer.serve(
                listener: listener,
                connectionCount: 2,  // probe + HTTP request
                stop: stop)
        }
        defer {
            stop.set()
            _ = serverTask
        }

        let transport = try await HeelerSSHTransport.connect(
            settings: environment.settings)
        defer { try? await transport.close() }
        let store = PortForwardStore(transport: transport)
        let request = PortForwardRequest(targetPort: remotePort, localPort: 5397)
        _ = try await store.start(request)

        // Concurrent chat RPCs (each one ordinarySession channel) over the
        // SAME connection while the forward is live.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<10 {
                    _ = try await transport.ping()
                }
            }
            group.addTask {
                let client = try Self.connectLocal(port: request.localPort ?? request.targetPort)
                defer { Darwin.close(client) }
                let body = try Self.exchangeHTTP(client: client)
                #expect(body.contains("200 OK"))
            }
            try await group.waitForAll()
        }

        // The forward is still healthy after concurrent chat traffic, and a
        // full ping burst still works afterwards: channel accounting stayed
        // correct through it all.
        let status = await store.status(of: request.id)
        #expect(status.phase.isActive)
        await store.stop(request.id)
        for _ in 0..<8 {
            _ = try await transport.ping()
        }
    }
}
