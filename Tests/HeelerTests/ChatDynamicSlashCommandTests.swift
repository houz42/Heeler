import Foundation
import os
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The composer's dynamic slash-command discovery (fork plan, Phase 3
// continuation): omp's on-disk `skill:` and per-project `file` sources,
// enumerated over the SFTP seam. Everything here is network-free — the
// seam is scripted with in-memory dictionaries and thrown errors,
// mirroring the ChatTranscriptReader tests. The rules under test are
// omp's own (extensibility/skills.ts, discovery/helpers.ts,
// slash-commands/available-commands.ts, verified 2026-09): gate key,
// SKILL.md frontmatter → `skill:<name>`, filename stem → file command,
// menu merge order, and the silent degrade.

// MARK: - Test seam

/// A scripted Host filesystem for the discovery seam: directory listings
/// keyed by path, file contents keyed by path, and optional failure
/// injections. Thread-safe because the seam closures hop isolation.
private final class ScriptedHost: @unchecked Sendable {
    struct Failure: Error, Equatable {
        let path: String
    }

    private let lock = NSLock()
    private var directories: [String: RemoteDirectoryContents]
    private var files: [String: Data]
    private var failingPaths: Set<String>
    private(set) var listedPaths: [String] = []
    private(set) var readPaths: [String] = []
    let home = "/home/tester"

    init(
        directories: [String: [(name: String, isDirectory: Bool)]] = [:],
        files: [String: String] = [:],
        failingPaths: Set<String> = []
    ) {
        var listings: [String: RemoteDirectoryContents] = [:]
        for (path, entries) in directories {
            listings[path] = RemoteDirectoryContents(
                entries: entries.map {
                    RemoteDirectoryEntry(name: $0.name, isDirectory: $0.isDirectory)
                },
                truncated: false)
        }
        self.directories = listings
        self.files = files.mapValues { Data($0.utf8) }
        self.failingPaths = failingPaths
    }

    var io: AgentCommandFileIO {
        let host = self
        return AgentCommandFileIO(
            listDirectory: { path in
                try host.list(path)
            },
            readFileHead: { path, maxLength in
                try host.read(path, maxLength: maxLength)
            },
            homeDirectory: { host.home })
    }

    private func list(_ path: String) throws -> RemoteDirectoryContents {
        lock.lock()
        defer { lock.unlock() }
        listedPaths.append(path)
        if failingPaths.contains(path) { throw Failure(path: path) }
        guard let contents = directories[path] else {
            throw Failure(path: path)
        }
        return contents
    }

    private func read(_ path: String, maxLength: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        readPaths.append(path)
        if failingPaths.contains(path) { throw Failure(path: path) }
        guard let data = files[path] else {
            throw Failure(path: path)
        }
        return data.prefix(maxLength)
    }
}

private let discoveryLog = Logger(
    subsystem: "dev.bybee.heeler.tests", category: "AgentCommands")

private func discover(
    _ host: ScriptedHost, cwd: String = "/home/tester/project"
) async -> [AgentSlashCommand] {
    await OmpHostCommandDiscovery.commands(cwd: cwd, io: host.io, log: discoveryLog)
}

// MARK: - Config gate

