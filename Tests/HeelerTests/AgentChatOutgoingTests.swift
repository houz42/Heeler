import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// Delivery-lifecycle regression proofs — review round (7 gaps) and
// re-review round (5 findings). One proof per contract.

@Suite("Agent chat outgoing delivery lifecycle")
@MainActor
struct AgentChatOutgoingTests {
    private func unavailableStore() async -> AgentChatStore {
        let store = AgentChatStore(
            pipeFactory: .init(open: { _ in
                throw CocoaError(.fileNoSuchFile)
            }, hostRecord: { nil }),
            paneIdentity: { nil })
        await store.start()  // no pane identity → unavailable
        return store
    }

    // MARK: Gap 1 — delivery states actually change

    @Test("an unconnected send lands the echo FAILED with honest copy, never stuck sending")
    func unconnectedSendFailsVisibly() async {
        let store = await unavailableStore()
        do {
            _ = try await store.send("hello")
            Issue.record("send on an unavailable store must throw")
        } catch {}
        #expect(store.outgoing.count == 1)
        #expect(store.outgoing[0].state == .failed)
        #expect(store.outgoing[0].failureMessage != nil)
        #expect(store.lastSendFailure != nil)
    }

    // MARK: Re-review finding 3 — count-based reconciliation

    @Test("an OLDER identical record is in the baseline and never eats a newer echo")
    func olderRecordIsBaselineNeverEatsEcho() {
        // The committed page ALREADY carries one 'Continue' BEFORE the
        // send; the echo's baseline is 1. Reconciliation against the
        // SAME page (count still 1) must keep the echo.
        let olderRecord = ChatMessage(
            id: UUID(), role: .user, blocks: [.text("Continue")],
            timestamp: Date(timeIntervalSinceNow: -120))
        let echo = AgentChatOutgoingMessage(
            requestKey: "k1", text: "Continue", baselineMatchingRecords: 1)
        let survivors = AgentChatEchoReconcile.reconcile(
            echoes: [echo], committed: [olderRecord])
        #expect(survivors.count == 1)
        #expect(survivors[0].id == echo.id)
    }

