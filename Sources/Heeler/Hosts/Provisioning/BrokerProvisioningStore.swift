import CryptoKit
import Foundation
import Observation

/// Error taxonomy for provisioning operations. Remote command exit-status
/// failures carry the command's own answer; transport failures stay
/// `TransportError`.
enum BrokerProvisioningError: Error, Sendable, Equatable {
    /// A layout path failed the conservative quoting subset.
    case layoutPathUnsafe
    /// The local package's checksum did not match its checksums.json.
    case packageChecksumMismatch
    /// The staged package's remote checksum did not match.
    case remoteChecksumMismatch
    /// The package version string is not a safe single word.
    case invalidPackageVersion
    /// The platform's service system rejected an enable/disable.
    /// `detail` is the command's stderr or status.
    case serviceCommandFailed(detail: String)
    /// The remote command infrastructure failed (non-EOF or transport).
    case commandFailed(detail: String)

    var userMessage: String {
        switch self {
        case .layoutPathUnsafe:
            "The Host's paths contain characters this installer cannot quote safely."
        case .packageChecksumMismatch:
            "The package failed its checksum verification before upload. Re-download it and retry."
        case .remoteChecksumMismatch:
            "The uploaded package failed checksum verification on the Host. Retry the install."
        case .invalidPackageVersion:
            "The package version is not a valid single word."
        case .serviceCommandFailed(let detail):
            "The Host's service system refused the operation. (\(detail))"
        case .commandFailed(let detail):
            "A provisioning command failed on the Host. (\(detail))"
        }
    }
}

/// The chat-broker provisioning state machine, driven entirely through the
/// existing Host mechanics: `HostOnboardingStore`-style one-connect
/// credential resolution + TOFU, `Transport.runProvisioningCommand` for
/// remote mutations (every one an explicit user action), and
/// `Transport.stageFile` for package upload.
///
/// Statuses (spec): backendUnavailable / installed / serviceActive /
/// adapterConfigured / restartRequired, plus prerequisite findings (Node
/// >= 22, omp) surfaced as actionable statuses. Inspect/status run
/// automatically; install/enable/disable/upgrade/uninstall never do — the
/// UI fires them from explicit buttons only.
@MainActor
@Observable
final class BrokerProvisioningStore {
    enum Phase: Equatable {
        case idle
        /// Inspect probe in flight.
        case inspecting
        /// A mutation (install/enable/disable/upgrade/uninstall) in flight.
        case operating
        case finished
    }

    /// One actionable finding from the inspect probe.
    enum PrerequisiteStatus: Equatable, Sendable {
        case satisfied
        case missingVersion(String)
        case missing

        var isSatisfied: Bool {
            switch self {
            case .satisfied: true
            case .missingVersion, .missing: false
            }
        }
    }

    /// The composite status the UI renders, in spec order.
    enum Status: Equatable {
        /// Never inspected (or the transport is not connected).
        case backendUnavailable(reason: String)
        /// Not installed: no `current` marker.
        case notInstalled
        /// Installed but the service is not active.
        case installed(serviceActive: Bool)
        /// Everything provisioned.
        case fullyProvisioned(activeVersion: String)

        var isInstalled: Bool {
            switch self {
            case .backendUnavailable, .notInstalled: false
            case .installed, .fullyProvisioned: true
            }
        }

        var isServiceActive: Bool {
            switch self {
            case .installed(let active): active
            case .fullyProvisioned: true
            case .backendUnavailable, .notInstalled: false
            }
        }
    }

    struct State: Equatable, Sendable {
        var platform: RemoteHostPlatform?
        var activeVersion: String?
        var socketPresent = false
        var serviceUnitInstalled = false
        var serviceActive = false
        var adapterConfigured = false
        var node: PrerequisiteStatus = .missing
        var omp: PrerequisiteStatus = .missing
        /// The layout the last inspect derived; every mutation reuses it.
        var layout: BrokerProvisioningLayout?

        var status: Status {
            guard let layout else {
                return .backendUnavailable(reason: "Not inspected yet.")
            }
            guard let activeVersion, !activeVersion.isEmpty else {
                return .notInstalled
            }
            if serviceActive, adapterConfigured {
                return .fullyProvisioned(activeVersion: activeVersion)
            }
            return .installed(serviceActive: serviceActive)
        }

