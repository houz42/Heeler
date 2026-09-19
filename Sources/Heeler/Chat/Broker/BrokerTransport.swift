import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The broker pipe over the app's one SSH backend: direct-streamlocal to
// the Host's configured broker socket (ADR 0011 discipline — same
// channel class as herdr's forwarding, a long-lived channel per chat
// connection). Alternative transports without stream-local forwarding
// report no broker support, exactly like remote directories.

/// What one Host connection can do with the broker socket.
enum BrokerPipeAvailability: Sendable, Equatable {
    /// The transport can open direct-streamlocal channels; the path is
    /// the Host's configured broker socket.
    case available(socketPath: String)
    /// No broker path configured on this Host.
    case notConfigured
}

/// A factory for broker pipes, so the store can open/reopen its channel
/// across Host reconnects. Production wraps the Host's live transport.
struct BrokerPipeFactory: Sendable {
    let open: @Sendable (_ socketPath: String) async throws -> any BrokerBytePipe
    let hostRecord: @MainActor () -> Host?
    let transportGeneration: @MainActor () -> UInt64?

    /// The resolved availability from the current Host record.
    @MainActor
    func availability() -> BrokerPipeAvailability {
        guard let host = hostRecord(), host.hasBrokerChat else { return .notConfigured }
        return .available(
            socketPath: host.brokerChatSocketPath.trimmingCharacters(in: .whitespaces))
    }

    /// Production: over a ConsoleStore's live Host connection. The
    /// transport must be `HeelerSSHTransport` (checked like every other
    /// stream-local feature); the socket path comes from the Host.
    @MainActor
    static func console(
        _ console: ConsoleStore, hostID: Host.ID
    ) -> BrokerPipeFactory {
        BrokerPipeFactory(
            open: { socketPath in
                try await console.withNotificationTransport(for: hostID) { transport in
                    guard let ssh = transport as? HeelerSSHTransport else {
                        throw TransportError.sshUnreachable(
                            detail: "This Host cannot reach chat brokers.")
                    }
                    return try await ssh.openBrokerChannel(socketPath: socketPath)
                }
            },
            hostRecord: { console.host(for: hostID) },
            transportGeneration: { console.hostConnectionGenerations[hostID] })
    }
}
