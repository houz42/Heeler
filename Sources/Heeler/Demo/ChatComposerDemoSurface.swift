#if DEBUG && targetEnvironment(simulator)
    import Observation
    import SwiftUI

    // SPDX-License-Identifier: Apache-2.0
    //
    // The v3 Messages-style composer capture surface (the
    // `--demo-chat-composer` demo route). ChatScreen with an
    // INTERACTIVE composer: a real ComposerRouterStore (the omp
    // command catalog, /level persistence, tag/mention/bash routing
    // over scripted seams), a deliver closure that appends the sent
    // text to the live transcript, and an attachments bundle whose
    // staging store completes instantly with a fake Host path — so
    // the + menu, pickers, tiles, multiline growth, and Send all run
    // the production composer code without a backend.

    /// One sent demo message, appended to the live transcript.
    @MainActor
    final class ChatComposerDemoModel: ObservableObject {
        @Published var messages: [ChatMessage] = [
            ChatMessage(role: .user, blocks: [
                .text("Ship the composer slice — capture the four states."),
            ]),
            ChatMessage(role: .assistant, blocks: [
                .text(
                    "Understood. The composer is the one row at the bottom: "
                    + "+ menu, capsule, Send. Try it — typing, attaching, "
                    + "and the four command modes are all live here."),
            ]),
        ]
        @Published var delivered: [String] = []
        @Published var follows: [String] = []
        @Published var tags: [TagFilter] = []

        func deliver(_ text: String) async throws {
            delivered.append(text)
            messages.append(ChatMessage(role: .user, blocks: [.text(text)]))
        }
    }

    /// The interactive composer demo surface.
    @MainActor
    struct ChatComposerDemoSurface: View {
        @StateObject private var model = ChatComposerDemoModel()
        @State private var levelStore = ChatDetailLevelStore(
            defaults: DemoScreenshotFixture.makeDefaults())
        @State private var router: ComposerRouterStore?
        @State private var attachments: ChatAttachments?

        var body: some View {
            NavigationStack {
                ChatScreen(
                    paneID: "demo:composer",
                    agentName: "ios-polish",
                    state: .idle,
                    content: ChatContent(messages: model.messages),
                    initialLevel: .l1,
                    changeLevel: { [levelStore] level, paneID in
                        levelStore.setLevel(level, paneID: paneID)
                    },
                    router: router,
                    deliver: { [model] text in
                        try await model.deliver(text)
                    },
                    deliverStructured: { [model] text, _ in
                        // Images ride the structured array in production;
                        // the demo transcript shows the text half.
                        try await model.deliver(
                            text.isEmpty ? "📷 (image-only message)" : text)
                    },
                    authorLabel: "Meadow · omp",
                    attachments: attachments)
                .navigationTitle("ios-polish")
                .navigationBarTitleDisplayMode(.inline)
            }
            .onAppear { buildDependencies() }
        }

        /// The attachment-capture route's launch argument.
        static let attachmentLaunchArgument = "--demo-composer-attachment"

        /// True when the attachment capture route is active.
        private static var wantsAttachmentSeed: Bool {
            ProcessInfo.processInfo.arguments.contains(attachmentLaunchArgument)
        }

        init() {
            // Seed in INIT, before ChatScreen's onAppear loads the
            // persisted draft: the capture opens on the RESTORED
            /// state (the real item-18 path), never a post-hoc write.
            if Self.wantsAttachmentSeed {
                ChatDraftPersistenceStore.shared.save(
                    ChatPaneDraft(
                        text: "Take a look at this screenshot —",
                        caretLocation: 27,
                        items: [
                            ChatPaneDraft.Item(
                                kind: .image,
                                id: "demo-image-1",
                                remotePath: "/home/demo/uploads/shot.png",
                                name: nil,
                                text: nil,
                                author: nil)
                        ]),
                    paneID: "demo:composer")
            } else {
                // The plain capture route opens the RESTING row: a
                // stale seed from a previous attachment capture must
                // not bleed in (the draft suite persists across
                // relaunches by design).
                ChatDraftPersistenceStore.shared.clear(paneID: "demo:composer")
            }
            _model = StateObject(wrappedValue: ChatComposerDemoModel())
            _levelStore = State(
                initialValue: ChatDetailLevelStore(
                    defaults: DemoScreenshotFixture.makeDefaults()))
        }

        /// Wires the router + attachments once: the real command
        /// catalog over scripted seams (bash pane records but never
        /// connects; mention resolution over a fixed roster).
        private func buildDependencies() {
            guard router == nil else { return }
            router = ComposerRouterStore(
                dependencies: ComposerRouterStore.Dependencies(
                    hostID: DemoScreenshotFixture.studioHostID,
                    paneID: "demo:composer",
                    levelStore: levelStore,
                    resolveAgent: { name in
                        let roster = ["docs-review", "accessibility", "reviewer"]
                        let exact = roster.first {
                            $0.caseInsensitiveCompare(name) == .orderedSame
                        }
                        guard let exact else { return nil }
                        return (
                            hostID: DemoScreenshotFixture.studioHostID,
                            paneID: exact
                        )
                    },
                    deliverMention: { [model] resolved, message in
                        try await model.deliver(
                            "→ \(resolved.paneID): \(message)")
                    },
                    bashIO: ComposerBashIO(
                        createScratchPane: { _ in "demo:scratch" },
                        sendText: { _, _, _ in },
                        readPaneText: { _, _ in "" }),
                    follow: { [model] name in model.follows.append(name) },
                    tagFilter: { [model] filter in model.tags.append(filter) },
                    // The demo has no level-chrome to re-read; the
                    // level store persists via the store's own path.
                    levelDidChange: { _ in },
                    workspaces: { ["iOS App", "Product Docs"] },
                    statuses: { ["blocked", "working", "done", "idle"] },
                    agents: {
                        ["docs-review", "accessibility", "reviewer"]
                    },
                    // The demo's command lane: a selection "invokes"
                    // by landing the command + arguments in the live
                    // transcript — visibly structured, never slash
                    // text through the prompt path.
                    deliverCommand: { [model] catalogID, name, arguments in
                        try await model.deliver(
                            "⚡ \(catalogID) (\(name))"
                            + (arguments.isEmpty ? "" : " args: \(arguments.joined(separator: " "))"))
                    },
                    describeError: { "Demo: \($0.localizedDescription)" },
                    bashTimeout: .seconds(2),
                    bashPollInterval: .milliseconds(50)))
            let draftStore = ChatAttachmentDraftStore()
            attachments = ChatAttachments(
                staging: ComposerStagingStore(
                    stageImage: { prepared, _ in
                        _ = prepared
                        return try StagedImage(path: "/home/demo/uploads/shot.png")
                    },
                    stageFile: { prepared, _ in
                        _ = prepared
                        return try StagedFile(path: "/home/demo/uploads/notes.md")
                    },
                    composer: draftStore),
                draftStore: draftStore)
        }
    }
#endif
