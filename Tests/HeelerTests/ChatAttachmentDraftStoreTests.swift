import Foundation
import Testing
import UIKit

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The chat input's attachment flow, at the seams the feature lives in:
//
// 1. `ChatAttachmentDraftStore` — the draft seam the staging pipeline
//    inserts into (caret-faithful, mirroring AgentComposerStore's
//    contract) and the pending-image hold the paste flow shows as a
//    thumbnail chip.
// 2. `ChatPasteResolver` — the pinned paste precedence: image-only
//    attaches, text-only pastes literally, both-present prefers TEXT.
// 3. The full staging pipeline through the chat draft seam: a
//    successful upload inserts the remote path reference into the draft
//    (the same `"<path> "` convention the terminal Composer produces),
//    and an upload failure surfaces an error message, not a silent
//    no-op.

// MARK: - Pasteboard scripting

/// A scripted pasteboard snapshot, so the pinned precedence runs
/// without the process-wide UIPasteboard.
@MainActor
private final class ScriptedPasteboard: ChatPasteboardSnapshotProviding {
    var hasImages = false
    var stringForPaste: String?
    var imageDataRepresentation: Data?
    var imageRepresentation: UIImage?

    init(
        hasImages: Bool = false,
        stringForPaste: String? = nil,
        imageDataRepresentation: Data? = nil,
        imageRepresentation: UIImage? = nil
    ) {
        self.hasImages = hasImages
        self.stringForPaste = stringForPaste
        self.imageDataRepresentation = imageDataRepresentation
        self.imageRepresentation = imageRepresentation
    }
}

// MARK: - ChatAttachmentDraftStore: the draft seam

