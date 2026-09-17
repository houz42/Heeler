import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The per-agent-kind slash command provider contract (fork plan, Phase
// 3): registry lookup (registered kind → its table, unknown kind → the
// empty provider so the menu degrades to client-local commands), the
// omp table's integrity (36 verified entries, unique names, summaries
// present, usage only where the binary carries one), and suggestion
// filtering over a provider's commands.

// MARK: - Registry

@Suite("AgentCommandRegistry")
struct ChatSlashProviderRegistryTests {
    @Test func ompKindResolvesToOmpProvider() {
        let commands = AgentCommandRegistry.provider(forKind: "omp")
            .slashCommands()
        #expect(!commands.isEmpty)
        #expect(commands == OmpCommandProvider.commands)
    }

    @Test func lookupIsCaseInsensitive() {
        #expect(
            AgentCommandRegistry.provider(forKind: "OMP").slashCommands()
            == AgentCommandRegistry.provider(forKind: "omp").slashCommands())
    }

    @Test func unknownKindYieldsNoAgentCommands() {
        // Kinds without a verified table must return nothing — never
        // crash, never fake omp's commands onto another agent.
        for kind in ["claude", "codex", "copilot", "pi", "muse", "unknown-agent"] {
            #expect(AgentCommandRegistry.provider(forKind: kind).slashCommands().isEmpty)
        }
    }

    @Test func unknownKindMenuDegradesToLocalOnly() {
        // The full store-level behavior the acceptance asks for: an
        // unknown kind still opens the menu on `/`, listing exactly the
        // client-local commands with their summaries.
        let suggestions = ComposerRouter.slashSuggestions(
            matching: "", agentCommands: [])
        #expect(suggestions.map(\.title) == ComposerLocalCommand.all.map(\.name))
        #expect(suggestions.allSatisfy { $0.kind == .local })
        #expect(suggestions.allSatisfy { $0.detail != nil })
    }

    @Test func unknownKindInsertionStillWorks() {
        let suggestions = ComposerRouter.slashSuggestions(
            matching: "f", agentCommands: [])
        #expect(suggestions.map(\.title) == ["follow"])
        #expect(suggestions.first?.insertion == "/follow ")
    }
}

// MARK: - omp table integrity

@Suite("OmpCommandProvider table")
struct ChatSlashProviderTableTests {
    let commands = OmpCommandProvider().slashCommands()

    @Test func tableHasThirtySixEntries() {
        #expect(commands.count == 36)
    }

    @Test func namesAreUnique() {
        #expect(Set(commands.map(\.name)).count == commands.count)
    }

    @Test func everyEntryCarriesAVerifiedSummary() {
        #expect(commands.allSatisfy { command in
            (command.summary?.isEmpty == false) && command.name.isEmpty == false
        })
    }

    @Test func allEntriesAreBuiltinTableSourced() {
        // No probe surface exists at protocol 22 (see AgentCommandProvider
        // header) — asserting .builtinTable guards against a fabricated
        // .probed entry sneaking in ahead of the real wire.
        #expect(commands.allSatisfy { $0.source == .builtinTable })
    }

    @Test func usageAppearsOnlyWhereVerified() {
        // Spot entries verified against the 18.2.1 binary's registry:
        // compact's acpInputHint resolves its template to the real mode
        // names; help carries no hint so usage stays nil.
        let byName = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
        #expect(byName["compact"]?.usage == "[soft|remote|snapcompact] [focus]")
        #expect(byName["tan"]?.usage == "<work>")
        #expect(byName["usage"]?.usage == "[show|reset [account|active]]")
        #expect(byName["help"]?.usage == nil)
        #expect(byName["tan"]?.usage == "<work>")
    }

    @Test func tableOrderIsStableAcrossCalls() {
        #expect(OmpCommandProvider().slashCommands() == OmpCommandProvider.commands)
    }
}

// MARK: - Suggestion filtering with summaries

@Suite("Slash suggestions over provider commands")
struct ChatSlashProviderFilterTests {
    let ompCommands = OmpCommandProvider().slashCommands()

    @Test func everyAgentRowCarriesItsSummary() {
        let suggestions = ComposerRouter.slashSuggestions(
            matching: "", agentCommands: ompCommands)
        let ompRows = suggestions.filter { $0.kind == .slash }
        #expect(!ompRows.isEmpty)
        #expect(ompRows.allSatisfy { $0.detail?.isEmpty == false })
    }

    @Test func filteringNarrowsAsTyped() {
        let all = ComposerRouter.slashSuggestions(
            matching: "", agentCommands: ompCommands)
        let narrowed = ComposerRouter.slashSuggestions(
            matching: "to", agentCommands: ompCommands)
        #expect(narrowed.count < all.count)
        #expect(narrowed.allSatisfy { $0.title.hasPrefix("to") })
        let titles = Set(narrowed.map(\.title))
        #expect(titles.contains("todo"))
    }

    @Test func usageSurfacesOnSuggestionRows() {
        let suggestions = ComposerRouter.slashSuggestions(
            matching: "u", agentCommands: ompCommands)
        let usage = suggestions.first { $0.title == "usage" }
        #expect(usage?.usage == "[show|reset [account|active]]")
    }

    @Test func noMatchStillShowsNothingRatherThanEverything() {
        let suggestions = ComposerRouter.slashSuggestions(
            matching: "zzzz", agentCommands: ompCommands)
        #expect(suggestions.isEmpty)
    }
}
