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
    /// Scripted broker probe for the flow's tests. `answers` replays in
    /// call order (detect's probe, then provision's post-setup
    /// re-probe): a host that comes UP when setup runs answers
    /// [false, true].
    private func scriptedProbe(answers: [Bool]) -> @Sendable (String, (any Transport)?) async -> Bool {
        let box = ProbeAnswers(answers: answers)
        return { _, _ in await box.next() }
    }

    /// Same answer every call.
    private func scriptedProbe(up: Bool) -> @Sendable (String, (any Transport)?) async -> Bool {
        scriptedProbe(answers: [up])
    }

    private final actor ProbeAnswers {
        private var answers: [Bool]
        init(answers: [Bool]) { self.answers = answers }
        func next() -> Bool {
            let first = answers.first ?? (answers.last ?? false)
            if answers.count > 1 { answers.removeFirst() }
            return first
        }
    }

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

    /// A connector whose transport IS an HeelerSSHTransport double the
    /// broker-probe path accepts, with a scriptable up/down answer.
    private final class ProbingConnector: TransportConnector {
        let transport: FlowTransport
        let brokerUp: Bool
        init(transport: FlowTransport, brokerUp: Bool) {
            self.transport = transport
            self.brokerUp = brokerUp
        }
        func connect(settings: SSHTransportSettings) async throws -> any Transport {
            transport
        }
    }

    /// A scripted package source: no bundle dependency.
    // MARK: - Fixtures

    private func makeHost() throws -> Host {
        var host = Host.fixture()
        host.brokerChatSocketPath = ""
        return host
    }


    /// Scripts every command the detect+provision path issues, against a
    /// development layout (disposable roots).
    /// Scripts the plugin-era detect+provision path: the socket
    /// resolution command (issued by detect and again by provision) and
    /// the plugin setup action.
    private func scriptProvisionPath(
        transport: FlowTransport
    ) async throws {
        // The resolution command runs TWICE (detect, then provision's
        // post-setup re-resolve): queue both answers.
        await transport.queueScript(
            "printf '%s' \"${XDG_DATA_HOME:-$HOME/.local/share}/meadow/broker.sock\"",
            stdout: "/home/dev/.local/share/meadow/broker.sock")
        await transport.queueScript(
            "printf '%s' \"${XDG_DATA_HOME:-$HOME/.local/share}/meadow/broker.sock\"",
            stdout: "/home/dev/.local/share/meadow/broker.sock")
        await transport.addScript(
            "herdr plugin action invoke heeler.setup",
            stdout: "M Meadow broker  up")
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
            catalog: nil,
            connector: ConnectingConnector(transport: transport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(
                defaults: try #require(UserDefaults(suiteName: "mfc-\(UUID().uuidString)")),
                hostID: host.id),
            brokerProbe: scriptedProbe(up: false))
        try await scriptProvisionPath(transport: transport)

        await store.detect()

        #expect(store.phase == .offering)
        // Detect is read-only: no setup action ran, no records written.
        let commands = await transport.commands
        #expect(!commands.contains { $0.contains("heeler.setup") })
    }

    @Test func detectWithLiveBrokerWritesRecordAndSkipsOffer() async throws {
        // Plugin-era: a broker answering at the standard path (probe via
        // an SSH transport double) writes the record and lands on .done.
        let transport = FlowTransport()
        let host = try makeHost()
        let store = MeadowFirstConnectProvisioningStore(
            host: host,
            catalog: nil,
            connector: ProbingConnector(transport: transport, brokerUp: true),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(
                defaults: try #require(UserDefaults(suiteName: "mfc-\(UUID().uuidString)")),
                hostID: host.id),
            brokerProbe: scriptedProbe(answers: [true]))
        await transport.queueScript(
            "printf '%s' \"${XDG_DATA_HOME:-$HOME/.local/share}/meadow/broker.sock\"",
            stdout: "/home/dev/.local/share/meadow/broker.sock")

        await store.detect()

        #expect(store.phase == .done)
        #expect(store.resolvedSocketPath == "/home/dev/.local/share/meadow/broker.sock")
    }

    @Test func provisionInstallsEnablesShimsAndLandsOnRestartDecision() async throws {
        let transport = FlowTransport()
        let host = try makeHost()
        let store = MeadowFirstConnectProvisioningStore(
            host: host,
            catalog: nil,
            connector: ConnectingConnector(transport: transport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(
                defaults: try #require(UserDefaults(suiteName: "mfc-\(UUID().uuidString)")),
                hostID: host.id),
            brokerProbe: scriptedProbe(answers: [false, true]))
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
        // The plugin's setup action ran — the ONE coherent bring-up
        // surface. No app-side install commands exist in the flow.
        let commands = await transport.commands
        #expect(commands.contains { $0.contains("herdr plugin action invoke heeler.setup") })
        #expect(!commands.contains { $0.contains("tar -xzf") })
    }

    @Test func skipRestartsKeepsBrokerAndCompletesWithoutRestarting() async throws {
        let transport = FlowTransport()
        let host = try makeHost()
        let store = MeadowFirstConnectProvisioningStore(
            host: host,
            catalog: nil,
            connector: ConnectingConnector(transport: transport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(
                defaults: try #require(UserDefaults(suiteName: "mfc-\(UUID().uuidString)")),
                hostID: host.id),
            brokerProbe: scriptedProbe(answers: [false, true]))
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
            catalog: nil,
            connector: ConnectingConnector(transport: transport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(
                defaults: try #require(UserDefaults(suiteName: "mfc-\(UUID().uuidString)")),
                hostID: host.id),
            brokerProbe: scriptedProbe(answers: [false, true]))
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
            catalog: nil,
            connector: ConnectingConnector(transport: transport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            preferredAddresses: PreferredAddressStore(
                defaults: try #require(UserDefaults(suiteName: "mfc-\(UUID().uuidString)")),
                hostID: host.id),
            brokerProbe: scriptedProbe(up: false))
        // The plugin's setup action FAILS (nonzero exit): the flow must
        // surface the honest failure and write nothing.
        await transport.queueScript(
            "printf '%s' \"${XDG_DATA_HOME:-$HOME/.local/share}/meadow/broker.sock\"",
            stdout: "/home/dev/.local/share/meadow/broker.sock")
        await transport.addScript(
            "herdr plugin action invoke heeler.setup",
            stdout: "plugin missing", exit: 1)

        await store.detect()
        await store.provision()

        guard case .failed(let message) = store.phase else {
            Issue.record("expected failed, got \(store.phase)")
            return
        }
        #expect(message.contains("heeler.setup exited 1"))
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