@Suite("Skill command config gate")
struct ChatDynamicSlashGateTests {
    @Test func absentKeyDefaultsToOmpSchemaDefaultEnabled() {
        // omp's settings schema carries default: true for
        // skills.enableSkillCommands (verified against the 18.2.3
        // binary and upstream settings-schema.ts); an absent key
        // must not hide the agent's own skill commands.
        #expect(OmpHostCommandDiscovery.skillCommandsEnabled(
            inConfigYaml: "theme:\n  dark: x\n") == true)
        #expect(OmpHostCommandDiscovery.skillCommandsEnabled(inConfigYaml: nil) == true)
        #expect(OmpHostCommandDiscovery.skillCommandsEnabled(inConfigYaml: "") == true)
    }

    @Test func explicitBooleanSpellingsAreHonoured() {
        #expect(OmpHostCommandDiscovery.skillCommandsEnabled(
            inConfigYaml: "skills:\n  enableSkillCommands: false\n") == false)
        #expect(OmpHostCommandDiscovery.skillCommandsEnabled(
            inConfigYaml: "skills:\n  enableSkillCommands: true\n") == true)
        #expect(OmpHostCommandDiscovery.skillCommandsEnabled(
            inConfigYaml: "  enableSkillCommands:   false  ") == false)
        #expect(OmpHostCommandDiscovery.skillCommandsEnabled(
            inConfigYaml: "enableSkillCommands: off\n") == false)
        #expect(OmpHostCommandDiscovery.skillCommandsEnabled(
            inConfigYaml: "enableSkillCommands: on\n") == true)
    }

    @Test func unrelatedKeysWithSimilarNamesDoNotTripTheGate() {
        #expect(OmpHostCommandDiscovery.skillCommandsEnabled(
            inConfigYaml: "enableSkillCommandsBackup: false\n") == true)
        #expect(OmpHostCommandDiscovery.skillCommandsEnabled(
            inConfigYaml: "other.enableSkillCommands: false\n") == true)
    }

    @Test func unrecognizedValueFallsBackToDefault() {
        #expect(OmpHostCommandDiscovery.skillCommandsEnabled(
            inConfigYaml: "enableSkillCommands: maybe\n") == true)
    }

    @Test func unreadableConfigDegradesToDefaultEnabledOverTheSeam() async {
        // The config file is absent from the Host: the gate read
        // throws, the default (enabled) applies, and the skills
        // listing still runs — proving the failure does not silently
        // disarm discovery.
        let host = ScriptedHost(
            directories: ["/home/tester/.agents/skills": [("alpha", true)]],
            files: [
                "/home/tester/.agents/skills/alpha/SKILL.md":
                    "---\nname: alpha\ndescription: Alpha skill\n---\n",
            ])
        let commands = await discover(host)
        #expect(commands.map(\.name) == ["skill:alpha"])
        #expect(host.listedPaths.contains("/home/tester/.agents/skills"))
    }
}

// MARK: - Skill parsing

@Suite("SKILL.md frontmatter → skill command")
struct ChatDynamicSlashSkillTests {
    @Test func frontmatterNameAndDescriptionProduceSkillCommand() {
        let command = OmpHostCommandDiscovery.skillCommand(
            directoryName: "my-dir",
            fileHead: """
            ---
            name: code-review
            description: Review the current diff
            ---
            # Body
            """)
        #expect(command?.name == "skill:code-review")
        #expect(command?.summary == "Review the current diff")
        #expect(command?.usage == "arguments")
        #expect(command?.source == .skillFile)
    }

    @Test func missingFrontmatterNameFallsBackToDirectoryName() {
        let command = OmpHostCommandDiscovery.skillCommand(
            directoryName: "pdf-tools",
            fileHead: "---\ndescription: Fill PDFs\n---\n")
        #expect(command?.name == "skill:pdf-tools")
    }

    @Test func missingDescriptionDropsTheSkill() {
        // omp's agents/omp providers load skills with
        // requireDescription: true — no description, no skill.
        let command = OmpHostCommandDiscovery.skillCommand(
            directoryName: "silent",
            fileHead: "---\nname: silent\n---\nBody only.")
        #expect(command == nil)
    }

    @Test func enabledFalseDropsTheSkill() {
        let command = OmpHostCommandDiscovery.skillCommand(
            directoryName: "off",
            fileHead: """
            ---
            name: off
            description: Should not register
            enabled: false
            ---
            """)
        #expect(command == nil)
    }

    @Test func unsafeNameDropsTheSkill() {
        // A name that cannot survive as one insertable word would
        // produce a suggestion the agent cannot parse.
        let spaced = OmpHostCommandDiscovery.skillCommand(
            directoryName: "dir",
            fileHead: "name: has space\ndescription: d\n")
        #expect(spaced == nil)
    }

    @Test func listingDotEntriesAndFilesAreNotSkillCandidates() {
        let names = OmpHostCommandDiscovery.skillCandidateNames(
            fromListing: RemoteDirectoryContents(
                entries: [
                    RemoteDirectoryEntry(name: "real-skill", isDirectory: true),
                    RemoteDirectoryEntry(name: ".hidden", isDirectory: true),
                    RemoteDirectoryEntry(name: "stray.md", isDirectory: false),
                ],
                truncated: false))
        #expect(names == ["real-skill"])
    }
}

// MARK: - File command parsing

@Suite("Command file → file command")
struct ChatDynamicSlashFileCommandTests {
    @Test func filenameStemIsTheCommandName() {
        let command = OmpHostCommandDiscovery.fileCommand(
            filename: "deploy.md",
            fileHead: "Deploy the app to production.\n")
        #expect(command?.name == "deploy")
        #expect(command?.summary == "Deploy the app to production.")
        #expect(command?.source == .commandFile)
    }

