import Foundation
import os

// SPDX-License-Identifier: Apache-2.0
//
// Host-scoped slash-command discovery for the Composer's suggestion menu
// (fork plan, Phase 3 continuation). omp builds its per-session `/` menu
// from six sources (builtin, skill, extension, custom, mcp_prompt, file);
// no runtime RPC exposes that list for a TUI agent (see
// `AgentCommandProvider`'s header), but two of the sources are plain
// files on the Host and enumerate honestly over the existing SFTP read
// path:
//
//   skill  — `~/.agents/skills/<name>/SKILL.md` → `/skill:<name>`, gated
//            by omp's `skills.enableSkillCommands` config key
//   file   — per-project `<dir>/commands/*.md` (`|.omp|.agents|.claude|
//            .codex`), walking up from the agent's cwd
//
// Extension, custom, and mcp_prompt commands have no on-disk surface and
// stay out of the menu — the agent still answers them if typed raw.
// Suggestions only; delivery is always the raw text through
// `agent.prompt`, so an omp that lacks a discovered command answers
// honestly on its own.
//
// Every SFTP failure degrades silently to whatever was already cached
// (initially nothing) — the menu then shows the static builtin table only
// — with a log line, never a user-facing error: command discovery is a
// suggestion surface, not a load-bearing read.

/// The Host-side I/O the discovery needs, as closures over the Console's
/// live connection (mirroring `ChatTranscriptReader`): production wires
/// `AgentCommandFileIO.console(_:hostID:)`, tests script in-memory
/// dictionaries and thrown errors.
struct AgentCommandFileIO: Sendable {
    /// Lists one absolute remote directory's full contents (files and
    /// subdirectories, dot-entries excluded). A missing directory throws.
    let listDirectory:
        @Sendable (_ path: String) async throws -> RemoteDirectoryContents
    /// Reads up to `maxLength` bytes from the head of one remote file.
    /// A missing file throws (the SFTP ranged read's rule); short files
    /// return what is there.
    let readFileHead:
        @Sendable (_ path: String, _ maxLength: Int) async throws -> Data
    /// The Host's remote home directory, absolute POSIX.
    let homeDirectory: @Sendable () async throws -> String

    /// The production seam over a ConsoleStore's live Host connection:
    /// the directory-browser listing, the transcript chunk read (an
    /// absolute-path SFTP read — the transcript name is historical), and
    /// the remote-home probe.
    @MainActor
    static func console(_ console: ConsoleStore, hostID: Host.ID) -> AgentCommandFileIO {
        AgentCommandFileIO(
            listDirectory: { path in
                try await console.listRemoteDirectoryContents(
                    at: path, on: hostID)
            },
            readFileHead: { path, maxLength in
                try await console.readTranscriptFileChunk(
                    atPath: path, offset: 0, length: maxLength, on: hostID)
            },
            homeDirectory: {
                try await console.remoteHomeDirectory(on: hostID)
            })
    }
}

/// A provider whose agent kind also keeps discoverable commands as plain
/// files on the Host. `discoverCommands` fetches them over the SFTP seam
/// and owns its own error handling: it never throws — a failing read
/// means fewer suggestions, not a failed chat surface.
protocol HostFileCommandDiscovery: Sendable {
    /// The kind's file-borne commands for one Host + agent cwd: omp's
    /// `skill:` and per-project file commands, in menu order (skill
    /// before file).
    func discoverCommands(cwd: String, io: AgentCommandFileIO) async -> [AgentSlashCommand]
}

extension HostFileCommandDiscovery {
    /// Kinds without a verified on-disk surface discover nothing.
    func discoverCommands(cwd: String, io: AgentCommandFileIO) async -> [AgentSlashCommand] { [] }
}