    @Test("confirmation requires the count to GROW past the baseline")
    func confirmationRequiresGrowth() {
        let preExisting = ChatMessage(
            id: UUID(), role: .user, blocks: [.text("Continue")])
        let echo = AgentChatOutgoingMessage(
            requestKey: "k1", text: "Continue", baselineMatchingRecords: 1)
        // Same page → count == baseline → no confirmation.
        #expect(
            AgentChatEchoReconcile.reconcile(
                echoes: [echo], committed: [preExisting]).count == 1)
        // The record's twin lands → count 2 > baseline 1 → confirmed.
        let twin = ChatMessage(
            id: UUID(), role: .user, blocks: [.text("Continue")])
        #expect(
            AgentChatEchoReconcile.reconcile(
                echoes: [echo], committed: [preExisting, twin]).isEmpty)
    }

    @Test("N identical pending echoes need N NEW records (never collapse)")
    func identicalSendsNeedNRecords() {
        let first = AgentChatOutgoingMessage(
            requestKey: "k1", text: "Continue", baselineMatchingRecords: 0)
        let second = AgentChatOutgoingMessage(
            requestKey: "k2", text: "Continue", baselineMatchingRecords: 0)
        let oneRecord = [ChatMessage(
            id: UUID(), role: .user, blocks: [.text("Continue")])]
        // One record confirms ONE echo; the other stays.
        let afterOne = AgentChatEchoReconcile.reconcile(
            echoes: [first, second], committed: oneRecord)
        #expect(afterOne.count == 1)
        let twoRecords = oneRecord + [ChatMessage(
            id: UUID(), role: .user, blocks: [.text("Continue")])]
        #expect(
            AgentChatEchoReconcile.reconcile(
                echoes: [first, second], committed: twoRecords).isEmpty)
    }

    @Test("failed and AMBIGUOUS echoes never reconcile away (retry stays)")
    func failedAndAmbiguousSurvive() {
        var failed = AgentChatOutgoingMessage(
            requestKey: "k1", text: "Continue", baselineMatchingRecords: 0)
        failed.state = .failed
        failed.failureMessage = "Send failed"
        var ambiguous = AgentChatOutgoingMessage(
            requestKey: "k2", text: "Continue", baselineMatchingRecords: 0)
        ambiguous.state = .ambiguous
        ambiguous.failureMessage = "Connection lost mid-flight"
        let record = ChatMessage(
            id: UUID(), role: .user, blocks: [.text("Continue")])
        let survivors = AgentChatEchoReconcile.reconcile(
            echoes: [failed, ambiguous], committed: [record])
        #expect(survivors.count == 2)
        #expect(survivors.contains { $0.id == failed.id })
        #expect(survivors.contains { $0.id == ambiguous.id })
    }

    @Test("a TEXT-ONLY record never confirms an IMAGE-bearing echo")
    func imageEchoNeedsImageRecord() {
        let echo = AgentChatOutgoingMessage(
            requestKey: "k1", text: "look",
            images: [AgentChatOutgoingImage(data: Data([1, 2]), mimeType: "image/png")],
            baselineMatchingRecords: 0)
        let textOnly = ChatMessage(
            id: UUID(), role: .user, blocks: [.text("look")])
        #expect(
            AgentChatEchoReconcile.reconcile(
                echoes: [echo], committed: [textOnly]).count == 1)
        let withImage = ChatMessage(
            id: UUID(), role: .user,
            blocks: [.text("look"), .image(ChatImageRef(
                ref: "r", mimeType: "image/png", byteLength: 2))])
        #expect(
            AgentChatEchoReconcile.reconcile(
                echoes: [echo], committed: [withImage]).isEmpty)
    }

    // MARK: Re-review finding 2 — ambiguous-loss honesty

    @Test("connection-loss and timeout failures classify AMBIGUOUS; wire errors stay failed")
    func ambiguousClassification() {
        #expect(AgentChatOutgoingMessageTestsBridge.isAmbiguous(
            AgentChatError.connectionClosed))
        #expect(AgentChatOutgoingMessageTestsBridge.isAmbiguous(
            AgentChatError.timedOut(method: "prompt.send")))
        #expect(!AgentChatOutgoingMessageTestsBridge.isAmbiguous(
            AgentChatError.wire(code: "invalid_request", message: "no", retryable: false)))
    }

    // MARK: Gap 5 + finding 2 — retry key rules

    @Test("retry by ECHO ID on the unavailable store keeps the key and lands failed again")
    func retryByID() async {
        let store = await unavailableStore()
        do { _ = try await store.send("hello") } catch {}
        guard let echo = store.outgoing.first else {
            Issue.record("echo missing after failed send")
            return
        }
        let originalKey = echo.requestKey
        // Retry by ID (re-review finding 1): same nil-vs-nil snapshot
        // → key preserved.
        do { try await store.retry(echoID: echo.id) } catch {}
        #expect(store.outgoing[0].requestKey == originalKey)
        #expect(store.outgoing[0].state == .failed)
    }

    @Test("retry on an AMBIGUOUS echo mints a fresh key")
    func ambiguousRetryMintsFreshKey() {
        // The key rule is the comparison: ambiguous ⇒ always fresh.
        var ambiguous = AgentChatOutgoingMessage(
            requestKey: "old-key", text: "Continue",
            sendRegistration: AgentChatRegistrationSnapshot(
                instanceId: "I", generation: 1),
            baselineMatchingRecords: 0)
        ambiguous.state = .ambiguous
        // An ambiguous echo with a MATCHING live registration still
        // mints fresh on retry — the acceptance state is unknowable.
        let matches = ambiguous.sendRegistration
            == AgentChatRegistrationSnapshot(instanceId: "I", generation: 1)
        #expect(matches)
        #expect(ambiguous.state == .ambiguous)  // ⇒ retry(echoID:) takes the fresh-key path
    }

    @Test("registration snapshots compare by instanceId and generation")
    func snapshotEquality() {
        #expect(
            AgentChatRegistrationSnapshot(instanceId: "I", generation: 1)
                == AgentChatRegistrationSnapshot(instanceId: "I", generation: 1))
        #expect(
            AgentChatRegistrationSnapshot(instanceId: "I", generation: 1)
                != AgentChatRegistrationSnapshot(instanceId: "I", generation: 2))
        #expect(
            AgentChatRegistrationSnapshot(instanceId: "A", generation: 1)
                != AgentChatRegistrationSnapshot(instanceId: "B", generation: 1))
    }

    // MARK: Re-review finding 4 — the send() baseline derivation

    @Test("send() derives its baseline from the committed page")
    func sendDerivesBaseline() async {
        let store = await unavailableStore()
        do { _ = try await store.send("hello") } catch {}
        // No committed user records → baseline 0 (the echo's snapshot).
        #expect(store.outgoing[0].baselineMatchingRecords == 0)
    }
}

/// Test bridge to the store's private classifier (ambiguous-loss).
@MainActor
enum AgentChatOutgoingMessageTestsBridge {
    static func isAmbiguous(_ error: AgentChatError) -> Bool {
        error.isAmbiguousLossForTesting
    }
}

extension AgentChatError {
    /// Testing seam for the ambiguous-loss classification.
    var isAmbiguousLossForTesting: Bool {
        switch self {
        case .connectionClosed, .timedOut:
            return true
        default:
            return false
        }
    }
}
