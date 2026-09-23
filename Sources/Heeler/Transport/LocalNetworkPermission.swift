import Darwin
import Dispatch
import Foundation
import Network
import os

/// The iOS 14+ Local Network permission (WWDC 20, "Support local network
/// privacy in your app"): connections to private addresses — the LAN and
/// VPN paths every herdr Host dials — are blocked without the user's grant,
/// and a denied app's connections fail with no prompt at all. iOS asks once,
/// the first time the app touches the local network; the
/// `NSLocalNetworkUsageDescription` declared in project.yml is the prompt's
/// body.
///
/// The permission is process-global, not per-Host: one probe answers for
/// every dial. `isGranted()` is that probe — a one-datagram UDP broadcast,
/// the well-known trigger. The raw SSH dial cannot distinguish denial from
/// an unreachable Host (both are a failed connect); the probe can, because
/// a denied app's broadcast fails with POSIX EACCES.
enum LocalNetworkPermission {
    /// The last probe's answer. Only grants are cached: a denial is
    /// re-probed on the next demand, so a user back from Settings with the
    /// permission newly granted recovers without relaunching the app.
    private static let state = OSAllocatedUnfairLock(initialState: false)

    /// Whether the Local Network permission is granted. Cheap after a
    /// definitive grant (the answer is cached); probes otherwise. Never
    /// blocks indefinitely — an inconclusive probe reads as granted so
    /// the dial behind it surfaces the real failure, and the next connect
    /// re-probes.
    static func isGranted() async -> Bool {
        if state.withLock({ $0 }) { return true }

        switch await probe() {
        case .some(true):
            state.withLock { $0 = true }
            return true
        case .some(false):
            return false
        case nil:
            // Inconclusive: let the dial behind the probe speak.
            return true
        }
    }

    /// Whether connecting to `address` needs the Local Network permission.
    ///
    /// Private (`10/8`, `172.16/12`, `192.168/16`), CGNAT (`100.64/10`),
    /// and link-local (`169.254/16`) IPv4; ULA (`fc00::/7`), link-local
    /// (`fe80::/10`), and private-IPv4-mapped IPv6; and every hostname (a
    /// `.local` name always resolves onto the local network, any other name
    /// may) do. Loopback — the E2E fixtures' sshd and reverse-tunnel Jump
    /// Host ports — and global addresses do not: iOS never gates them.
    static func isRequired(for address: String) -> Bool {
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return isPrivateIPv4(ipv4)
        }
        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return isPrivateIPv6(ipv6)
        }
        return true
    }

    // MARK: Address classification

    private static func isPrivateIPv4(_ address: in_addr) -> Bool {
        // s_addr holds the address in network byte order; reinterpret the
        // big-endian value so the shift reads octets left to right.
        let value = UInt32(bigEndian: address.s_addr)
        let first = value >> 24
        let second = (value >> 16) & 0xFF
        return switch first {
        case 127:
            // Loopback is this device, not the local network.
            false
        case 10:
            true
        case 172:
            // 172.16.0.0 – 172.31.255.255.
            second & 0xF0 == 0x10
        case 192:
            second == 168
        case 169:
            second == 254
        case 100:
            // 100.64.0.0 – 100.127.255.255 (CGNAT): not a global address.
            second & 0xC0 == 0x40
        default:
            false
        }
    }

    private static func isPrivateIPv6(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        // ::1 — loopback, exempt like 127.0.0.1.
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
            return false
        }
        // ULA fc00::/7 (fc and fd prefixes).
        if bytes[0] & 0xFE == 0xFC { return true }
        // Link-local fe80::/10.
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }
        // IPv4-mapped ::ffff:a.b.c.d: the embedded IPv4 decides.
        if bytes[0...9].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            var embedded = in_addr()
            _ = withUnsafeMutableBytes(of: &embedded) { destination in
                destination.copyBytes(from: bytes[12...15])
            }
            return isPrivateIPv4(embedded)
        }
        return false
    }

    // MARK: Probe

    /// One empty datagram to the broadcast address, bounded to ``probeBudget``.
    ///
    /// - Returns `true` when the send went out: the permission is granted
    ///   (a denied app's broadcast fails with POSIX EACCES).
    /// - Returns `false` only on that permission refusal — the one outcome
    ///   the raw SSH dial cannot distinguish from an unreachable Host.
    /// - Returns `nil` on expiry: the prompt may be up, unanswered; the
    ///   dial behind the probe surfaces whatever is actually wrong.
    private static func probe() async -> Bool? {
        let connection = NWConnection(
            to: .hostPort(host: "255.255.255.255", port: 9),
            using: .udp)
        return await withCheckedContinuation { continuation in
            let finish = ProbeFinish(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: Data([0]),
                        completion: .contentProcessed { error in
                            finish.resume(with: !isPermissionError(error))
                        })
                case .failed(let error):
                    finish.resume(with: !isPermissionError(error))
                case .waiting(let error):
                    if isPermissionError(error) {
                        finish.resume(with: false)
                    }
                case .setup, .preparing, .cancelled:
                    break
                @unknown default:
                    break
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + probeBudget) {
                finish.resume(with: nil)
            }
            connection.start(queue: DispatchQueue.global())
        }
    }

    /// The probe budget. Long enough that a granted permission reports
    /// definitively and a denied one fails fast; short enough that a
    /// connect is never held hostage to an unanswered prompt — the dial
    /// behind the probe has its own budget and the next connect re-probes.
    private static let probeBudget: DispatchTimeInterval = .seconds(10)

    private static func isPermissionError(_ error: NWError?) -> Bool {
        guard case .posix(let code)? = error else { return false }
        return code == .EACCES || code == .EPERM
    }
}

/// Resumes the probe continuation exactly once and always tears the
/// NWConnection down, whichever of the state handler, send completion, or
/// timeout reports first.
private final class ProbeFinish: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private let continuation: CheckedContinuation<Bool?, Never>
    private let connection: NWConnection

    init(continuation: CheckedContinuation<Bool?, Never>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func resume(with answer: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = answer ?? true
        connection.cancel()
        continuation.resume(returning: result)
    }
}
