import CryptoKit
import Foundation
import Testing

@testable import Heeler

/// First-connect auto-provisioning: the flow state machine, the two
/// confirmations, the host-record write, and the restart loop's
/// ask-before-restart guarantee.
@MainActor
@Suite("Meadow first-connect provisioning")
struct MeadowFirstConnectProvisioningTests {

    // MARK: - Scripted seams

    /// Scripts the whole remote surface the flow drives: provisioning
    /// commands, staging, snapshot, prompts, restarts.
    private final actor FlowTransport: Transport {
        private(set) var commands: [String] = []
        private(set) var prompts: [AgentPromptParams] = []
        private(set) var restarts: [(paneID: String, arguments: [String])] = []
        var responses: [String: RemoteCommandResult] = [:]
        private var responseSequences: [String: [RemoteCommandResult]] = [:]
        private(set) var stagedFiles: [String] = []
        private(set) var snapshotAgents: [AgentInfo] = []
        func setSnapshotAgents(_ agents: [AgentInfo]) {
            snapshotAgents = agents
        }
        var promptShouldFail = false

        func addScript(_ command: String, stdout: String, exit: Int32 = 0) {
            responses[command] = RemoteCommandResult(
                stdout: Data(stdout.utf8), exitStatus: exit)
        }

        /// Queues a scripted answer AFTER the static one: the flow's
        /// detect-inspect and post-install refresh-inspect issue the
        /// SAME command, and each run must see its own answer.
        func queueScript(_ command: String, stdout: String, exit: Int32 = 0) {
            responseSequences[command, default: []].append(
                RemoteCommandResult(stdout: Data(stdout.utf8), exitStatus: exit))
        }

        func runProvisioningCommand(_ command: String) async throws -> RemoteCommandResult {
            commands.append(command)
            if var sequence = responseSequences[command], !sequence.isEmpty {
                let result = sequence.removeFirst()
                responseSequences[command] = sequence
                return result
            }
            if let result = responses[command] {
                return result
            }
            return RemoteCommandResult(stdout: Data(), exitStatus: 0)
        }

        func stageFile(
            _ file: PreparedFile,
            progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
        ) async throws -> StagedFile {
            stagedFiles.append(file.remoteFilename)
            return try StagedFile(path: "/remote/staging/\(file.remoteFilename)")
        }

        func sessionSnapshot() async throws -> SessionSnapshot {
            SessionSnapshot(
                agents: snapshotAgents, layouts: [], panes: [],
                protocolVersion: 17, tabs: [], version: "0.9.0",
                workspaces: [])
        }

        func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
            prompts.append(params)
            if promptShouldFail {
                throw TransportError.channelFailed(detail: "prompt refused")
            }
            return Agent(AgentInfo(
                agentStatus: .idle, focused: false, paneID: params.target,
                revision: 1, tabID: "t", terminalID: "term",
                workspaceID: "w"))
        }

        func restartAgent(
            paneID: String, kind: String, name: String, arguments: [String]
        ) async throws -> Agent {
            restarts.append((paneID, arguments))
            return Agent(AgentInfo(
                agentStatus: AgentStatus.idle, focused: false, paneID: paneID,
                revision: 1, tabID: "t", terminalID: "term", workspaceID: "w"))
        }

