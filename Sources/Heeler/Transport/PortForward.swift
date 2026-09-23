import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The v3 known-port native SSH forwarding slice (design doc: "V3 link UX and
// native SSH forwarding" / forwarding-scope amendment). One explicitly
// requested forward: the phone binds a LOOPBACK-ONLY listener and forwards it
// over the already-authenticated SSH connection's direct-tcpip channels to the
// SAME host's loopback target port. No listener discovery, no automatic port
// exposure, no PWA/Web Push, and no background-liveness promise (iOS
// suspension applies). This file owns the value types; PortForwardTunnel owns
// the transport wiring; PortForwardStore owns the lifecycle.

/// Stable identity of one forward operation. Repeated Start requests carry the
/// same id, which is what makes Start idempotent: the same tuple reuses the
/// running operation rather than opening a second listener.
struct PortForwardID: Hashable, Sendable, CustomStringConvertible {
    /// The host's loopback target port. The forward's whole identity: one
    /// requested known-port forward per host connection.
    let targetPort: UInt16

    var description: String { "forward(\(targetPort))" }
}

/// The explicit Start request. `targetPort` is the authenticated host's
/// loopback port (known port, named by the user — never inferred from chat
/// text). `localPort` is the phone-side listener port; `nil` binds the same
/// number, and the caller is told the actual bound port through the state.
struct PortForwardRequest: Equatable, Sendable {
    let targetPort: UInt16
    /// Phone-side listener port; `nil` means "same as the target port".
    /// OAuth callbacks may require the exact original port, so a conflict is
    /// reported (`.localPortInUse`) rather than silently remapped.
    let localPort: UInt16?

    init(targetPort: UInt16, localPort: UInt16? = nil) {
        self.targetPort = targetPort
        self.localPort = localPort
    }

    var id: PortForwardID { PortForwardID(targetPort: targetPort) }
}

/// The forward lifecycle. "Active" is the VERIFIED state: a probe channel
/// reached the target through the tunnel machinery and the server accepted the
/// direct-tcpip OPEN to the target port. Accepted setup alone is never active.
enum PortForwardPhase: Equatable, Sendable {
    /// Start accepted; the listener is not yet bound.
    case requested
    /// Listener bound (or probe in flight); target verification pending.
    case connecting(localPort: UInt16)
    /// Probe verified the tunnel AND the target; traffic flows.
    case active(localPort: UInt16)
    /// The target refused the probe connection (or died while active). The
    /// listener may still be bound; explicit Stop or a later Start retries.
    case unreachable(localPort: UInt16, reason: String)
    /// Explicit Stop or connection loss; listener released, channels closed.
    case stopped
    /// Idle expiry. The design's forward-grant expiry: initial default 30
    /// minutes idle, user-visible restart. Listener released.
    case expired
}

/// How a forward ended, for surfaces that show history.
enum PortForwardStopCause: Equatable, Sendable {
    case userStop
    case sshConnectionLost
    case idleExpiry
    case targetExit
}

/// The delivery-gate error taxonomy. Every failure a Start can hit is one of
/// these, so the UI can present an honest cause instead of a generic failure.
enum PortForwardError: Error, Equatable, Sendable {
    /// Another listener already owns the requested local port.
    case localPortInUse(port: UInt16)
    /// sshd (or an authorized_keys restriction) denied the forward.
    case forwardingDenied
    /// The channel opened but the host's target port refused the connection.
    case targetUnreachable
    /// The SSH session is gone (closed or invalidated) — Start while
    /// disconnected.
    case sshDisconnected
    /// The transport cannot open forward channels at all (wrong kind).
    case unsupportedTransport
    /// The forward already exists and cannot accept a conflicting local port.
    case conflictingLocalPort(existing: UInt16, requested: UInt16)
}

/// What the app layer needs from a channel: the write/read/close surface the
/// tunnel pumps drive. `SSHForwardChannel` conforms in the transport wiring;
/// tests substitute a fake.
protocol PortForwardChannel: Sendable {
    func write(_ data: Data, timeout: Duration) async throws
    func read(maximumBytes: Int, timeout: Duration) async throws -> Data?
    func close(timeout: Duration) async throws
}

/// The transport seam for forwarding: the one method a Transport must expose
/// beyond its existing RPC surface. Kept out of the main `Transport` protocol
/// so this slice stays independent of the in-flight chat/terminal work; the
/// concrete `HeelerSSHTransport` conforms in PortForwardWiring.swift.
protocol PortForwardTransport: Sendable {
    /// Opens one direct-tcpip channel from the authenticated host to
    /// `targetPort` on the host's loopback. Throws `PortForwardError` cases.
    func openForwardChannel(
        targetPort: UInt16,
        timeout: Duration
    ) async throws -> any PortForwardChannel
}

extension PortForwardPhase {
    /// The listener port while one is bound, for surfaces that show the
    /// local endpoint regardless of verification state.
    var boundLocalPort: UInt16? {
        switch self {
        case .connecting(let localPort), .active(localPort: let localPort),
            .unreachable(let localPort, _):
            return localPort
        case .requested, .stopped, .expired:
            return nil
        }
    }

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}
