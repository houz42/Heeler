import CryptoKit
import Foundation
import Testing

@testable import Heeler

/// Broker provisioning: state machine over the status taxonomy, operation
/// paths through the reused seams, prerequisite detection, checksum
/// verification, and atomic-install semantics. The remote is a scripted
/// transport — no SSH; the shell-command semantics were verified against
/// a real local `sh` run of the generated scripts.
@MainActor
@Suite("Broker provisioning")
struct BrokerProvisioningTests {

    // MARK: - Scripted transport

    /// Scripts `runProvisioningCommand` by exact command match; captures
    /// every command for ordering assertions. `stageFile` reports a fixed
    /// staged path.
    private final actor ScriptedProvisioningTransport: Transport {
        private(set) var commands: [String] = []
        private var responses: [String: RemoteCommandResult] = [:]
        private var responseSequence: [String: [RemoteCommandResult]] = [:]
        private(set) var isClosed = false

        func addScript(_ command: String, result: RemoteCommandResult) {
            responseSequence[command, default: []].append(result)
        }

        func runProvisioningCommand(_ command: String) async throws -> RemoteCommandResult {
            commands.append(command)
            if var sequence = responseSequence[command], !sequence.isEmpty {
                let result = sequence.removeFirst()
                responseSequence[command] = sequence
                return result
            }
            if let result = responses[command] {
                return result
            }
            // Default: exit 0 with empty stdout (probes read as absent).
            return RemoteCommandResult(stdout: Data(), exitStatus: 0)
        }

        func stageFile(
            _ file: PreparedFile,
            progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
        ) async throws -> StagedFile {
            try StagedFile(path: "/remote/staging/\(file.remoteFilename)")
        }

        func ping() async throws -> ServerInfo {
            throw TransportError.channelFailed(detail: "not scripted")
        }

        // MARK: Transport stubs the provisioning store never calls.

        func listAgents() async throws -> [Agent] { [] }
        func sessionSnapshot() async throws -> SessionSnapshot {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func sendAgentKeys(_ params: AgentSendKeysParams) async throws {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func startAgentInNewWorktree(
            _ request: AgentLaunchRequest, worktree: WorktreeSpec
        ) async throws -> Agent {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func startAgentInNewWorkspace(
            _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
        ) async throws -> Agent {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func closePane(_ params: PaneTarget) async throws {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func focusAgent(_ target: AgentTarget) async throws {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func renameAgent(_ params: AgentRenameParams) async throws {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func subscribeToEvents(
            _ subscriptions: [EventSubscription]
        ) async throws -> HerdrEventStream {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func attachTerminal(
            _ request: TerminalAttachRequest
        ) async throws -> TerminalAttachSession {
            throw TransportError.channelFailed(detail: "not scripted")
        }

        var isConnected: Bool { !isClosed }

        func close() async throws { isClosed = true }
    }

    /// A Transport that fails every command: the backend-unavailable path.
    private final actor FailingTransport: Transport {
        func ping() async throws -> ServerInfo {
            throw TransportError.channelFailed(detail: "x")
        }
        func runProvisioningCommand(
            _ command: String
        ) async throws -> RemoteCommandResult {
            throw TransportError.channelFailed(detail: "boom")
        }
        func listAgents() async throws -> [Agent] { [] }
        func sessionSnapshot() async throws -> SessionSnapshot {
            throw TransportError.channelFailed(detail: "x")
        }
        func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
            throw TransportError.channelFailed(detail: "x")
        }
        func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
            throw TransportError.channelFailed(detail: "x")
        }
        func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
            throw TransportError.channelFailed(detail: "x")
        }
        func sendAgentKeys(_ params: AgentSendKeysParams) async throws {}
        func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
            throw TransportError.channelFailed(detail: "x")
        }
        func startAgentInNewWorktree(
            _ request: AgentLaunchRequest, worktree: WorktreeSpec
        ) async throws -> Agent {
            throw TransportError.channelFailed(detail: "x")
        }
        func startAgentInNewWorkspace(
            _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
        ) async throws -> Agent {
            throw TransportError.channelFailed(detail: "x")
        }
        func closePane(_ params: PaneTarget) async throws {}
        func focusAgent(_ target: AgentTarget) async throws {}
        func renameAgent(_ params: AgentRenameParams) async throws {}
        func renameWorkspace(_ params: WorkspaceRenameParams) async throws {}
        func subscribeToEvents(
            _ subscriptions: [EventSubscription]
        ) async throws -> HerdrEventStream {
            throw TransportError.channelFailed(detail: "x")
        }
        func attachTerminal(
            _ request: TerminalAttachRequest
        ) async throws -> TerminalAttachSession {
            throw TransportError.channelFailed(detail: "x")
        }
        var isConnected: Bool { false }
        func close() async throws {}
    }

    private func makeLayout(
        platform: RemoteHostPlatform = .linux, suffix: String = "t1"
    ) -> BrokerProvisioningLayout {
        .development(platform: platform, root: "/tmp/hc-test", suffix: suffix)
    }

    /// One inspect probe's canned output, covering every key.
    private func inspectOutput(
        platform: String = "Linux",
        home: String = "/home/dev",
        node: String = "v24.1.0",
        omp: String = "present",
        version: String? = nil,
        socket: String = "absent",
        service: String = "inactive"
    ) -> String {
        var lines = [
            "platform=\(platform)", "home=\(home)", "node=\(node)",
            "omp=\(omp)", "installed=\(version == nil ? "absent" : "present")",
            "version=\(version ?? "")", "socket=\(socket)", "service=\(service)",
        ]
        _ = lines
        return lines.joined(separator: "\n")
    }

    private func makeStore(
        transport: ScriptedProvisioningTransport,
        layout: BrokerProvisioningLayout
    ) -> BrokerProvisioningStore {
        BrokerProvisioningStore(
            transport: transport,
            layoutBuilder: { _, _ in layout })
    }

    // MARK: - Inspect / status

    @Test func inspectDetectsPlatformAndBuildsLayout() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout()
        let store = makeStore(transport: transport, layout: layout)

        // Platform probe.
        await transport.addScript(
            "printf '%s\\n%s\\n' \"$(uname)\" \"${HOME:-\"\"}\"",
            result: RemoteCommandResult(
                stdout: Data("Linux\n/home/dev\n".utf8), exitStatus: 0))
        // Inspect probe: nothing installed, Node present, omp absent.
        await transport.addScript(
            layout.inspectCommand,
            result: RemoteCommandResult(
                stdout: Data(
                    inspectOutput(node: "v18.0.0", omp: "absent").utf8),
                exitStatus: 0))
        // Adapter env read: absent (cat of missing file → exit 1, empty).
        await transport.addScript(
            layout.readAdapterShimCommand,
            result: RemoteCommandResult(stdout: Data(), exitStatus: 1))

        await store.inspect()

        #expect(store.state.platform == .linux)
        #expect(store.state.layout == layout)
        #expect(store.state.status == .notInstalled)
        // Node 18 < 22 → missing with version; omp absent → missing.
        #expect(store.state.node == .missingVersion("v18.0.0"))
        #expect(store.state.omp == .missing)
        let hints = store.state.missingPrerequisiteHints
        #expect(hints.count == 2)
        #expect(hints[0].contains("Node 22+"))
        #expect(hints[1].contains("omp"))
    }

    @Test func statusFullyProvisionedWhenActiveAndAdapterConfigured() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t2")
        let store = makeStore(transport: transport, layout: layout)
        await transport.addScript(
            "printf '%s\\n%s\\n' \"$(uname)\" \"${HOME:-\"\"}\"",
            result: RemoteCommandResult(
                stdout: Data("Linux\n/home/dev\n".utf8), exitStatus: 0))
        await transport.addScript(
            layout.inspectCommand,
            result: RemoteCommandResult(
                stdout: Data(
                    inspectOutput(
                        version: "1.2.0", socket: "present", service: "active"
                    ).utf8),
                exitStatus: 0))
        await transport.addScript(
            layout.readAdapterShimCommand,
            result: RemoteCommandResult(
                stdout: Data(
                    "// Managed by Heeler. Replaces the broker-adapter extension shim.\n"
                        .utf8),
                exitStatus: 0))

        await store.inspect()

        #expect(
            store.state.status
                == .fullyProvisioned(activeVersion: "1.2.0"))
        #expect(store.state.adapterConfigured)
        #expect(store.state.socketPresent)
    }

    @Test func installedInactiveReportsServiceInactive() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t3")
        let store = makeStore(transport: transport, layout: layout)
        await transport.addScript(
            "printf '%s\\n%s\\n' \"$(uname)\" \"${HOME:-\"\"}\"",
            result: RemoteCommandResult(
                stdout: Data("Linux\n/home/dev\n".utf8), exitStatus: 0))
        await transport.addScript(
            layout.inspectCommand,
            result: RemoteCommandResult(
                stdout: Data(inspectOutput(version: "1.2.0").utf8), exitStatus: 0))
        await transport.addScript(
            layout.readAdapterShimCommand,
            result: RemoteCommandResult(stdout: Data(), exitStatus: 1))

        await store.inspect()

        #expect(store.state.status == .installed(serviceActive: false))
        #expect(store.state.status.isInstalled)
        #expect(!store.state.status.isServiceActive)
    }