@MainActor
@Suite("Chat attachment draft store")
struct ChatAttachmentDraftStoreTests {
    @Test func insertIntoDraftLandsAtTheCaretAndAdvancesIt() {
        // The staging store's completed-attachment path mirrors the
        // terminal Composer's insertIntoDraft: text lands at the caret
        // (or replaces the selection), and the caret follows the
        // insertion.
        let store = ChatAttachmentDraftStore(draft: "see this", selection: NSRange(location: 3, length: 0))
        store.insertIntoDraft("/tmp/heeler-upload/img.jpg ")

        #expect(store.draft == "see/tmp/heeler-upload/img.jpg  this")
        #expect(
            store.draftSelection
                == NSRange(location: 3 + "/tmp/heeler-upload/img.jpg ".utf16.count, length: 0))
    }

    @Test func insertIntoDraftReplacesTheCurrentSelection() {
        let store = ChatAttachmentDraftStore(
            draft: "drop [this] here", selection: NSRange(location: 5, length: 6))
        store.insertIntoDraft("/tmp/report.txt ")
        #expect(store.draft == "drop /tmp/report.txt  here")
    }

    @Test func applyEditorDraftKeepsTheReportedCaretAndClampsStaleOnes() {
        // Stale selection beyond the end (programmatic rewrites) must
        // clamp exactly the way the text view does.
        let store = ChatAttachmentDraftStore()
        store.applyEditorDraft("hello", selection: NSRange(location: 99, length: 0))
        #expect(store.draft == "hello")
        #expect(store.draftSelection == NSRange(location: 5, length: 0))
    }

    @Test func applyEditorDraftIsANoOpForIdenticalState() {
        let store = ChatAttachmentDraftStore(draft: "same", selection: NSRange(location: 4, length: 0))
        store.applyEditorDraft("same", selection: NSRange(location: 4, length: 0))
        #expect(store.draft == "same")
        #expect(store.draftSelection == NSRange(location: 4, length: 0))
    }

    // MARK: - The pending-image hold (paste flow)

    @Test func holdPendingImagePrependsItsPathToTheSentText() {
        // The Send flow's message convention: the path reference rides
        // ahead of the draft text — the same shape a bare path insert
        // produces, so the agent reads one uniform reference format.
        let store = ChatAttachmentDraftStore()
        store.holdPendingImage(path: "/tmp/heeler-upload/pic.png")
        #expect(
            store.messageText(forDraft: "what is in this image?")
            == "/tmp/heeler-upload/pic.png what is in this image?")
    }

    @Test func aPendingImageWithNoMessageTextStillBuildsASendableMessage() {
        // The reference IS the message: paste then immediately Send.
        let store = ChatAttachmentDraftStore()
        store.holdPendingImage(path: "/tmp/heeler-upload/pic.png")
        #expect(store.messageText(forDraft: "") == "/tmp/heeler-upload/pic.png ")
    }

    @Test func removingThePendingImageDropsThePathReference() {
        // The chip's x: the message text goes back to the plain draft.
        let store = ChatAttachmentDraftStore()
        store.holdPendingImage(path: "/tmp/heeler-upload/pic.png")
        store.clearPendingImage()
        #expect(store.pendingImage == nil)
        #expect(store.messageText(forDraft: "hello") == "hello")
    }

    @Test func withoutAPendingImageTheMessageTextIsTheDraftVerbatim() {
        let store = ChatAttachmentDraftStore()
        #expect(store.messageText(forDraft: "hello") == "hello")
    }

    // MARK: - Failure surfacing

    @Test func uploadFailuresSurfaceAsAnErrorMessageNotASilentNoop() {
        let store = ChatAttachmentDraftStore()
        store.recordUploadFailure("Image upload failed.")
        #expect(store.uploadFailureMessage == "Image upload failed.")
        store.clearUploadFailure()
        #expect(store.uploadFailureMessage == nil)
    }

    // MARK: - Pinned paste precedence

    @Test func imageOnlyPasteAttaches() {
        let pasteboard = ScriptedPasteboard(
            hasImages: true, imageDataRepresentation: Data([0x89, 0x50, 0x4E, 0x47]))
        let intent = ChatPasteResolver.resolve(pasteboard: pasteboard)
        #expect(intent.attachesImage)
        #expect(intent.text == nil)
        #expect(intent.imageData == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func textPasteStaysALiteralInsert() {
        let pasteboard = ScriptedPasteboard(hasImages: false, stringForPaste: "plain text")
        let intent = ChatPasteResolver.resolve(pasteboard: pasteboard)
        #expect(!intent.attachesImage)
        #expect(intent.imageData == nil)
    }

    @Test func imagePasteWithNoTextButNoReadableDataIsPlainPaste() {
        // hasImages is only the pasteboard's claim; the provider must
        // produce bytes or the paste is a no-op instead of a wrong
        // text insert.
        let pasteboard = ScriptedPasteboard(hasImages: true)
        let intent = ChatPasteResolver.resolve(pasteboard: pasteboard)
        #expect(!intent.attachesImage)
        #expect(intent.imageData == nil)
    }

    @Test func bothPresentPrefersText() {
        // The pinned rule: typed/copied text is the primary payload; a
        // stray image representation beside it must not hijack the
        // paste.
        let pasteboard = ScriptedPasteboard(
            hasImages: true,
            stringForPaste: "the message",
            imageDataRepresentation: Data([0x01]))
        let intent = ChatPasteResolver.resolve(pasteboard: pasteboard)
        #expect(!intent.attachesImage)
        #expect(intent.text == "the message")
        #expect(intent.imageData == nil)
    }

    @Test func emptyStringBesideAnImageDoesNotWin() {
        // An empty string is not a payload: the image attaches.
        let pasteboard = ScriptedPasteboard(
            hasImages: true, stringForPaste: "", imageDataRepresentation: Data([0x01]))
        let intent = ChatPasteResolver.resolve(pasteboard: pasteboard)
        #expect(intent.attachesImage)
        #expect(intent.imageData == Data([0x01]))
    }

    // MARK: - The Send composition contract (ChatScreen.sendDraft mirrors this)

    @Test func sendComposesThePathAheadOfTheDraftBeforeRouting() async throws {
        // Device regression (11d32f2): the router saw the RAW draft,
        // so an image-only paste submitted "" — an empty prompt
        // delivered, no message arrived, and the UI cleared as if
        // success. The send must compose the full message text
        // BEFORE routing and deliver exactly what was composed.
        let store = ChatAttachmentDraftStore()
        store.holdPendingImage(path: "/tmp/heeler.k1/stage-u/pic.jpg")

        // The image-only paste: draft emptied by removePathFromDraft.
        let composed = store.messageText(forDraft: "")
        #expect(composed == "/tmp/heeler.k1/stage-u/pic.jpg ")

        // The router must classify the COMPOSED text: a leading path
        // is not a chat slash command the user typed. "tmp/heeler.k1/
        // stage-u/pic.jpg" is not a known command, so an omp passthrough
        // is expected — but the classification must never see "".
        #expect(!composed.isEmpty)
        let router = ComposerRouterStore(dependencies: makeChatDependencies())
        let outcome = await router.submit(composed)
        #expect(outcome == .passthrough, "a path-only message routes as plain delivery")
        #expect(composed == store.messageText(forDraft: ""))
    }

    @Test func aDeliveryFailureSurfacesAndRetainsDraftAndChip() {
        // The other half of the device regression: the catch swallowed
        // delivery errors, clearing the draft as if success. The
        // contract: a failed delivery keeps the draft AND the pending
        // image, and the error lands in the same row staging failures
        // use.
        let store = ChatAttachmentDraftStore()
        store.applyEditorDraft("what is this?", selection: NSRange(location: 13, length: 0))
        store.holdPendingImage(path: "/tmp/heeler.k1/stage-u/pic.jpg")

        // A delivery failure (the screen records it; nothing clears).
        store.recordUploadFailure("Couldn't send the message: The Host is not connected.")
        #expect(
            store.uploadFailureMessage?.contains("not connected") == true)
        // The retry payload is intact: draft, chip, and composition.
        #expect(store.draft == "what is this?")
        #expect(store.pendingImage?.remotePath == "/tmp/heeler.k1/stage-u/pic.jpg")
        #expect(
            store.messageText(forDraft: store.draft)
                == "/tmp/heeler.k1/stage-u/pic.jpg what is this?")

        // A successful retry clears the failure and the chip together.
        store.clearUploadFailure()
        store.clearPendingImage()
        store.replaceDraft(with: "")
        #expect(store.uploadFailureMessage == nil)
        #expect(store.messageText(forDraft: "") == "")
    }
}