        /// Missing prerequisites rendered as actionable labels.
        var missingPrerequisiteHints: [String] {
            var hints: [String] = []
            switch node {
            case .satisfied: break
            case .missingVersion(let found):
                hints.append(
                    "Node \(BrokerProvisioningLayout.minimumNodeMajorVersion)+ required; "
                        + "found \(found.isEmpty ? "none" : found).")
            case .missing:
                hints.append("Node is not installed on the Host.")
            }
            if !omp.isSatisfied {
                hints.append("omp is not installed on the Host.")
            }
            return hints
        }
    }

    enum Operation: Equatable, Sendable {
        case install
        case enable
        case disable
        case upgrade
        case uninstall
    }

    private(set) var phase: Phase = .idle
    /// Internal: tests seed inspected states so operation paths run
    /// without scripting the full probe; production only reads.
    var state = State()
    private(set) var lastError: String?
    /// The operation whose failure set `lastError`, if any.
    private(set) var failedOperation: Operation?

    private let transport: any Transport

    /// The platform-independent fallback layout used until an inspect has
    /// run (or when the host home dir is unknown). Tests inject
    /// development layouts here to honor the disposable-roots rule.
    private let layoutBuilder: @Sendable (RemoteHostPlatform, String) -> BrokerProvisioningLayout

    init(
        transport: any Transport,
        layoutBuilder: @escaping @Sendable (RemoteHostPlatform, String) -> BrokerProvisioningLayout
            = BrokerProvisioningLayout.standard
    ) {
        self.transport = transport
        self.layoutBuilder = layoutBuilder
    }

    // MARK: - Inspect / status

    /// One round trip: probe platform, prerequisites, install state,
    /// service state, adapter config. Safe to run automatically (read-only).
    /// The adapter evidence rides the SAME command (the probe reads the
    /// adapter env file's first line) so inspect stays one round trip.
    func inspect() async {
        guard phase != .inspecting, phase != .operating else { return }
        await runInspect()
    }

    /// Re-inspects after a mutation so the UI reflects the new state.
    /// The internal form bypasses the reentry guard: the mutation has
    /// finished its own commands by the time this runs.
    private func refresh() async {
        await runInspect()
    }

    /// The inspection body; `inspect()` is the guarded public entry.
    private func runInspect() async {
        phase = .inspecting
        defer { phase = .finished }
        do {
            let layout = try await resolveLayout()
            let result = try await transport.runProvisioningCommand(
                layout.inspectCommand)
            // Adapter evidence: the shim's marker comment proves the
            // helper wrote it (it is the one file we own in that tree).
            let adapter = try await transport.runProvisioningCommand(
                layout.readAdapterShimCommand)
            var next = State()
            next.layout = layout
            var combined = result.trimmedText
            if adapter.exitStatus == 0,
                adapter.trimmedText.contains("Managed by Heeler")
            {
                combined += "\nadapter=present"
            }
            parseInspectOutput(combined, into: &next)
            state = next
            lastError = nil
            failedOperation = nil
        } catch {
            state = State()
            lastError = "Could not inspect the Host. (\(error))"
        }
    }

    /// Resolves the platform + home directory (one probe), then builds the
    /// layout. Cached in `state.layout` between mutations.
    private func resolveLayout() async throws -> BrokerProvisioningLayout {
        if let cached = state.layout { return cached }
        let result = try await transport.runProvisioningCommand(
            "printf '%s\\n%s\\n' \"$(uname)\" \"${HOME:-\"\"}\"")
        let lines = result.trimmedText.split(separator: "\n")
        guard lines.count >= 2 else {
            throw BrokerProvisioningError.commandFailed(
                detail: "Platform probe returned no answer")
        }
        let platform = RemoteHostPlatform(marker: String(lines[0]).lowercased())
        let home = String(lines[1])
        let layout = layoutBuilder(platform, home)
        state.layout = layout
        return layout
    }