    @Test func nonMarkdownEntriesAreIgnored() {
        #expect(OmpHostCommandDiscovery.fileCommand(
            filename: "notes.txt", fileHead: "x") == nil)
        #expect(OmpHostCommandDiscovery.fileCommand(
            filename: ".hidden.md", fileHead: "x") == nil)
    }

    @Test func frontmatterDescriptionWinsOverFirstLine() {
        let command = OmpHostCommandDiscovery.fileCommand(
            filename: "triage.md",
            fileHead: """
            ---
            description: Triage incoming issues
            argument-hint: [query]
            ---
            Some body text that must not become the summary.
            """)
        #expect(command?.summary == "Triage incoming issues")
    }

    @Test func firstContentLineFallsBackWhenNoFrontmatterDescription() {
        let command = OmpHostCommandDiscovery.fileCommand(
            filename: "ship.md",
            fileHead: "# Heading is the first line\n\nBody.\n")
        #expect(command?.summary == "# Heading is the first line")
    }

    @Test func longFirstLineIsCappedAtSixtyCharacters() {
        let long = String(repeating: "a", count: 80)
        let command = OmpHostCommandDiscovery.fileCommand(
            filename: "long.md", fileHead: long + "\n")
        #expect(command?.summary?.count == 63)
        #expect(command?.summary?.hasSuffix("...") == true)
    }

    @Test func walkUpDirectoriesAreBoundedAndNearestFirst() {
        let directories = OmpHostCommandDiscovery.commandDirectories(
            fromCwd: "/home/tester/work/repo/packages/app")
        // Nearest level first, .omp before .agents within a level.
        #expect(directories.first
            == "/home/tester/work/repo/packages/app/.omp/commands")
        #expect(directories.count
            == OmpHostCommandDiscovery.maximumWalkUpLevels
                * OmpHostCommandDiscovery.commandDirectoryNames.count)
        // The walk-up stops at the cap, never escaping to `/`.
        #expect(!directories.contains("/.omp/commands"))
    }

    @Test func relativeOrEmptyCwdYieldsNoCommandDirectories() {
        #expect(OmpHostCommandDiscovery.commandDirectories(fromCwd: "").isEmpty)
        #expect(OmpHostCommandDiscovery.commandDirectories(fromCwd: "relative").isEmpty)
        #expect(OmpHostCommandDiscovery.commandDirectories(fromCwd: "~/x").isEmpty)
    }
}

// MARK: - Merge order + degrade

@Suite("Discovery over the seam: merge order, gate, degrade")
struct ChatDynamicSlashDiscoveryTests {
    private func makeHost() -> ScriptedHost {
        ScriptedHost(
            directories: [
                "/home/tester/.agents/skills": [
                    ("alpha", true),
                    ("beta", true),
                    ("not-a-skill", false),
                    (".git", true),
                ],
                "/home/tester/project/.omp/commands": [
                    ("deploy.md", false),
                    ("level.md", false),
                    ("ignore.txt", false),
                ],
                "/home/tester/project/.agents/commands": [
                    ("agents-review.md", false),
                ],
            ],
            files: [
                "/home/tester/.omp/agent/config.yml":
                    "skills:\n  enableSkillCommands: true\n",
                "/home/tester/.agents/skills/alpha/SKILL.md":
                    "---\nname: alpha\ndescription: The alpha skill\n---\n",
                "/home/tester/.agents/skills/beta/SKILL.md":
                    "---\ndescription: Beta skill without a frontmatter name\n---\n",
                "/home/tester/project/.omp/commands/deploy.md":
                    "---\ndescription: Deploy the project\n---\nBody",
                // Same name as a client-local command — the router
                // still lists its own local commands; this entry tests
                // that discovery itself does not special-case it.
                "/home/tester/project/.omp/commands/level.md":
                    "A file command shadow-named like a local command.\n",
                "/home/tester/project/.agents/commands/agents-review.md":
                    "Review agents.\n",
            ])
    }

    @Test func skillsSortBeforeFileCommandsAndGateAdmitsThem() async {
        let commands = await discover(makeHost())
        let names = commands.map(\.name)
        #expect(names.first == "skill:alpha")
        #expect(names.contains("skill:beta"))
        #expect(names.contains("deploy"))
        #expect(names.contains("agents-review"))
        // Menu order: every skill: command precedes every file command.
        let firstFile = names.firstIndex { !$0.hasPrefix("skill:") }
        if let firstFile {
            #expect(names[..<firstFile].allSatisfy { $0.hasPrefix("skill:") })
        }
        // The stray file and dot-directory in the skills root are not
        // treated as skills.
        #expect(!names.contains("skill:not-a-skill"))
        #expect(!names.contains("skill:.git"))
    }