/// Pure, network-free pieces of omp's dynamic command discovery. The
/// upstream rules this mirrors (oh-my-pi 18.2.x, `extensibility/skills.ts`
/// + `discovery/helpers.ts` + `slash-commands/available-commands.ts`,
/// verified 2026-09):
///
///   - a skill's slash name is `skill:` + the frontmatter `name`
///     (falling back to the directory name); `enabled: false` drops the
///     skill; the omp/agents providers require a `description`
///   - a file command's name is the filename stem; its menu line is the
///     frontmatter description or the first non-empty body line, capped
///     at 60 characters with an ellipsis
///   - the menu dedupes by name, first-wins, in order builtin → skill →
///     extension → custom → file
enum OmpHostCommandDiscovery {
    /// The most directories any single discovery read lists (skills root
    /// + up to five walk-up levels × four command dirs).
    static let maximumListedDirectories = 21

    /// How far above the agent's cwd per-project command directories are
    /// looked for. omp itself walks to the repo root (or home); five
    /// levels covers real checkout layouts while bounding the walk.
    static let maximumWalkUpLevels = 5

    /// The per-project command directory names, in precedence order.
    /// `.omp` is omp's own convention; `.agents` is the shared standard;
    /// `.claude` and `.codex` are the compatibility roots omp loads by
    /// default (`commands.enableClaudeProject` / the Codex commands
    /// provider).
    static let commandDirectoryNames = [".omp", ".agents", ".claude", ".codex"]

    /// The head of a SKILL.md worth reading: frontmatter is at the top,
    /// and only `name`/`description`/`enabled` are consumed.
    static let maximumSkillFileBytes = 4_096

    /// The head of a command file worth reading: the description line
    /// lives at the top.
    static let maximumCommandFileBytes = 2_048

    /// The head of the agent config worth scanning for the skill gate.
    static let maximumConfigBytes = 64 * 1_024

    // MARK: - Config gate

