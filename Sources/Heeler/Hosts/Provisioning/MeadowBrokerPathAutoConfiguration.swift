import Foundation
import Observation

/// Connection-time broker path auto-configuration (the consolidation
/// reality): the heeler plugin owns the broker on every Host and runs it
/// at the ONE standard path — `${XDG_DATA_HOME:-$HOME/.local/share}/
/// meadow/broker.sock`. So when a Host connects WITHOUT a
/// `brokerChatSocketPath` on record, the app resolves the standard path
/// host-side, probes it with a REAL broker hello (the consolidation's
/// startup hook means an up broker proves itself on the wire), and
/// writes the record — zero manual edit.
///
/// If the probe does NOT answer, nothing is written and the first-connect
/// flow (setup confirm + ask-before-restart) takes over.
@MainActor
@Observable
final class MeadowBrokerPathAutoConfiguration {
    private(set) var isRunning = false
    /// True once a probe resolved + wrote the path this session (the
    /// guard against re-probing every surface entry).
    private var configuredHostIDs: Set<Host.ID> = []
    let console: ConsoleStore
    /// The durable catalog the resolved path is written to.
    let catalog: HostStore

    init(console: ConsoleStore, catalog: HostStore) {
        self.console = console
        self.catalog = catalog
    }

    /// The one-shot per-Host auto-configure, safe to call from any
    /// chat-gate: hosts already carrying a path, or already probed
    /// this session, are no-ops.
    func autoConfigure(hostID: Host.ID) async {
        guard !isRunning else { return }
        guard !configuredHostIDs.contains(hostID) else { return }
        guard let host = catalog.hosts.first(where: { $0.id == hostID }),
            !host.hasBrokerChat
        else { return }
        isRunning = true
        defer { isRunning = false }

        do {
            guard let resolved = try await resolveStandardPath(on: hostID)
            else { return }
            guard try await probeAnswers(socketPath: resolved, on: hostID)
            else { return }
            var updated = host
            updated.brokerChatSocketPath = resolved
            try catalog.update(updated)
            configuredHostIDs.insert(hostID)
        } catch {
            // A failed probe/resolution leaves the record untouched;
            // the first-connect flow surfaces the honest setup offer.
        }
    }

    /// Resolves the standard path ON THE HOST (XDG_DATA_HOME honored).
    func resolveStandardPath(on hostID: Host.ID) async throws -> String? {
        let result = try await console.withNotificationTransport(for: hostID) { transport in
            try await transport.runProvisioningCommand(
                "printf '%s' \"${XDG_DATA_HOME:-$HOME/.local/share}/meadow/broker.sock\"")
        }
        let path = result.trimmedText
        guard path.hasPrefix("/"), path.hasSuffix("broker.sock") else {
            return nil
        }
        return path
    }

    /// A REAL broker hello at the resolved path: same discipline as the
    /// chat lane (direct-streamlocal, HeelerSSHTransport only).
    func probeAnswers(socketPath: String, on hostID: Host.ID) async throws -> Bool {
        try await console.withNotificationTransport(for: hostID) { transport in
            guard let ssh = transport as? HeelerSSHTransport else {
                return false
            }
            _ = try await ssh.openBrokerChannel(socketPath: socketPath)
            return true
        }
    }
}
