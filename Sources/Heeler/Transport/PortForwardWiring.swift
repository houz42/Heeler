import Foundation
import HeelerSSH

// SPDX-License-Identifier: Apache-2.0
//
// The concrete wiring of the v3 known-port forward seam (PortForward.swift)
// onto the libssh2 Transport. The Transport method itself lives on
// HeelerSSHTransport (it needs the actor's private `connected` and
// `channelAdmission`); this file carries the package-channel conformance,
// the admission-held channel wrapper, and the error taxonomy mapping.

extension SSHForwardChannel: PortForwardChannel {}

extension HeelerSSHTransport: PortForwardTransport {}

/// One forward channel plus the `.ordinaryForwarding` admission lease it
/// holds for its whole lifetime (the same Events/broker discipline). Closing
/// or dropping the wrapper releases the lease exactly once.
final class AdmissionHeldForwardChannel: PortForwardChannel, @unchecked Sendable {
    private let lock = NSLock()
    private let channel: SSHForwardChannel
    private let lease: SSHChannelAdmissionLease
    private var released = false

    init(channel: SSHForwardChannel, lease: SSHChannelAdmissionLease) {
        self.channel = channel
        self.lease = lease
    }

    func write(_ data: Data, timeout: Duration) async throws {
        try await channel.write(data, timeout: timeout)
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        try await channel.read(maximumBytes: maximumBytes, timeout: timeout)
    }

    func close(timeout: Duration) async throws {
        do {
            try await channel.close(timeout: timeout)
        } catch {
            releaseLease()
            throw error
        }
        releaseLease()
    }

    deinit {
        releaseLease()
    }

    private func releaseLease() {
        lock.lock()
        let shouldRelease = !released
        released = true
        lock.unlock()
        if shouldRelease {
            Task { await lease.release() }
        }
    }
}

extension PortForwardError {
    /// Maps the SSH library's taxonomy onto the forward's delivery-gate
    /// cases. Target refusals and policy denials are per-channel verdicts
    /// that leave the session usable; everything else is a transport failure.
    static func map(_ error: any Error) -> PortForwardError {
        if let error = error as? PortForwardError { return error }
        guard let error = error as? SSHError else {
            return .sshDisconnected
        }
        switch error {
        case .targetUnreachable:
            return .targetUnreachable
        case .forwardingDenied:
            return .forwardingDenied
        default:
            return .sshDisconnected
        }
    }
}