    /// Whether omp registers skills as `/skill:<name>` commands, read
    /// from the Host's `~/.omp/agent/config.yml`. The gate key is
    /// `skills.enableSkillCommands`; YAML boolean spellings are
    /// accepted, everything else (absent key, unreadable file, other
    /// value) falls back to omp's schema default — **true** (verified
    /// against the 18.2.3 binary's embedded schema and upstream
    /// `settings-schema.ts`; the TUI path treats an unset value as
    /// enabled, `interactive-mode.ts`'s `!== false`).
    static func skillCommandsEnabled(inConfigYaml yaml: String?) -> Bool {
        guard var yaml, !yaml.isEmpty else { return true }
        for lineFragment in yaml.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = lineFragment.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("enableSkillCommands:") else { continue }
            let value = line
                .dropFirst("enableSkillCommands:".count)
                .trimmingCharacters(in: .whitespaces)
            switch value.lowercased() {
            case "false", "no", "off": return false
            case "true", "yes", "on": return true
            default: continue
            }
        }
        return true
    }

    // MARK: - Skills

    /// One skill directory listing entry → the candidate name omp would
    /// probe: dot-prefixed entries are skipped (omp's rule).
    static func skillCandidateNames(
        fromListing contents: RemoteDirectoryContents
    ) -> [String] {
        contents.entries
            .filter { $0.isDirectory && !$0.name.hasPrefix(".") }
            .map(\.name)
    }

    /// The command a SKILL.md's head yields, or nil when omp would not
    /// register the skill: `enabled: false`, missing description (the
    /// agents provider loads skills with `requireDescription: true`), or
    /// a name that cannot survive as one insertable word. The name is
    static func skillCommand(
        directoryName: String, fileHead: String
    ) -> AgentSlashCommand? {
        let frontmatter = SkillFrontmatter.parse(fileHead)
        if frontmatter.enabled == false { return nil }
        guard let description = SkillProbe.safeDescription(frontmatter.description)
        else { return nil }
        let rawName = frontmatter.name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let rawName, !rawName.isEmpty, SkillProbe.isUsableName(rawName) {
            name = rawName
        } else {
            name = directoryName
        }
        guard SkillProbe.isUsableName(name) else { return nil }
        return AgentSlashCommand(
            name: "skill:\(name)",
            summary: description,
            usage: "arguments",
            source: .skillFile)
    }

    /// The `<dir>/commands` directories to list for one agent cwd:
    /// walking up at most ``maximumWalkUpLevels``, nearest level first,
    /// in ``commandDirectoryNames`` order within a level. Paths are
    /// absolute POSIX (a relative or empty cwd yields none).
    static func commandDirectories(fromCwd cwd: String) -> [String] {
        guard cwd.hasPrefix("/") else { return [] }
        if cwd == "/" {
            return commandDirectoryNames.map { "/\($0)/commands" }
        }
        var level = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        guard !level.isEmpty else { return [] }
        var directories: [String] = []
        var levels = 0
        while true {
            for name in commandDirectoryNames {
                directories.append("\(level)/\(name)/commands")
            }
            levels += 1
            guard levels < maximumWalkUpLevels else { break }
            guard let parent = level.lastIndex(of: "/") else { break }
            level =
                parent == level.startIndex
                ? "/" : String(level[..<parent])
        }
        return directories
    }

    // MARK: - File commands

    /// The command a `<name>.md` command file's head yields, or nil when
    /// the entry is not a command: the name is the filename stem and must
    /// survive as one word. The menu line is the frontmatter
    /// description, else the first non-empty line past any frontmatter
    /// block, capped at 60 characters with an ellipsis (omp's rule).
    static func fileCommand(
        filename: String, fileHead: String
    ) -> AgentSlashCommand? {
        guard filename.hasSuffix(".md") else { return nil }
        // omp's discovery globs with hidden: false — dotfile commands
        // are never loaded, so the menu must not advertise them.
        guard !filename.hasPrefix(".") else { return nil }
        let stem = String(filename.dropLast(3))
        guard !stem.isEmpty, SkillProbe.isUsableName(stem) else { return nil }
        let frontmatter = SkillFrontmatter.parse(fileHead)
        var summary: String?
        if let description = SkillProbe.safeDescription(frontmatter.description) {
            summary = description
        } else if let line = firstContentLine(fileHead) {
            summary = line.count > 60 ? String(line.prefix(60)) + "..." : line
        }
        return AgentSlashCommand(
            name: stem,
            summary: summary,
            usage: nil,
            source: .commandFile)
    }

    /// The first non-empty line of `content` with any leading frontmatter
    /// block skipped — the fallback menu line for a command file without
    /// a description.
    static func firstContentLine(_ content: String) -> String? {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines = lines.dropFirst()
            while let line = lines.first {
                lines = lines.dropFirst()
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" || trimmed == "..." { break }
            }
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return SkillProbe.safeDescription(trimmed)
            }
        }
        return nil
    }

    // MARK: - Fetch (over the seam)

    /// The discovered commands for one Host, in menu order: skill
    /// commands (gated) first, then per-project file commands. Every
    /// failing read is skipped — a missing skills directory, an
    /// unreadable SKILL.md, an absent config: each yields fewer
    /// suggestions, never an error.
    static func commands(
        cwd: String, io: AgentCommandFileIO, log: Logger
    ) async -> [AgentSlashCommand] {
        var commands: [AgentSlashCommand] = []
        if await skillCommandsEnabled(io: io, log: log) {
            commands += await skillCommands(io: io, log: log)
        }
        commands += await fileCommands(cwd: cwd, io: io)
        return commands
    }

    /// Reads the gate from `~/.omp/agent/config.yml` over the seam.
    /// Unreadable → omp's default (enabled).
    private static func skillCommandsEnabled(
        io: AgentCommandFileIO, log: Logger
    ) async -> Bool {
        do {
            let home = try await io.homeDirectory()
            let head = try await io.readFileHead(
                "\(home)/.omp/agent/config.yml", maximumConfigBytes)
            return skillCommandsEnabled(
                inConfigYaml: String(decoding: head, as: UTF8.self))
        } catch {
            log.info(
                "skill-command gate unreadable (\(error.localizedDescription, privacy: .public)); using omp's default")
            return true
        }
    }

    /// Lists `~/.agents/skills`, reads each `<name>/SKILL.md` head, and
    /// maps the loadable ones to `skill:<name>` commands.
    private static func skillCommands(
        io: AgentCommandFileIO, log: Logger
    ) async -> [AgentSlashCommand] {
        let home: String
        do {
            home = try await io.homeDirectory()
        } catch {
            log.info("skills listing skipped: no home (\(error.localizedDescription, privacy: .public))")
            return []
        }
        let listing: RemoteDirectoryContents
        do {
            listing = try await io.listDirectory("\(home)/.agents/skills")
        } catch {
            log.info("skills listing failed (\(error.localizedDescription, privacy: .public))")
            return []
        }
        var commands: [AgentSlashCommand] = []
        for name in skillCandidateNames(fromListing: listing) {
            do {
                let head = try await io.readFileHead(
                    "\(home)/.agents/skills/\(name)/SKILL.md",
                    maximumSkillFileBytes)
                if let command = skillCommand(
                    directoryName: name,
                    fileHead: String(decoding: head, as: UTF8.self))
                {
                    commands.append(command)
                }
            } catch {
                // A skill without a readable SKILL.md is not a skill omp
                // registers; skip it and keep the rest.
                continue
            }
        }
        return commands
    }

    /// Lists each walk-up `<dir>/commands` and maps the `.md` entries to
    /// file commands. A missing directory is the common case (most
    /// levels carry none) and simply contributes nothing.
    private static func fileCommands(
        cwd: String, io: AgentCommandFileIO
    ) async -> [AgentSlashCommand] {
        guard !cwd.isEmpty else { return [] }
        var commands: [AgentSlashCommand] = []
        for directory in commandDirectories(fromCwd: cwd) {
            let listing: RemoteDirectoryContents
            do {
                listing = try await io.listDirectory(directory)
            } catch {
                continue
            }
            for entry in listing.entries where !entry.isDirectory {
                do {
                    let head = try await io.readFileHead(
                        "\(directory)/\(entry.name)", maximumCommandFileBytes)
                    if let command = fileCommand(
                        filename: entry.name,
                        fileHead: String(decoding: head, as: UTF8.self))
                    {
                        commands.append(command)
                    }
                } catch {
                    continue
                }
            }
        }
        return commands
    }
}