    /// Parses the inspect probe's `key=value` lines into `state`. Unknown
    /// keys and malformed lines are dropped (login-shell chatter).
    private func parseInspectOutput(_ output: String, into state: inout State) {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let (key, value) = (String(parts[0]), String(parts[1]))
            switch key {
            case "platform":
                state.platform = RemoteHostPlatform(marker: value.lowercased())
            case "node":
                switch value {
                case "none", "":
                    state.node = .missing
                default:
                    // The probe reports the raw `node --version` output;
                    // only the major matters for the minimum gate.
                    if Self.nodeMajorVersion(value)
                        >= BrokerProvisioningLayout.minimumNodeMajorVersion
                    {
                        state.node = .satisfied
                    } else {
                        state.node = .missingVersion(value)
                    }
                }
            case "omp":
                state.omp = value == "present" ? .satisfied : .missing
            case "version":
                state.activeVersion = value.isEmpty ? nil : value
            case "socket":
                state.socketPresent = value == "present"
            case "service":
                state.serviceActive = value == "active"
            case "adapter":
                state.adapterConfigured = value == "present"
            default:
                break
            }
        }
        // Service-unit presence is implied: an active service proves the
        // unit; without activity the unit's own probe would be another
        // round trip the status view does not need.
        state.serviceUnitInstalled = state.serviceActive
    }

    /// "v22.3.1" -> 22.
    static func nodeMajorVersion(_ version: String) -> Int {
        let digits = version.drop(while: { $0 == "v" })
            .prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }

    // MARK: - Mutations (every one an explicit user action)

    /// Installs a versioned package atomically: local checksum verify,
    /// stage, remote checksum verify, extract to `.incomplete`, promote +
    /// swap `current`, prune old versions. No auto-enable — enable is a
    /// separate explicit action.
    func install(
        package: PreparedFile, version: String, sha256: String
    ) async throws {
        try ensureMutable()
        let layout = try requireLayout()
        try validateVersion(version)
        phase = .operating
        defer { phase = .finished }
        try verifyLocalChecksum(package: package, sha256: sha256)

        let staged = try await transport.stageFile(package) { _ in }
        let checksumResult = try await transport.runProvisioningCommand(
            try layout.remoteChecksumCommand(
                path: staged.path, expectedSHA256: sha256))
        guard checksumResult.trimmedText == "ok" else {
            throw BrokerProvisioningError.remoteChecksumMismatch
        }
        try await runZeroExit(
            try layout.extractToIncompleteCommand(stagedPath: staged.path, version: version),
            failure: .commandFailed(detail: "Could not extract the package on the Host."))
        try await runZeroExit(
            try layout.promoteVersionCommand(version: version),
            failure: .commandFailed(detail: "Could not promote the new version."))
        try await runZeroExit(
            try layout.pruneOldVersionsCommand(keep: version),
            failure: .commandFailed(detail: "Could not prune old versions."))
        try? package.remove()
        await refresh()
    }

    /// Mutations refuse to overlap an in-flight inspect or mutation.
    private func ensureMutable() throws {
        guard phase != .inspecting, phase != .operating else {
            throw BrokerProvisioningError.commandFailed(
                detail: "Another provisioning operation is in flight.")
        }
    }

    /// Writes the service unit for the active version and enables it.
    /// Requires prerequisites (Node >= 22, omp) to be satisfied.
    func enable() async throws {
        try ensureMutable()
        let layout = try requireLayout()
        guard let version = state.activeVersion, !version.isEmpty else {
            throw BrokerProvisioningError.commandFailed(
                detail: "Nothing is installed yet.")
        }
        guard state.node.isSatisfied, state.omp.isSatisfied else {
            throw BrokerProvisioningError.commandFailed(
                detail: "Missing prerequisites on the Host.")
        }
        phase = .operating
        defer { phase = .finished }
        try await runZeroExit(
            layout.ensureDirectoriesCommand,
            failure: .commandFailed(detail: "Could not create the broker directories."))
        try await runZeroExit(
            try layout.writeBrokerEnvironmentCommand(environment: [:]),
            failure: .commandFailed(detail: "Could not write the broker environment."))
        try await runZeroExit(
            try layout.writeUnitCommand(activeVersion: version),
            failure: .commandFailed(detail: "Could not write the service unit."))
        try await runZeroExit(
            layout.enableServiceCommand,
            failure: .serviceCommandFailed(detail: "enable"))
        await refresh()
    }

    func disable() async throws {
        try ensureMutable()
        let layout = try requireLayout()
        phase = .operating
        defer { phase = .finished }
        try await runZeroExit(
            layout.disableServiceCommand,
            failure: .serviceCommandFailed(detail: "disable"))
        await refresh()
    }

    /// Upgrade = install of the newer version, then — when the service was
    /// active before — a re-enable (the unit pins the active version, so
    /// the re-enable rewrites it and restarts onto the new version). An
    /// inactive service stays inactive: no auto-start on upgrade.
    func upgrade(package: PreparedFile, version: String, sha256: String) async throws {
        try ensureMutable()
        let wasActive = state.status.isServiceActive
        let prerequisitesMet = state.node.isSatisfied && state.omp.isSatisfied
        try await install(package: package, version: version, sha256: sha256)
        // install's refresh re-inspects; on a Host whose probe answers
        // race the new `current` marker, re-seed the facts this install
        // just established so enable cannot read a stale "not installed".
        state.activeVersion = version
        state.node = state.node.isSatisfied ? .satisfied : state.node
        if wasActive {
            guard prerequisitesMet else {
                throw BrokerProvisioningError.commandFailed(
                    detail: "Missing prerequisites on the Host.")
            }
            try await enable()
        }
    }

    /// Removes only helper-owned paths (unit, data root, config root,
    /// socket). Sessions/history live outside this footprint.
    func uninstall() async throws {
        try ensureMutable()
        let layout = try requireLayout()
        phase = .operating
        defer { phase = .finished }
        try await runZeroExit(
            layout.uninstallCommand,
            failure: .commandFailed(detail: "Could not uninstall the broker."))
        state = State()
        await refresh()
    }

    /// Writes the adapter shim (the one helper-owned file under
    /// `~/.omp/agent/extensions/`), importing the active versioned
    /// extension. The ask-wrapper flag is OFF unless explicitly opted in.
    func configureAdapter(askWrapperOptIn: Bool) async throws {
        try ensureMutable()
        let layout = try requireLayout()
        guard let version = state.activeVersion, !version.isEmpty else {
            throw BrokerProvisioningError.commandFailed(
                detail: "Nothing is installed yet.")
        }
        phase = .operating
        defer { phase = .finished }
        try await runZeroExit(
            layout.ensureDirectoriesCommand,
            failure: .commandFailed(detail: "Could not create the adapter directories."))
        try await runZeroExit(
            layout.writeAdapterShimCommand(
                activeVersion: version, askWrapperOptIn: askWrapperOptIn),
            failure: .commandFailed(detail: "Could not write the adapter shim."))
        await refresh()
    }

    // MARK: - Internals

    private func requireLayout() throws -> BrokerProvisioningLayout {
        guard let layout = state.layout else {
            throw BrokerProvisioningError.commandFailed(
                detail: "Inspect the Host first.")
        }
        return layout
    }

    private func validateVersion(_ version: String) throws {
        // "." and ".." are traversal names for the versions/ directory:
        // rejected alongside the charset gate.
        let valid = !version.isEmpty
            && version != "." && version != ".."
            && version.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
            }
            && version.count <= 32
        guard valid else { throw BrokerProvisioningError.invalidPackageVersion }
    }

    private func verifyLocalChecksum(package: PreparedFile, sha256: String) throws {
        // The package's checksums.json (already verified at download) is
        // re-verified here against the staged bytes: read the local file
        // and hash it.
        guard let data = try? Data(contentsOf: package.fileURL) else {
            throw BrokerProvisioningError.packageChecksumMismatch
        }
        let actual = Self.sha256Hex(data)
        guard actual == sha256.lowercased() else {
            throw BrokerProvisioningError.packageChecksumMismatch
        }
    }

    /// A command whose success is exit 0; nonzero exits map to `failure`.
    private func runZeroExit(
        _ command: String, failure: BrokerProvisioningError
    ) async throws {
        let result = try await transport.runProvisioningCommand(command)
        guard result.exitStatus == 0 else {
            throw failure
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