    @Test func gateOffHidesSkillCommandsButKeepsFileCommands() async {
        let host = ScriptedHost(
            directories: [
                "/home/tester/.agents/skills": [("alpha", true)],
                "/home/tester/project/.omp/commands": [("deploy.md", false)],
            ],
            files: [
                "/home/tester/.omp/agent/config.yml":
                    "skills:\n  enableSkillCommands: false\n",
                "/home/tester/.agents/skills/alpha/SKILL.md":
                    "---\nname: alpha\ndescription: Hidden by the gate\n---\n",
                "/home/tester/project/.omp/commands/deploy.md": "Deploy.\n",
            ])
        let commands = await discover(host)
        #expect(!commands.map(\.name).contains("skill:alpha"))
        #expect(commands.map(\.name).contains("deploy"))
        // The gated skills directory is not even listed.
        #expect(!host.listedPaths.contains("/home/tester/.agents/skills"))
    }

    @Test func listingFailureDegradesToEmptyNotError() async {
        let host = ScriptedHost(
            directories: [:],
            files: [:],
            failingPaths: [
                "/home/tester/.agents/skills",
                "/home/tester/.omp/agent/config.yml",
            ])
        let commands = await discover(host)
        #expect(commands.isEmpty)
    }

    @Test func partialFailureKeepsTheRest() async {
        // One unreadable SKILL.md must not drop its siblings; one
        // missing command dir must not drop the others.
        let host = ScriptedHost(
            directories: [
                "/home/tester/.agents/skills": [
                    ("good", true),
                    ("bad", true),
                ],
                "/home/tester/project/.omp/commands": [("deploy.md", false)],
            ],
            files: [
                "/home/tester/.agents/skills/good/SKILL.md":
                    "---\nname: good\ndescription: Good skill\n---\n",
                "/home/tester/project/.omp/commands/deploy.md": "Deploy.\n",
            ],
            failingPaths: [
                "/home/tester/.agents/skills/bad/SKILL.md",
            ])
        let names = Set(await discover(host).map(\.name))
        #expect(names.contains("skill:good"))
        #expect(!names.contains("skill:bad"))
        #expect(names.contains("deploy"))
    }
}

// MARK: - Menu merge with the builtin table

@Suite("Menu merge: builtin → skill → file → local")
struct ChatDynamicSlashMergeTests {
    @Test func builtinShadowsDiscoveredDuplicates() async {
        // A file command named like a builtin (compact) must be dropped
        // by the store's merge: omp's menu dedupes first-wins.
        let host = ScriptedHost(
            directories: [
                "/home/tester/project/.omp/commands": [("compact.md", false)],
            ],
            files: [
                "/home/tester/project/.omp/commands/compact.md":
                    "A shadow-named file command.\n",
            ])
        let store = AgentDynamicCommandStore()
        let hostID = UUID()
        await store.refresh(
            hostID: hostID,
            paneID: "p1",
            kind: "omp",
            cwd: "/home/tester/project",
            io: host.io)
        let merged = await store.cachedCommands(hostID: hostID, paneID: "p1")
        let compacts = merged.filter { $0.name == "compact" }
        #expect(compacts.count == 1)
        #expect(compacts.first?.source == .builtinTable)
    }

    @Test func suggestionsListDiscoveredCommandsWithTheirPrefixes() async {
        let host = ScriptedHost(
            directories: [
                "/home/tester/.agents/skills": [("alpha", true)],
                "/home/tester/project/.omp/commands": [("deploy.md", false)],
            ],
            files: [
                "/home/tester/.agents/skills/alpha/SKILL.md":
                    "---\nname: alpha\ndescription: The alpha skill\n---\n",
                "/home/tester/project/.omp/commands/deploy.md": "Deploy.\n",
            ])
        let store = AgentDynamicCommandStore()
        let hostID = UUID()
        await store.refresh(
            hostID: hostID, paneID: "p1", kind: "omp",
            cwd: "/home/tester/project", io: host.io)
        let suggestions = ComposerRouter.slashSuggestions(
            matching: "",
            agentCommands: await store.cachedCommands(
                hostID: hostID, paneID: "p1"))
        let titles = suggestions.map(\.title)
        #expect(titles.contains("skill:alpha"))
        #expect(titles.contains("deploy"))
        // The insertion for a skill carries its `skill:` prefix — the
        // text the agent parses.
        let alpha = suggestions.first { $0.title == "skill:alpha" }
        #expect(alpha?.insertion == "/skill:alpha ")
        #expect(alpha?.detail == "The alpha skill")
    }
}
