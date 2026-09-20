import Observation
import SwiftUI

/// The state of ONE route's check, driven by an explicit user press —
/// never on open (handoff §E: alternate routes are not switched or tested
/// automatically). Before the first check the route honestly reports
/// "unknown this session".
enum RouteCheckState: Equatable, Sendable {
    /// No check has run since the inspector opened.
    case unchecked
    /// The user's check is in flight.
    case checking
    /// The address answered an SSH handshake.
    case reachable
    /// The address did not answer within the probe budget.
    case unreachable
}

/// Backs the per-route inspector sheet (handoff §E): exact address:port
/// and user for the tapped route, host-key trust for its endpoint, and an
/// explicit on-demand reachability check. The in-use/alternate derivation
/// lives in the presentation struct below, not here — this store only
/// owns facts the sheet can change.
@MainActor
@Observable
final class HostRouteInspectorStore {
    private(set) var checkState: RouteCheckState = .unchecked
    private(set) var trustedFingerprint: HostKeyFingerprint?
    @ObservationIgnored private let connector: any TransportConnector
    @ObservationIgnored private let knownHosts: any KnownHostsStore
    @ObservationIgnored private let credentials: HostCredentialsProvider

    init(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider()
    ) {
        self.connector = connector
        self.knownHosts = knownHosts
        self.credentials = credentials
    }

    /// Loads the endpoint's trusted fingerprint (if any) for the trust
    /// row. Runs on open — it reads the local known-hosts store, no
    /// network.
    func loadTrust(host: String, port: Int) async {
        trustedFingerprint = await knownHosts.fingerprint(host: host, port: port)
    }

    /// Probes exactly one address: an SSH handshake that closes
    /// immediately. True when the path answered. Unknown host keys fail
    /// quietly — the probe never runs the TOFU conversation; auth or trust
    /// failures still prove the path carries SSH traffic (same semantics
    /// as the onboarding sweep's `probeOne`).
    func check(host: Host, address: String) async {
        guard checkState != .checking else { return }
        checkState = .checking
        guard let resolved = try? credentials.credentials(for: host) else {
            checkState = .unchecked
            return
        }
        // No TOFU prompt from a probe: keys not already trusted fail the
        // probe quietly; onboarding owns the trust conversation.
        let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in false }
        var settings = SSHTransportSettings(
            host: host, credentials: resolved, hostKeyPolicy: policy)
        settings.host = address
        settings.candidateAddresses = []
        do {
            let transport = try await connector.connect(settings: settings)
            try? await transport.close()
            checkState = .reachable
        } catch is CancellationError {
            // A cancelled probe decided nothing: back to unchecked so a
            // later press can retry.
            checkState = .unchecked
        } catch {
            if let transportError = error as? TransportError,
                transportError.isReachFailure
            {
                checkState = .unreachable
            } else {
                // Non-reach failures (auth, unknown host key) still prove
                // the path carries SSH traffic.
                checkState = .reachable
            }
        }
    }
}

/// The pure presentation for one route on the Host card and in the
/// inspector: named, exact address, and an honest in-use/alternate state
/// (handoff §E requirement 2). An alternate route is NEVER shown
/// connected: `inUse` is true only when the live session's dialed address
/// equals this route's address.
struct HostRoutePresentation: Equatable, Sendable {
    enum Usage: Equatable, Sendable {
        /// The live session is dialed through this route.
        case inUse
        /// Saved for this Host; reachability unknown until checked.
        case alternate
    }

    let name: String
    let address: String
    let usage: Usage

    init(host: Host, address: String, connectedAddress: String?) {
        self.name = host.routeName(for: address)
        self.address = address
        self.usage = connectedAddress == address ? .inUse : .alternate
    }

    /// The state chip the Host card row shows.
    var stateLabel: String {
        switch usage {
        case .inUse: "In use"
        case .alternate: "Alternate"
        }
    }

    var accessibilityLabel: String {
        switch usage {
        case .inUse:
            "Route \(name), \(address), currently in use"
        case .alternate:
            "Route \(name), \(address), alternate route, reachability unknown until checked"
        }
    }
}

/// The sheet that inspects ONE route of ONE Host, titled
/// `HOST · ROUTE`: exact address:port and user, trust/reachability
/// information, and an explicit check button. Never claims an unchecked
/// alternate route is connected (handoff §E).
struct HostRouteInspectorView: View {
    let host: Host
    let route: HostRoutePresentation
    @Environment(\.dismiss) private var dismiss
    @State private var store: HostRouteInspectorStore

    init(
        host: Host,
        address: String,
        connectedAddress: String?,
        store: HostRouteInspectorStore = HostRouteInspectorStore()
    ) {
        self.host = host
        self.route = HostRoutePresentation(
            host: host, address: address, connectedAddress: connectedAddress)
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connection target")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(route.address):\(String(host.port))")
                            .font(.title3.weight(.semibold))
                            .monospaced()
                            .textSelection(.enabled)
                        Text(host.username)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                Section {
                    LabeledContent("SSH connection") {
                        connectionStateText
                    }
                    LabeledContent("Host key") {
                        trustText
                    }
                    LabeledContent("Route selection") {
                        switch route.usage {
                        case .inUse: Text("Currently in use")
                        case .alternate: Text("Available alternative")
                        }
                    }
                } header: {
                    Text("Status")
                }

                Section {
                    Button {
                        checkRoute()
                    } label: {
                        Label("Check this route", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(store.checkState == .checking)
                } footer: {
                    Text(routeExplanation)
                }
            }
            .navigationTitle("\(host.displayName) · \(route.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                Task { await store.loadTrust(host: route.address, port: host.port) }
            }
        }
    }

    private var connectionStateText: Text {
        switch route.usage {
        case .inUse:
            return Text("Connected").foregroundStyle(.green)
        case .alternate:
            switch store.checkState {
            case .unchecked:
                return Text("Not checked this session").foregroundStyle(.secondary)
            case .checking:
                return Text("Checking…").foregroundStyle(.secondary)
            case .reachable:
                return Text("Reachable").foregroundStyle(.green)
            case .unreachable:
                return Text("Unreachable").foregroundStyle(.red)
            }
        }
    }

    private var trustText: Text {
        if let fingerprint = store.trustedFingerprint {
            return Text("Trusted · \(fingerprint.displayString)")
                .font(.footnote.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        return Text("Not checked this session").foregroundStyle(.secondary)
    }

    private var routeExplanation: String {
        switch route.usage {
        case .inUse:
            return "This is the route currently carrying traffic to \(host.displayName)."
        case .alternate:
            return "This route is saved for \(host.displayName). Its reachability is "
                + "unknown until checked."
        }
    }

    private func checkRoute() {
        Task { await store.check(host: host, address: route.address) }
    }

}
