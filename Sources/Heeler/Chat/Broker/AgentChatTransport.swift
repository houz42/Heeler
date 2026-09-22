import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The agent-chat broker pipe over the app's one SSH backend:
// direct-streamlocal to the Host's configured chat socket (same
// discipline as every other stream-local feature).

/// What one Host connection can do with the chat socket.
enum AgentChatPipeAvailability: Sendable, Equatable {
    case available(socketPath: String)
    case notConfigured
}

/// A factory for broker pipes, so the store can open/reopen its channel
/// across Host reconnects. Production wraps the Host's live transport.
struct AgentChatPipeFactory: Sendable {
    let open: @Sendable (_ socketPath: String) async throws -> any AgentChatBytePipe
    let hostRecord: @MainActor () -> Host?

    @MainActor
    func availability() -> AgentChatPipeAvailability {
        guard let host = hostRecord(), host.hasBrokerChat else { return .notConfigured }
        return .available(
            socketPath: host.brokerChatSocketPath.trimmingCharacters(in: .whitespaces))
    }

    /// Production: over a ConsoleStore's live Host connection. The
    /// transport must be `HeelerSSHTransport`, checked like every other
    /// stream-local feature.
    @MainActor
    static func console(
        _ console: ConsoleStore, hostID: Host.ID
    ) -> AgentChatPipeFactory {
        AgentChatPipeFactory(
            open: { socketPath in
                try await console.withNotificationTransport(for: hostID) { transport in
                    guard let ssh = transport as? HeelerSSHTransport else {
                        throw TransportError.sshUnreachable(
                            detail: "This Host cannot reach chat brokers.")
                    }
                    return try await ssh.openBrokerChannel(socketPath: socketPath)
                }
            },
            hostRecord: { console.host(for: hostID) })
    }
}