/// The per-(Host, pane) cache of one chat surface's discovered commands.
/// `makeChatDependencies` refreshes on chat open; the menu reads the
/// cache synchronously (empty until the refresh lands, so the first `/`
/// can already show the static table). A failed refresh leaves the cache
/// untouched — the menu degrades to the builtin table, never breaks.
@MainActor
final class AgentDynamicCommandStore {
    static let shared = AgentDynamicCommandStore()

    private struct CacheKey: Hashable {
        let hostID: UUID
        let paneID: String
    }

    private var cache: [CacheKey: [AgentSlashCommand]] = [:]
    private var refreshesInFlight: Set<CacheKey> = []
    private let log = Logger(subsystem: "dev.bybee.heeler", category: "AgentCommands")

    /// The discovered commands for one chat surface, or empty while the
    /// opening refresh has not landed (or failed — the silent degrade).
    func cachedCommands(hostID: UUID, paneID: String) -> [AgentSlashCommand] {
        cache[CacheKey(hostID: hostID, paneID: paneID)] ?? []
    }

    /// Re-fetches one chat surface's discovered commands over the seam.
    /// Idempotent per (Host, pane): a refresh already running wins and
    /// the later call rides on it.
    func refresh(
        hostID: UUID,
        paneID: String,
        kind: String,
        cwd: String,
        io: AgentCommandFileIO
    ) async {
        let key = CacheKey(hostID: hostID, paneID: paneID)
        guard !refreshesInFlight.contains(key) else { return }
        refreshesInFlight.insert(key)

        let provider = AgentCommandRegistry.provider(forKind: kind)
        guard let discovery = provider as? any HostFileCommandDiscovery else {
            refreshesInFlight.remove(key)
            return
        }
        let discovered = await discovery.discoverCommands(cwd: cwd, io: io)
        let builtin = provider.slashCommands()
        // omp's menu dedupe: first-wins in menu order builtin →
        // skill → file, so a file command named like a builtin is
        // shadowed exactly as the agent's own menu shadows it.
        var seen = Set<String>()
        cache[key] = (builtin + discovered).filter { seen.insert($0.name).inserted }
        refreshesInFlight.remove(key)
    }
}