        func ping() async throws -> ServerInfo {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func listAgents() async throws -> [Agent] { [] }
        func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
            throw TransportError.channelFailed(detail: "not scripted")
        }
        func sendAgentKeys(_ params: AgentSendKeysParams) async throws {}
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
        func closePane(_ params: PaneTarget) async throws {}
        func focusAgent(_ target: AgentTarget) async throws {}
        func renameAgent(_ params: AgentRenameParams) async throws {}
        func renameWorkspace(_ params: WorkspaceRenameParams) async throws {}
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
        var isConnected: Bool { true }
        func close() async throws {}
    }

    private final actor ConnectingConnector: TransportConnector {
        let transport: FlowTransport
        init(transport: FlowTransport) { self.transport = transport }
        func connect(settings: SSHTransportSettings) async throws -> any Transport {
            transport
        }
    }

    /// A scripted package source: no bundle dependency.
    private struct ScriptedPackageSource: MeadowPackageSource {
        let package: MeadowPackage?
        func package(for platform: RemoteHostPlatform?) async throws -> MeadowPackage? {
            package
        }
    }

    // MARK: - Fixtures

    private func makeHost() throws -> Host {
        var host = Host.fixture()
        host.brokerChatSocketPath = ""
        return host
    }

    private func makePackage() throws -> MeadowPackage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meadow-flow-\(UUID().uuidString).targz")
        let bytes = Data("flow-package".utf8)
        try bytes.write(to: url)
        return MeadowPackage(
            version: "0.1.0-dev.3",
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            prepared: PreparedFile(
                fileURL: url, fileExtension: "targz", byteCount: Int64(bytes.count)))
    }

    /// Scripts every command the detect+provision path issues, against a
    /// development layout (disposable roots).
    private func scriptProvisionPath(
        transport: FlowTransport
    ) async throws {
        // The remote post-staging checksum verification must answer "ok".
        let layout = BrokerProvisioningLayout.standard(
            platform: .linux, homeDirectory: "/home/dev")
        let packageBytes = Data("flow-package".utf8)
        let sha = SHA256.hash(data: packageBytes).map { String(format: "%02x", $0) }.joined()
        await transport.addScript(
            try layout.remoteChecksumCommand(
                path: "/remote/staging/file.targz", expectedSHA256: sha),
            stdout: "ok")
        // Platform probe.
        await transport.addScript(
            "printf '%s\\n%s\\n' \"$(uname)\" \"${HOME:-\"\"}\"",
            stdout: "Linux\n/home/dev")
        // Inspect answers: nothing installed, prerequisites satisfied.
        // (`layout` declared at the top of this helper.)
        await transport.queueScript(
            layout.inspectCommand,
            stdout: inspectAnswer(version: nil, service: "inactive"))
        await transport.queueScript(layout.readAdapterShimCommand, stdout: "")
        // Post-install refresh-inspect: installed, service active, shim
        // present. QUEUED (not static) so the second run of the same
        // command sees the post-install state while detect's run saw
        // the pre-install one. Enable's own refresh inspect needs a
        // THIRD answer (the queue replays in order).
        await transport.queueScript(
            layout.inspectCommand,
            stdout: inspectAnswer(version: "0.1.0-dev.3", service: "active"))
        await transport.queueScript(
            layout.readAdapterShimCommand,
            stdout: "// Managed by Heeler. Replaces the broker-adapter extension shim.")
        await transport.queueScript(
            layout.inspectCommand,
            stdout: inspectAnswer(version: "0.1.0-dev.3", service: "active"))
        await transport.queueScript(
            layout.readAdapterShimCommand,
            stdout: "// Managed by Heeler. Replaces the broker-adapter extension shim.")
        // configureAdapter's refresh inspect (third re-run of the flow).
        await transport.queueScript(
            layout.inspectCommand,
            stdout: inspectAnswer(version: "0.1.0-dev.3", service: "active"))
        await transport.queueScript(
            layout.readAdapterShimCommand,
            stdout: "// Managed by Heeler. Replaces the broker-adapter extension shim.")
        // Socket resolution.
        await transport.addScript(
            "printf '%s' \"${XDG_DATA_HOME:-$HOME/.local/share}/meadow/broker.sock\"",
            stdout: "/home/dev/.local/share/meadow/broker.sock")
    }

    private func inspectAnswer(version: String?, service: String) -> String {
        [
            "platform=Linux", "home=/home/dev", "node=v26.8.1", "omp=present",
            "installed=\(version == nil ? "absent" : "present")",
            "version=\(version ?? "")", "socket=\(service == "active" ? "present" : "absent")",
            "service=\(service)",
        ].joined(separator: "\n")
    }

    private func agentInfo(
        paneID: String,
        sessionFile: String?
    ) -> AgentInfo {
        AgentInfo(
            agentStatus: AgentStatus.idle, focused: false, paneID: paneID,
            revision: 1, tabID: "t1", terminalID: "term-\(paneID)",
            workspaceID: "w1",
            agent: "omp",
            agentSession: sessionFile.map {
                AgentSessionInfo(
                    agent: "omp", kind: AgentSessionRefKind.path,
                    source: "herdr:omp", value: $0)
            },
            terminalTitle: "π > \(paneID) work",
            terminalTitleStripped: "π > \(paneID) work")
    }

    // MARK: - Flow tests

    @Test func detectOnUnprovisionedHostOffersSetup() async throws {
        let transport = FlowTransport()
        let host = try makeHost()
        let store = MeadowFirstConnectProvisioningStore(
            host: host,
            connector: ConnectingConnector(transport: transport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(
                defaults: try #require(UserDefaults(suiteName: "mfc-\(UUID().uuidString)")),
                hostID: host.id))
        try await scriptProvisionPath(transport: transport)

        await store.detect()

        #expect(store.phase == .offering)
        #expect(store.provisioning != nil)
        // Detect is read-only: no mutations ran.
        let commands = await transport.commands
        #expect(!commands.contains { $0.contains("mkdir -p") })
        #expect(!commands.contains { $0.contains("tar -xzf") })
    }

    @Test func detectOnFullyProvisionedHostSkipsOffer() async throws {
        let transport = FlowTransport()
        var host = try makeHost()
        host.brokerChatSocketPath = "/home/dev/.local/share/meadow/broker.sock"
        let store = MeadowFirstConnectProvisioningStore(
            host: host,
            connector: ConnectingConnector(transport: transport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(
                defaults: try #require(UserDefaults(suiteName: "mfc-\(UUID().uuidString)")),
                hostID: host.id))
        let layout = BrokerProvisioningLayout.standard(
            platform: .linux, homeDirectory: "/home/dev")
        await transport.addScript(
            "printf '%s\\n%s\\n' \"$(uname)\" \"${HOME:-\"\"}\"",
            stdout: "Linux\n/home/dev")
        await transport.addScript(
            layout.inspectCommand,
            stdout: inspectAnswer(version: "0.1.0-dev.3", service: "active"))
        await transport.addScript(
            layout.readAdapterShimCommand,
            stdout: "// Managed by Heeler. Replaces the broker-adapter extension shim.")

        await store.detect()

        #expect(store.phase == .done)
    }

    @Test func provisionInstallsEnablesShimsAndLandsOnRestartDecision() async throws {
        let transport = FlowTransport()
        let host = try makeHost()
        let store = MeadowFirstConnectProvisioningStore(
            host: host,
            connector: ConnectingConnector(transport: transport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(
                defaults: try #require(UserDefaults(suiteName: "mfc-\(UUID().uuidString)")),
                hostID: host.id),
            packageSource: ScriptedPackageSource(package: try makePackage()))
        try await scriptProvisionPath(transport: transport)
        await transport.setSnapshotAgents([
            agentInfo(
                paneID: "w1:pA",
                sessionFile: "/x/2026-01-01T00-00-00Z_01a0c4ef-6a8b-7169-86cf-265306ac7319.jsonl"),
            agentInfo(paneID: "w1:pB", sessionFile: nil),
        ])

        await store.detect()
        await store.provision()

        guard case .restartDecision(let agents) = store.phase else {
            Issue.record("expected restartDecision, got \(store.phase)")
            return
        }
        #expect(agents.count == 2)
        // Bounded indexing: a smaller-than-expected list must FAIL the
        // expectation, never crash the process out from under the suite.
        #expect(agents.first?.resumeSessionID == "01a0c4ef-6a8b-7169-86cf-265306ac7319")
        #expect(agents.dropFirst().first?.resumeSessionID == nil)
        #expect(store.resolvedSocketPath == "/home/dev/.local/share/meadow/broker.sock")
        // The provisioning sequence ran: staging, checksum, extract,
        // promote, unit write, enable, shim write.
        let commands = await transport.commands
        #expect(commands.contains { $0.contains("tar -xzf") })
        #expect(commands.contains { $0.contains("systemctl --user enable --now") })
        #expect(commands.contains { $0.contains("extensions/meadow-chat.ts") })
    }

    @Test func skipRestartsKeepsBrokerAndCompletesWithoutRestarting() async throws {
        let transport = FlowTransport()
        let host = try makeHost()
        let store = MeadowFirstConnectProvisioningStore(
            host: host,
            connector: ConnectingConnector(transport: transport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(
                defaults: try #require(UserDefaults(suiteName: "mfc-\(UUID().uuidString)")),
                hostID: host.id),
            packageSource: ScriptedPackageSource(package: try makePackage()))
        try await scriptProvisionPath(transport: transport)
        await transport.setSnapshotAgents([agentInfo(paneID: "w1:pA", sessionFile: nil)])

        await store.detect()
        await store.provision()
        store.skipRestarts()

        #expect(store.phase == .done)
        // Hard requirement: cancel means NOTHING restarted.
        let restarts = await transport.restarts
        let prompts = await transport.prompts
        #expect(restarts.isEmpty)
        #expect(prompts.isEmpty)
    }

    @Test func confirmedRestartExitsEachAgentThenResumesInItsPane() async throws {
        let transport = FlowTransport()
        let host = try makeHost()
        let store = MeadowFirstConnectProvisioningStore(
            host: host,
            connector: ConnectingConnector(transport: transport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(
                defaults: try #require(UserDefaults(suiteName: "mfc-\(UUID().uuidString)")),
                hostID: host.id),
            packageSource: ScriptedPackageSource(package: try makePackage()))
        try await scriptProvisionPath(transport: transport)
        await transport.setSnapshotAgents([
            agentInfo(
                paneID: "w1:pA",
                sessionFile: "/x/2026-01-01T00-00-00Z_01a0c4ef-6a8b-7169-86cf-265306ac7319.jsonl"),
        ])

        await store.detect()
        await store.provision()
        await store.restartConfirmedAgents()

        #expect(store.phase == .done)
        // Exit prompt then same-pane resume with the session id.
        let prompts = await transport.prompts
        #expect(prompts.count == 1)
        #expect(prompts.first?.text == "/exit")
        #expect(prompts.first?.target == "w1:pA")
        let restarts = await transport.restarts
        #expect(restarts.count == 1)
        #expect(restarts.first?.paneID == "w1:pA")
        #expect(
            restarts.first?.arguments
                == ["--resume", "01a0c4ef-6a8b-7169-86cf-265306ac7319"])
    }

    @Test func provisionFailureSurfacesMessageAndStops() async throws {
        let transport = FlowTransport()
        let host = try makeHost()
        let store = MeadowFirstConnectProvisioningStore(
            host: host,
            connector: ConnectingConnector(transport: transport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(
                defaults: try #require(UserDefaults(suiteName: "mfc-\(UUID().uuidString)")),
                hostID: host.id),
            // No package for the platform: the flow must fail honestly
            // before any remote mutation.
            packageSource: ScriptedPackageSource(package: nil))
        try await scriptProvisionPath(transport: transport)

        await store.detect()
        await store.provision()

        guard case .failed(let message) = store.phase else {
            Issue.record("expected failed, got \(store.phase)")
            return
        }
        #expect(message.contains("no broker package"))
        let commands = await transport.commands
        #expect(!commands.contains { $0.contains("tar -xzf") })
    }

    // MARK: - Helpers

    @Test func resumeSessionIDExtractsUUIDFromTranscriptBasename() {
        let session = AgentSessionInfo(
            agent: "omp", kind: .path, source: "herdr:omp",
            value: "/h/.omp/agent/sessions/-src/2026-09-21T17-08-48-512Z_01a0c4f1-1300-70f7-9ffd-8db61643f390.jsonl")
        #expect(
            MeadowFirstConnectProvisioningStore.resumeSessionID(from: session)
                == "01a0c4f1-1300-70f7-9ffd-8db61643f390")
        #expect(MeadowFirstConnectProvisioningStore.resumeSessionID(from: nil) == nil)
        // Non-transcript refs resume bare.
        let weird = AgentSessionInfo(
            agent: "omp", kind: .path, source: "herdr:omp", value: "not-a-file")
        #expect(MeadowFirstConnectProvisioningStore.resumeSessionID(from: weird) == nil)
    }
}
