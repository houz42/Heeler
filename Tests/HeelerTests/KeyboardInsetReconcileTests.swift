import UIKit
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The scene-activation reconcile pins (the reported device symptom:
// content pinned to half height with the keyboard NOT showing after a
// lock/unlock cycle). The insets pin measured heights and clear them
// only through UIKit's will-hide notification — which UIKit can swallow
// when the responder is silently dropped across the lock cycle. The
// reconcile path re-reads the window's keyboard layout guide on
// activation: zero coverage clears the stale pin, a measured keyboard
// keeps the height.

@Suite("Keyboard inset scene-activation reconcile")
@MainActor
struct KeyboardInsetReconcileTests {

    // MARK: Terminal inset

    @Test("terminal inset: a stale pinned height clears on activation with zero guide coverage")
    func terminalStalePinClearsOnActivation() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(
            notificationCenter: center, measure: { _ in 336 },
            measureWindowKeyboard: { 0 })
        // A keyboard presented and measured (336pt).
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 500, width: 402, height: 370)])
        try #require(await Self.eventually { inset.height == 336 })

        // The lock cycle swallows the will-hide: the pin stays.
        #expect(inset.height == 336)

        // Activation with NO keyboard on the window (the layout guide
        // reports zero): the reconcile clears the stale pin.
        inset.reconcileAfterSceneActivation()
        #expect(inset.height == 0)
        #expect(inset.isSoftwareKeyboardDismissed)

        // And the layout follows: contentInset falls to the live height.
        let layout = AgentComposerKeyboardLayout(
            currentHeight: inset.height,
            lastPresentedHeight: inset.lastPresentedHeight,
            presentation: .system,
            softwareKeyboardDismissed: inset.isSoftwareKeyboardDismissed)
        #expect(layout.contentInset == 0)
    }

    @Test("terminal inset: a keyboard that survived the lock cycle keeps its height")
    func terminalKeyboardSurvivingKeepsHeight() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(
            notificationCenter: center, measure: { _ in 336 },
            measureWindowKeyboard: { 336 })
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 500, width: 402, height: 370)])
        try #require(await Self.eventually { inset.height == 336 })

        // Activation with the keyboard still docked: the measured guide
        // height keeps the inset (no spurious clear under a real
        // keyboard).
        inset.reconcileAfterSceneActivation()
        #expect(inset.height == 336)
        #expect(!inset.isSoftwareKeyboardDismissed)
    }

    // MARK: Chat inset

    @Test("chat inset: reconcile without a window never corrupts measured state")
    func chatReconcileWithoutWindowIsInert() async throws {
        let center = NotificationCenter()
        let inset = ChatKeyboardInset(
            notificationCenter: center,
            measure: { _ in 300 })
        // A keyboard presented and measured (300pt).
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 600, width: 402, height: 300)])
        try #require(await Self.eventually { inset.height == 300 })

        // The lock cycle swallows the will-hide: the pin stays (the
        // reported half-height chat).
        #expect(inset.height == 300)

        // The chat inset's reconcile measures the window's layout
        // guide; with the measurement seam set (no real window) the
        // reconcile is inert — the pin stands until a real notification
        // arrives, which still clears it.
        inset.reconcileAfterSceneActivation()
        #expect(inset.height == 300)
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
    }

    private static func eventually(
        _ condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