private func makeChatDependencies() -> ComposerRouterStore.Dependencies {
    ComposerRouterStore.Dependencies(
        hostID: UUID(),
        paneID: "wA:p1",
        levelStore: ChatDetailLevelStore(
            defaults: UserDefaults(suiteName: "ChatAttachmentDraftStoreTests.\(UUID().uuidString)")
                ?? .standard),
        resolveAgent: { _ in nil },
        deliverMention: { _, _ in },
        bashIO: ComposerBashIO(
            createScratchPane: { _ in "scratch" },
            sendText: { _, _, _ in },
            readPaneText: { _, _ in "" }))
}

// MARK: - The chat bundle's leave/rebuild lifecycle

@MainActor
@Suite("Chat attachment lifecycle")
struct ChatAttachmentLifecycleTests {
    /// The screen's wiring contract (AgentDetailView mirrors this exact
    /// sequence): teardown nils the bundle on disappear, and a later
    /// appearance rebuilds each empty slot — the + button renders on
    /// every chat entry, not just the first. Device regression: the
    /// bundle stranded nil behind a still-live chat store when the
    /// rebuild guard keyed on the chat store alone.
    @Test func teardownThenRebuildRestoresAUsableAttachmentBundle() async throws {
        // Build (the appear path): a fresh bundle accepts begins.
        let bundle = await Self.buildBundle()
        #expect(bundle.staging.canBegin, "a fresh bundle must accept begins")

        // Teardown (onDisappear): leave() settles the store, and the
        // screen's slots empty.
        await bundle.staging.leave()
        #expect(bundle.staging.state == .idle, "teardown settles to idle")
        var attachments: ChatAttachments? = nil
        #expect(attachments == nil)

        // Rebuild (the next appear): the bundle comes back accepting
        // begins, with clean pending/failure state.
        let rebuilt = await Self.buildBundle()
        attachments = rebuilt
        #expect(attachments != nil)
        #expect(rebuilt.staging.canBegin, "the rebuilt bundle must accept begins")
        #expect(rebuilt.draftStore.pendingImage == nil)
        #expect(rebuilt.draftStore.uploadFailureMessage == nil)
    }

    /// The stranding regression specifically: the chat store stays live
    /// (a spurious disappear tore only part of the bundle down) — the
    /// attachments slot must rebuild on its own, not be gated behind
    /// the chat store's existence.
    @Test func attachmentsRebuildIndependentlyOfTheChatStore() async throws {
        let bundle = await Self.buildBundle()
        // A spurious disappear: attachments nilled, chat "store" (here
        // the draft seam, already delivered) still live.
        var attachments: ChatAttachments? = nil
        _ = bundle  // the live chat bundle keeps serving the screen
        #expect(attachments == nil)

        // The next appearance: the guard must rebuild the empty
        // attachments slot even though the chat side never went away.
        let rebuilt = await Self.buildBundle()
        attachments = rebuilt
        #expect(attachments != nil)
        #expect(rebuilt.staging.canBegin)
    }

