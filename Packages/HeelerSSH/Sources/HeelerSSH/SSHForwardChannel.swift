import Foundation

/// A package-owned long-lived direct-tcpip channel to the authenticated
/// host's target endpoint.
///
/// Native pointers remain inside `SessionDriver`, exactly as
/// `SSHStreamLocalChannel` arranges: each read and write takes a short turn
/// on the driver's operation mutex, so an idle forward never monopolizes the
/// SSH session while chat RPCs, Events, PTY, and SFTP channels make
/// progress. The Jump-Host byte-transport `openDirectTCPIP` cannot serve a
/// shared forward: its pump sets the driver's hard `forwarding` mutual-
/// exclusion gate, refusing every other operation for the channel's whole
/// lifetime. This channel is the concurrent form instead — the direct-tcpip
/// OPEN path (`libssh2_channel_direct_tcpip_ex`, with the server's
/// connect-refused / administratively-prohibited classification) plus the
/// streamLocal short-turn IO registry.
///
/// sshd itself verifies the target: when the target port refuses the TCP
/// connection the channel OPEN fails with "connect failed", which surfaces
/// as `SSHError.targetUnreachable` rather than a channel that reads EOF.
public final class SSHForwardChannel: Sendable {
    private let id: UInt64
    private let driver: SessionDriver

    init(id: UInt64, driver: SessionDriver) {
        self.id = id
        self.driver = driver
    }

    public func write(_ data: Data, timeout: Duration) async throws {
        try await driver.writeForward(
            id: id,
            data: data,
            timeout: timeout)
    }

    /// Reads the next available bytes, or nil after orderly remote EOF
    /// (target closed the connection).
    public func read(
        maximumBytes: Int = 16 * 1024,
        timeout: Duration
    ) async throws -> Data? {
        try await driver.readForward(
            id: id,
            maximumBytes: maximumBytes,
            timeout: timeout)
    }

    /// Closes only this channel. Idempotent.
    public func close(timeout: Duration) async throws {
        try await driver.closeForward(id: id, timeout: timeout)
    }

    deinit {
        let id = id
        let driver = driver
        Task { try? await driver.closeForward(id: id, timeout: .seconds(2)) }
    }
}