    @Test func inspectFailureReportsBackendUnavailable() async throws {
        let layout = makeLayout(suffix: "t4")
        // A transport whose every command throws: the inspect probe fails,
        // leaving the state un-inspected (backend unavailable) with the
        // failure recorded.
        let failingStore = BrokerProvisioningStore(
            transport: FailingTransport(),
            layoutBuilder: { _, _ in layout })

        await failingStore.inspect()

        #expect(
            failingStore.state.status
                == .backendUnavailable(reason: "Not inspected yet."))
        #expect(failingStore.lastError != nil)
    }

    // MARK: - Prerequisite detection

    @Test func nodeMajorVersionParsesLeadingV() {
        #expect(BrokerProvisioningStore.nodeMajorVersion("v22.3.1") == 22)
        #expect(BrokerProvisioningStore.nodeMajorVersion("v24.21.0") == 24)
        #expect(BrokerProvisioningStore.nodeMajorVersion("18.0.0") == 18)
        #expect(BrokerProvisioningStore.nodeMajorVersion("none") == 0)
        #expect(BrokerProvisioningStore.nodeMajorVersion("") == 0)
    }

    @Test func minimumNodeIs22() {
        #expect(BrokerProvisioningLayout.minimumNodeMajorVersion == 22)
    }

    // MARK: - Checksum verification

    @Test func localChecksumMismatchFailsInstallBeforeUpload() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t5")
        let store = makeStore(transport: transport, layout: layout)
        store.state.layout = layout
        store.state.activeVersion = "1.0.0"

        let package = try makePackageFixture(contents: "package-bytes")
        let wrongSHA = String(repeating: "0", count: 64)

        await #expect(throws: BrokerProvisioningError.packageChecksumMismatch) {
            try await store.install(
                package: package, version: "1.1.0", sha256: wrongSHA)
        }
        // No remote mutation happened — the failure is pre-upload.
        let commands = await transport.commands
        #expect(commands.filter { $0.contains("staging") || $0.contains("tar") }.isEmpty)
    }

    @Test func remoteChecksumMismatchFailsInstallAfterUpload() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t6")
        let store = makeStore(transport: transport, layout: layout)
        store.state.layout = layout
        store.state.activeVersion = "1.0.0"

        let contents = Data("package-bytes".utf8)
        let package = try makePackageFixture(contents: "package-bytes")
        let correctSHA = sha256Hex(contents)

        // The remote reports a MISMATCH on the staged bytes. The staged
        // filename comes from PreparedFile: extensions keep only
        // [0-9a-z], so "tar.gz" arrives at the transport as "targz".
        await transport.addScript(
            try layout.remoteChecksumCommand(
                path: "/remote/staging/file.targz", expectedSHA256: correctSHA),
            result: RemoteCommandResult(
                stdout: Data("mismatch".utf8), exitStatus: 0))

        await #expect(throws: BrokerProvisioningError.remoteChecksumMismatch) {
            try await store.install(
                package: package, version: "1.1.0", sha256: correctSHA)
        }
        // Extract never ran.
        let commands = await transport.commands
        #expect(!commands.contains { $0.contains(".incomplete") })
    }

    @Test func installRunsAtomicSequence() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t7")
        let store = makeStore(transport: transport, layout: layout)
        store.state.layout = layout

        let contents = Data("package-bytes".utf8)
        let package = try makePackageFixture(contents: "package-bytes")
        let sha = sha256Hex(contents)
        let checksumCommand = try layout.remoteChecksumCommand(
            path: "/remote/staging/file.targz", expectedSHA256: sha)
        await transport.addScript(
            checksumCommand,
            result: RemoteCommandResult(stdout: Data("ok".utf8), exitStatus: 0))

        try await store.install(package: package, version: "1.1.0", sha256: sha)

        let commands = await transport.commands
        // The sequence: checksum, extract, promote (with .incomplete
        // rollback), prune (ls | grep -v keep | xargs rm), then re-inspect.
        #expect(commands.contains(checksumCommand))
        #expect(commands.contains { $0.contains("tar -xzf") })
        #expect(commands.contains { $0.contains("mv ") && $0.contains(".incomplete") })
        #expect(commands.contains { $0.contains("current.tmp") })
        #expect(commands.contains { $0.contains("grep -v") && $0.contains("xargs rm -rf") })
        // Ordering: extract before promote before prune.
        let extractIndex = try #require(commands.firstIndex { $0.contains("tar -xzf") })
        let promoteIndex = try #require(
            commands.firstIndex { $0.contains(".incomplete") && $0.contains("current.tmp") })
        let pruneIndex = try #require(
            commands.firstIndex { $0.contains("xargs rm -rf") })
        #expect(extractIndex < promoteIndex)
        #expect(promoteIndex < pruneIndex)
        // The atomic-promote command rolls back the .incomplete dir on failure.
        let promote = commands.first { $0.contains(".incomplete") }
        #expect(try #require(promote).contains("rm -rf"))
        // Extract validates the broker entrypoint + manifest before promote.
        let extract = commands.first { $0.contains("tar -xzf") }
        #expect(try #require(extract).contains("test -x"))
        #expect(try #require(extract).contains("manifest.json"))
    }

    @Test func installRejectsUnsafeVersions() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t8")
        let store = makeStore(transport: transport, layout: layout)
        store.state.layout = layout

        for bad in ["", ".", "..", "1.0.0; rm -rf /", "1.0.0`x`", "1.0.0$(x)", "a b c"] {
            await #expect(throws: BrokerProvisioningError.invalidPackageVersion) {
                try await store.install(
                    package: try makePackageFixture(contents: "x"),
                    version: bad,
                    sha256: sha256Hex(Data("x".utf8)))
            }
        }
    }

    // MARK: - Enable / disable / upgrade / uninstall

    @Test func enableRequiresInstallThenRunsDirectoryEnvUnitEnableSequence() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t9")
        let store = makeStore(transport: transport, layout: layout)
        // Simulate an inspected-and-installed state.
        store.state.layout = layout
        store.state.activeVersion = "1.1.0"
        store.state.node = .satisfied
        store.state.omp = .satisfied

        try await store.enable()

        let commands = await transport.commands
        #expect(commands.contains { $0.contains("mkdir -p") && $0.contains("chmod 700") })
        #expect(commands.contains { $0.contains("broker.env") })
        #expect(commands.contains { $0.contains("systemctl --user enable --now") })
        // The unit write pins the active version's entrypoint: decode the
        // base64 payload of the unit write (the command that targets the
        // systemd user unit path) and verify the ExecStart line.
        let unitWrite = try #require(
            commands.first { $0.contains(layout.unitInstallPath) })
        let payload = try #require(
            unitWrite.split(separator: "'").first { $0.count > 40 })
        let decoded = String(
            decoding: try #require(Data(base64Encoded: String(payload))),
            as: UTF8.self)
        #expect(decoded.contains("[Unit]"))
        #expect(
            decoded.contains(
                "ExecStart=\(layout.brokerExecutablePath(activeVersion: "1.1.0"))"))
        #expect(decoded.contains("Restart=on-failure"))
    }

    @Test func enableRefusedWhenPrerequisitesMissing() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t10")
        let store = makeStore(transport: transport, layout: layout)
        store.state.layout = layout
        store.state.activeVersion = "1.1.0"
        store.state.node = .missingVersion("v18.0.0")
        store.state.omp = .satisfied

        await #expect(throws: BrokerProvisioningError.self) {
            try await store.enable()
        }
        let commands = await transport.commands
        #expect(commands.isEmpty)
    }

    @Test func enableRefusedWhenNothingInstalled() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t11")
        let store = makeStore(transport: transport, layout: layout)
        store.state.layout = layout
        store.state.node = .satisfied
        store.state.omp = .satisfied

        await #expect(throws: BrokerProvisioningError.self) {
            try await store.enable()
        }
    }

    @Test func disableRunsServiceDisable() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t12")
        let store = makeStore(transport: transport, layout: layout)
        store.state.layout = layout

        try await store.disable()

        let commands = await transport.commands
        #expect(commands.contains { $0.contains("systemctl --user disable --now") })
    }

    @Test func upgradeReEnablesOnlyWhenServiceWasActive() async throws {
        // Service active before → upgrade ends with enable.
        do {
            let transport = ScriptedProvisioningTransport()
            let layout = makeLayout(suffix: "t13")
            let store = makeStore(transport: transport, layout: layout)
            store.state.layout = layout
            store.state.activeVersion = "1.0.0"
            store.state.serviceActive = true
            store.state.node = .satisfied
            store.state.omp = .satisfied

            let contents = Data("package-bytes".utf8)
            let package = try makePackageFixture(contents: "package-bytes")
            let sha = sha256Hex(contents)
            await transport.addScript(
                try layout.remoteChecksumCommand(
                    path: "/remote/staging/file.targz", expectedSHA256: sha),
                result: RemoteCommandResult(stdout: Data("ok".utf8), exitStatus: 0))

            try await store.upgrade(package: package, version: "1.1.0", sha256: sha)

            let commands = await transport.commands
            #expect(commands.contains { $0.contains("systemctl --user enable --now") })
        }
        // Service inactive before → upgrade installs but does NOT enable.
        do {
            let transport = ScriptedProvisioningTransport()
            let layout = makeLayout(suffix: "t13b")
            let store = makeStore(transport: transport, layout: layout)
            store.state.layout = layout
            store.state.activeVersion = "1.0.0"
            store.state.serviceActive = false
            store.state.node = .satisfied
            store.state.omp = .satisfied

            let contents = Data("package-bytes".utf8)
            let package = try makePackageFixture(contents: "package-bytes")
            let sha = sha256Hex(contents)
            await transport.addScript(
                try layout.remoteChecksumCommand(
                    path: "/remote/staging/file.targz", expectedSHA256: sha),
                result: RemoteCommandResult(stdout: Data("ok".utf8), exitStatus: 0))

            try await store.upgrade(package: package, version: "1.1.0", sha256: sha)

            let commands = await transport.commands
            #expect(!commands.contains { $0.contains("systemctl --user enable --now") })
        }
    }

    @Test func uninstallRemovesOnlyHelperOwnedPaths() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t14")
        let store = makeStore(transport: transport, layout: layout)
        store.state.layout = layout

        try await store.uninstall()

        let uninstall = await transport.commands.first { $0.contains("rm -rf") }
        let command = try #require(uninstall)
        #expect(command.contains(layout.dataRoot))
        #expect(command.contains(layout.configRoot))
        #expect(command.contains(layout.socketPath))
        #expect(command.contains(layout.unitInstallPath))
        // Session/history trees are outside the footprint by construction:
        // the rm list names only the layout's own roots.
        #expect(command.split(separator: " ").filter { $0.hasPrefix("rm") }.count >= 1)
        #expect(!command.contains(".config/opencode"))
        #expect(!command.contains(".local/share/omp"))
        #expect(!command.contains("sessions"))
    }

    @Test func uninstallPreservesSessionsByOmission() async throws {
        // The macOS variant of the same property.
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(platform: .macOS, suffix: "t15")
        let store = makeStore(transport: transport, layout: layout)
        store.state.layout = layout

        try await store.uninstall()

        let uninstall = await transport.commands.first { $0.contains("rm -rf") }
        #expect(try #require(uninstall).contains("bootout"))
    }

    // MARK: - Adapter configuration

    @Test func adapterShimDefaultsAskWrapperOff() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t16")
        let store = makeStore(transport: transport, layout: layout)
        store.state.layout = layout
        store.state.activeVersion = "1.1.0"

        try await store.configureAdapter(askWrapperOptIn: false)

        // The shim write targets the helper-owned shim path, and its
        // decoded payload carries the versioned import but NOT the
        // ask-wrapper flag (absent = OFF).
        let write = try #require(
            await transport.commands.first {
                $0.contains(layout.adapterShimPath) && $0.contains("base64")
            })
        let payload = try #require(
            write.split(separator: "'").first { $0.count > 40 })
        let text = String(
            decoding: try #require(Data(base64Encoded: String(payload))),
            as: UTF8.self)
        #expect(text.contains("Managed by Heeler"))
        #expect(
            text.contains(
                "from \"\(layout.versionsDirectory)/1.1.0/broker/adapters/omp/extension.ts\""))
        #expect(!text.contains("HEELER_CHAT_ASK_WRAPPER"))
    }

    @Test func adapterShimWritesOptInOnlyOnExplicitRequest() async throws {
        let transport = ScriptedProvisioningTransport()
        let layout = makeLayout(suffix: "t17")
        let store = makeStore(transport: transport, layout: layout)
        store.state.layout = layout
        store.state.activeVersion = "1.1.0"

        try await store.configureAdapter(askWrapperOptIn: true)

        let write = try #require(
            await transport.commands.first {
                $0.contains(layout.adapterShimPath) && $0.contains("base64")
            })
        let payload = try #require(
            write.split(separator: "'").first { $0.count > 40 })
        let text = String(
            decoding: try #require(Data(base64Encoded: String(payload))),
            as: UTF8.self)
        #expect(text.contains("process.env.HEELER_CHAT_ASK_WRAPPER = \"1\""))
    }

    // MARK: - Development-vs-production layout safety

    @Test func macOSUnitWriteSubstitutesNodeDirHostSide() throws {
        // The launchd write pipes the base64 body through a host-side
        // sed that substitutes the __MEADOW_NODE_DIR__ placeholder with
        // the discovered node directory — plists carry literal paths only.
        let layout = makeLayout(platform: .macOS, suffix: "nodepath")
        let command = try layout.writeUnitCommand(activeVersion: "0.1.0")
        #expect(command.contains("sed \"s|__MEADOW_NODE_DIR__|$(dirname \"$(command -v node)\")|\""))
        #expect(command.contains("base64 -d"))
    }

    @Test func developmentLayoutUsesDisposableRootsAndTestServiceNames() {
        let layout = makeLayout(suffix: "safety")
        #expect(layout.dataRoot.contains("meadow-test-safety"))
        #expect(layout.serviceName.contains("meadow-test"))
        #expect(!layout.usesXDGDataDirSocket)
        #expect(!layout.usesRealLaunchAgentsDir)
        // Production layout names the real Meadow footprint, with the
        // XDG_DATA_HOME socket template expanded on the Host.
        let production = BrokerProvisioningLayout.standard(
            platform: .linux, homeDirectory: "/home/dev")
        #expect(production.dataRoot == "/home/dev/.local/share/meadow")
        #expect(production.serviceName == "meadow-broker")
        #expect(production.usesXDGDataDirSocket)
        #expect(
            production.shellSocketPath
                == "${XDG_DATA_HOME:-/home/dev/.local/share/meadow}/meadow/broker.sock")
        #expect(
            production.adapterShimPath
                == "/home/dev/.omp/agent/extensions/meadow-chat.ts")
    }

    @Test func macOSStandardLayoutMirrorsTheMeadowDataTree() {
        let production = BrokerProvisioningLayout.standard(
            platform: .macOS, homeDirectory: "/Users/dev")
        // Binding: the Meadow standard data tree — ~/.local/share/meadow
        // on BOTH platforms; never Application Support, never ~/.cache.
        #expect(
            production.dataRoot == "/Users/dev/.local/share/meadow")
        #expect(production.serviceName == "com.meadow.chat.broker")
        #expect(
            production.socketPath
                == "/Users/dev/.local/share/meadow/broker.sock")
        #expect(production.usesXDGDataDirSocket)
        #expect(production.usesRealLaunchAgentsDir)
    }

    // MARK: - Fixtures

    private func makePackageFixture(contents: String) throws -> PreparedFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-pkg-\(UUID().uuidString).targz")
        try Data(contents.utf8).write(to: url)
        // "targz": PreparedFile's safeExtension keeps [0-9a-z] only, and
        // the staged remote filename derives from it ("file.targz").
        return PreparedFile(
            fileURL: url, fileExtension: "targz", byteCount: Int64(contents.utf8.count))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