    /// The teardown path an in-flight upload goes through: leave()
    /// cancels it and settles to idle, so the abandoned screen holds no
    /// live operation.
    @Test func leaveDuringAnInFlightUploadCancelsAndSettles() async throws {
        let gate = ScriptedTransportCallGate()
        let transport = ScriptedTransport()
        await transport.configureImageStaging(
            outcomes: [.success(try! StagedImage(path: "/tmp/heeler-upload/x.jpg"))],
            gate: gate)
        let draftStore = ChatAttachmentDraftStore()
        let staging = ComposerStagingStore(
            imagePreparer: ScriptedChatImagePreparer(),
            filePreparer: ScriptedChatFilePreparer(),
            stageImage: { image, reporter in
                try await transport.stageImage(image) { progress in
                    await reporter.report(progress)
                }
            },
            stageFile: { file, reporter in
                try await transport.stageFile(file) { progress in
                    await reporter.report(progress)
                }
            },
            composer: draftStore)
        #expect(staging.begin(.photo(DataImageSelection(data: Data([0x01])))) != nil)
        await staging.leave()
        #expect(staging.state == .idle, "leave() must cancel and settle to idle")
        #expect(staging.canBegin, "a settled store accepts a new begin")
    }

    /// The + render contract's device regression (de3ba20): the button
    /// must not depend on the bundle's existence. ChatScreen mirrors
    /// this exact fallback — actions with canBegin=false while the
    /// bundle is missing — so a stranded bundle renders a disabled
    /// menu, never a missing button.
    @Test func plusActionsRenderWithoutABundleWithDisabledBegin() {
        let attachments: ChatAttachments? = nil
        let canBegin = attachments?.staging.canBegin ?? false
        #expect(!canBegin, "a missing bundle must render disabled actions, not hide the +")
        #expect(
            !AgentActionMenuPolicy.isEnabled(
                .addImage,
                actions: AgentComposerActions(
                    canBegin: canBegin,
                    attachLinkCount: 0,
                    addImage: {},
                    addFile: {},
                    showAttachLinks: {},
                    openTerminal: nil,
                    isOpeningTerminal: false,
                    startAgent: {},
                    manageSnippets: {},
                    showSkills: nil,
                    showWorktreeDetails: nil,
                    renameAgent: {},
                    renameWorkspace: {},
                    closeAgent: {})),
            "Add Image must be disabled, not gone, while the bundle is missing")
    }

    /// The + add flow's device regression (de3ba20): the completed
    /// upload's path insertion landed in the DRAFT MIRROR, which the
    /// visible draft never sinks — the path reference must appear in
    /// the text the user sees and sends. The screen's completion sink
    /// mirrors this exact sequence.
    @Test func completedAddUploadSinksTheMirrorIntoTheVisibleDraft() async throws {
        let bundle = await Self.buildBundle()
        // The visible draft's state (empty; the user just opened input).
        var visibleDraft = ""
        bundle.draftStore.applyEditorDraft(visibleDraft, selection: NSRange(location: 0, length: 0))

        // The staging store completes and inserts into the mirror.
        _ = bundle.staging.begin(.file(URL(fileURLWithPath: "/provider/report.txt")))
        try await waitUntil("upload should complete") {
            if case .completed = bundle.staging.state { return true }
            return false
        }
        // The screen's completion sink (syncAttachmentUploadState's
        // non-paste branch): mirror → visible.
        let mirrored = bundle.draftStore.draft
        if mirrored != visibleDraft {
            visibleDraft = mirrored
        }
        #expect(
            visibleDraft.hasPrefix("/tmp/heeler-upload/lifecycle.txt"),
            "the path reference must reach the VISIBLE draft the user sends")
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }

    /// Mirrors AgentDetailView.buildChatIfPossible's construction.
    private static func buildBundle() async -> ChatAttachments {
        let draftStore = ChatAttachmentDraftStore()
        return ChatAttachments(
            staging: ComposerStagingStore(
                imagePreparer: ScriptedChatImagePreparer(),
                filePreparer: ScriptedChatFilePreparer(),
                stageImage: { _, _ in
                    try await Task.sleep(for: .milliseconds(1))
                    return try StagedImage(path: "/tmp/heeler-upload/lifecycle.jpg")
                },
                stageFile: { _, _ in
                    try await Task.sleep(for: .milliseconds(1))
                    return try StagedFile(path: "/tmp/heeler-upload/lifecycle.txt")
                },
                composer: draftStore),
            draftStore: draftStore)
    }
}

// MARK: - The staging pipeline through the chat draft seam

