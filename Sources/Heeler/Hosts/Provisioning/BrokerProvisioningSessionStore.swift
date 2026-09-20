import Foundation
import Observation

/// Owns the one SSH connection the broker-provisioning sheet needs,
/// built from the exact Host mechanics onboarding uses: credential
/// resolution, the TOFU host-key confirmation, the preferred dial order,
/// and the same connector seam. The provisioning store is created only
/// once a Transport exists; the sheet closes the connection on
/// disappear.
@MainActor
@Observable
final class BrokerProvisioningSessionStore {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(message: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var pendingFingerprint: HostKeyCandidate?
    private(set) var provisioning: BrokerProvisioningStore?
    /// The address the connection succeeded on, for the status header.
    private(set) var workingAddress: String?

    let host: Host

    @ObservationIgnored private let connector: any TransportConnector
    @ObservationIgnored private let knownHosts: any KnownHostsStore
    @ObservationIgnored private let credentials: HostCredentialsProvider
    @ObservationIgnored private let preferredAddresses: PreferredAddressStore
    @ObservationIgnored private let fingerprintTimeout: Duration
    @ObservationIgnored private var fingerprintDecision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var fingerprintTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var transport: (any Transport)?
    @ObservationIgnored private let layoutBuilder: @Sendable (RemoteHostPlatform, String) -> BrokerProvisioningLayout

    init(
        host: Host,
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        preferredAddresses: PreferredAddressStore,
        fingerprintTimeout: Duration = .seconds(60),
        layoutBuilder: @escaping @Sendable (RemoteHostPlatform, String) -> BrokerProvisioningLayout
            = BrokerProvisioningLayout.standard
    ) {
        self.host = host
        self.connector = connector
        self.knownHosts = knownHosts
        self.credentials = credentials
        self.preferredAddresses = preferredAddresses
        self.fingerprintTimeout = fingerprintTimeout
        self.layoutBuilder = layoutBuilder
    }

    /// Connects using the preferred dial order (the same semantics as
    /// onboarding's full connect: one address list, TOFU prompt surfaced,
    /// failures rendered as a message). On success, exposes the
    /// provisioning store and immediately inspects.
    func connect() async {
        guard phase != .connecting, phase != .connected else { return }
        phase = .connecting
        do {
            let resolved = try credentials.credentials(for: host)
            let policy = HostKeyPolicy(knownHosts: knownHosts) { [weak self] candidate in
                await self?.awaitFingerprintDecision(for: candidate) ?? false
            }
            var settings = SSHTransportSettings(
                host: host, credentials: resolved, hostKeyPolicy: policy)
            // The connector dials candidates itself; hand it the preferred
            // order rather than re-implementing the sweep.
            settings.candidateAddresses = preferredAddresses.preferredOrder(
                for: host.candidateAddresses)
            let opened = try await connector.connect(settings: settings) { [weak self] result in
                Task { @MainActor in
                    self?.workingAddress = result.address
                }
            }
            transport = opened
            let store = BrokerProvisioningStore(
                transport: opened, layoutBuilder: layoutBuilder)
            provisioning = store
            phase = .connected
            await store.inspect()
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(message: String(describing: error))
        }
    }

    /// The user's verdict on the pending fingerprint (same ceremony as
    /// onboarding: unanswered means declined).
    func confirmFingerprint(trusted: Bool) {
        guard let decision = fingerprintDecision else { return }
        fingerprintDecision = nil
        fingerprintTimeoutTask?.cancel()
        fingerprintTimeoutTask = nil
        pendingFingerprint = nil
        decision.resume(returning: trusted)
    }

    /// Closes the sheet's connection. Provisioning is one-shot per sheet
    /// presentation, matching preflight's connect-probe-close pattern.
    func close() async {
        if let transport {
            try? await transport.close()
        }
        transport = nil
        provisioning = nil
        phase = .idle
    }

    private func awaitFingerprintDecision(for candidate: HostKeyCandidate) async -> Bool {
        guard fingerprintDecision == nil else { return false }
        pendingFingerprint = candidate
        return await withCheckedContinuation { continuation in
            fingerprintDecision = continuation
            fingerprintTimeoutTask = Task { [fingerprintTimeout] in
                try? await Task.sleep(for: fingerprintTimeout)
                guard !Task.isCancelled else { return }
                self.confirmFingerprint(trusted: false)
            }
        }
    }
}
