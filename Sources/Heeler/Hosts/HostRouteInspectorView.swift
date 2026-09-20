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
/// owns facts the sheet can change (probe + trust lookup).
@MainActor
@Observable
final class HostRouteInspectorStore {
    private(set) var checkState: RouteCheckState = .unchecked
    /// Actionable explanation when a check could not run at all (§E:
    /// the user's Check must never appear to silently do nothing). nil
    /// while the check ran and produced a reachability verdict.
    private(set) var checkFailureExplanation: String?
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
        checkFailureExplanation = nil
        guard let resolved = try? credentials.credentials(for: host) else {
            // The check could not even start: say WHY (no silent reset —
            // §E: the user's press must surface an actionable failure).
            checkState = .unchecked
            switch host.authMethod {
            case .password:
                checkFailureExplanation =
                    "The check could not run: no password is saved for "
                    + "\(host.displayAliasName)."
            case .deviceKey:
                checkFailureExplanation =
                    "The check could not run: the Device Key could not "
                    + "be loaded. Open Edit and replace it if it is corrupt."
            }
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

    /// The route vocabulary (kept per the prototype; the card ROW is quiet
    /// — the user's dot-only decision — but the inspector keeps words).
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
/// `HOST · ROUTE`, at the prototype's compact density
/// (host-preview.js connectionDetails): a small connection-target block
/// (eyebrow, ONE strong monospace address:port line, quiet `user ·
/// state` subline), a compact group of setting rows, an explicit check
/// control, and an in-context `Edit route` affordance that opens the SAME
/// route editor the host form uses — so naming a route is reachable
/// where the user actually lands. Content-height detents, never
/// full-screen sprawl. Never claims an unchecked alternate route is
/// connected (handoff §E).
struct HostRouteInspectorView: View {
    let host: Host
    let route: HostRoutePresentation
    /// Whether the tapped route carries a user label yet — the Edit
    /// affordance's hint that a friendly name is available to add.
    let routeHasLabel: Bool
    /// The probe/trust state, owned by the PRESENTING view for the
    /// lifetime of one sheet presentation (device bug #5): this view is
    /// rebuilt inside the sheet's content closure on every parent
    /// status tick, and a store held as @State here was re-created
    /// mid-probe — silently discarding the user's check verdict. The
    /// owner creates it when the inspector opens and releases it on
    /// dismissal.
    let ownedStore: HostRouteInspectorStore
    @State private var isEditingRoute = false
    /// The edited route's new label: the inspector and the caller's list
    /// refresh reactively when the catalog updates, so this only needs
    /// to exist long enough to hand the edit to the saver.
    @State private var editedRoute: AdditionalAddressRow?
    @Environment(\.dismiss) private var dismiss
    /// Persists route edits made in-context (the host catalog; same
    /// store the host form saves through).
    var onEditRoute: ((AdditionalAddressRow) -> Void)?

    /// A presentation-local store for previews and direct embedding.
    init(
        host: Host,
        address: String,
        connectedAddress: String?,
        routeHasLabel: Bool? = nil,
        onEditRoute: ((AdditionalAddressRow) -> Void)? = nil
    ) {
        self.host = host
        self.route = HostRoutePresentation(
            host: host, address: address, connectedAddress: connectedAddress)
        self.routeHasLabel =
            routeHasLabel ?? !(host.routeLabels[address]?.isEmpty ?? true)
        self.ownedStore = HostRouteInspectorStore()
        self.onEditRoute = onEditRoute
    }

    /// The production path: the presenting view owns the store, so one
    /// presentation owns one store for its lifetime.
    init(
        host: Host,
        address: String,
        connectedAddress: String?,
        ownedStore: HostRouteInspectorStore,
        onEditRoute: ((AdditionalAddressRow) -> Void)? = nil
    ) {
        self.host = host
        self.route = HostRoutePresentation(
            host: host, address: address, connectedAddress: connectedAddress)
        self.routeHasLabel = !(host.routeLabels[address]?.isEmpty ?? true)
        self.ownedStore = ownedStore
        self.onEditRoute = onEditRoute
    }

    var body: some View {
        NavigationStack {
            List {
                // The prototype's compact connection-target block: eyebrow
                // + ONE strong address:port line + quiet user·state subline.
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connection target")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text("\(route.address):\(String(host.port))")
                            .font(.subheadline.weight(.semibold).monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Text("\(host.username) · \(route.stateLabel) route")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("route-connection-target")
                }

                // Compact setting rows with quiet values, per the prototype.
                Section {
                    LabeledContent("SSH connection") {
                        connectionStateText
                            .accessibilityIdentifier("route-ssh-connection")
                    }
                    LabeledContent("Host key") {
                        trustText
                            .accessibilityIdentifier("route-host-key")
                    }
                    LabeledContent("Route selection") {
                        Group {
                            switch route.usage {
                            case .inUse: Text("Currently in use")
                            case .alternate: Text("Available alternative")
                            }
                        }
                        .accessibilityIdentifier("route-selection")
                    }
                }

                Section {
                    Button {
                        checkRoute()
                    } label: {
                        Label("Check this route", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(ownedStore.checkState == .checking)
                    if let failure = ownedStore.checkFailureExplanation {
                        // The check could not run: the actionable why,
                        // never a silent no-op (§E).
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("route-check-failure")
                    }
                    // In-context naming (device finding): the SAME route
                    // editor the host form uses, one tap from where the
                    // user actually lands.
                    Button {
                        isEditingRoute = true
                    } label: {
                        Label(
                            routeHasLabel ? "Edit route" : "Name this route",
                            systemImage: "pencil")
                    }
                    .accessibilityIdentifier("route-inspector-edit")
                } footer: {
                    Text(routeExplanation)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("\(host.displayName) · \(route.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .presentationDetents([.height(500), .large])
            .sheet(isPresented: $isEditingRoute) {
                HostRouteEditView(
                    hostName: host.displayAliasName,
                    route: editedRoute ?? routeEditorRow,
                    isPrimaryRoute: host.address == route.address,
                    onSave: { updated in
                        onEditRoute?(updated)
                    },
                    onRemove: nil)
            }
            .onAppear {
                Task { await ownedStore.loadTrust(host: route.address, port: host.port) }
            }
        }
    }
    /// The tapped route as the editor's row shape: the row identity is the
    /// address's position in the Host's candidates (address-keyed like the
    /// labels), so an in-inspector save lands on exactly this route.
    private var routeEditorRow: AdditionalAddressRow {
        AdditionalAddressRow(
            address: route.address,
            label: host.routeLabels[route.address] ?? "")
    }

    private var connectionStateText: Text {
        switch route.usage {
        case .inUse:
            return Text("Connected").foregroundStyle(.green)
        case .alternate:
            switch ownedStore.checkState {
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

    @ViewBuilder private var trustText: some View {
        if let fingerprint = ownedStore.trustedFingerprint {
            Text("Trusted · \(fingerprint.displayString)")
                .font(.footnote.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("Not checked this session").foregroundStyle(.secondary)
        }
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
        Task { await ownedStore.check(host: host, address: route.address) }
    }
}