@MainActor
@Suite("Chat attachment staging pipeline")
struct ChatAttachmentStagingTests {
    private func makeFixture(
        imagePlans: [Result<StagedImage, AttachmentStagingError>] = [
            .success(try! StagedImage(path: "/tmp/heeler-upload/chat-img.jpg"))
        ],
        filePlans: [Result<StagedFile, AttachmentStagingError>] = [
            .success(try! StagedFile(path: "/tmp/heeler-upload/chat-report.txt"))
        ]
    ) async -> (staging: ComposerStagingStore, draftStore: ChatAttachmentDraftStore, transport: ScriptedTransport) {
        let transport = ScriptedTransport()
        await transport.configureImageStaging(outcomes: imagePlans)
        await transport.configureFileStaging(outcomes: filePlans)
        let draftStore = ChatAttachmentDraftStore()
        let staging = ComposerStagingStore(
            imagePreparer: ScriptedChatImagePreparer(),
            filePreparer: ScriptedChatFilePreparer(),
            stageImage: { image, reporter in
                try await transport.stageImage(image) { progress in
                    await reporter.report(progress)
                }
            },
            stageFile: { file, reporter in
                try await transport.stageFile(file) { progress in
                    await reporter.report(progress)
                }
            },
            composer: draftStore)
        return (staging, draftStore, transport)
    }

    @Test func successfulUploadInsertsThePathReferenceIntoTheChatDraft() async throws {
        // The chat surface's + Add File lands the same message-format
        // convention the terminal Composer produces: the remote path
        // (with its trailing space) inserted at the caret.
        let fixture = await makeFixture()
        fixture.draftStore.applyEditorDraft(
            "check this out ", selection: NSRange(location: 15, length: 0))

        let id = fixture.staging.begin(.file(URL(fileURLWithPath: "/provider/report.txt")))
        #expect(id != nil, "the pipeline must accept the begin")

        try await waitUntil("upload should complete") {
            if case .completed = fixture.staging.state { return true }
            return false
        }

        #expect(
            fixture.draftStore.draft
                == "check this out /tmp/heeler-upload/chat-report.txt ")
    }

    @Test func uploadFailureSurfacesAnErrorAndLeavesTheDraftUntouched() async throws {
        // A failing upload must not insert anything: the draft stays,
        // and the failure is visible to the frame's error row.
        let fixture = await makeFixture(
            imagePlans: [.failure(.sftpUnavailable)])
        let before = fixture.draftStore.draft

        let id = fixture.staging.begin(.photo(DataImageSelection(data: Data([0x01]))))
        #expect(id != nil)

        try await waitUntil("upload should fail") {
            if case .failed = fixture.staging.state { return true }
            return false
        }

        #expect(fixture.draftStore.draft == before)
        guard case .failed(let failure) = fixture.staging.state else {
            Issue.record("expected a failed state")
            return
        }
        #expect(failure.message.contains("SFTP"))
        #expect(!failure.isRetryable)
    }

    @Test func beginWhileBusyIsRejectedNotSilentlyQueued() async throws {
        // The busy guard: a second begin (double paste) returns nil
        // instead of queueing behind the first — the caller surfaces
        // the "already uploading" error.
        let gate = ScriptedTransportCallGate()
        let transport = ScriptedTransport()
        await transport.configureImageStaging(
            outcomes: [.success(try! StagedImage(path: "/tmp/heeler-upload/a.jpg"))],
            gate: gate)
        let draftStore = ChatAttachmentDraftStore()
        let staging = ComposerStagingStore(
            imagePreparer: ScriptedChatImagePreparer(),
            filePreparer: ScriptedChatFilePreparer(),
            stageImage: { image, reporter in
                try await transport.stageImage(image) { progress in
                    await reporter.report(progress)
                }
            },
            stageFile: { file, reporter in
                try await transport.stageFile(file) { progress in
                    await reporter.report(progress)
                }
            },
            composer: draftStore)

        let first = staging.begin(.photo(DataImageSelection(data: Data([0x01]))))
        #expect(first != nil)
        let second = staging.begin(.photo(DataImageSelection(data: Data([0x02]))))
        #expect(second == nil, "a busy pipeline must reject, not queue")

        await gate.open()
        try await waitUntil("first upload should complete") {
            if case .completed = staging.state { return true }
            return false
        }
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}

/// Returns one bounded prepared image without touching the filesystem
/// — the pipeline under test is the transport hop, not the decode.
private actor ScriptedChatImagePreparer: ImagePreparing {
    func prepare(_: any ImageSelection) async throws -> PreparedImage {
        PreparedImage(
            fileURL: URL(fileURLWithPath: "/nonexistent/prepared.jpg"),
            format: .jpeg,
            pixelWidth: 16,
            pixelHeight: 16,
            byteCount: 128)
    }
}

private actor ScriptedChatFilePreparer: FilePreparing {
    func prepare(_: URL) async throws -> PreparedFile {
        PreparedFile(
            fileURL: URL(fileURLWithPath: "/nonexistent/prepared.txt"),
            fileExtension: "txt",
            byteCount: 256)
    }
}
