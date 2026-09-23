import SwiftUI
import UIKit

// SPDX-License-Identifier: Apache-2.0
//
// The chat composer's own keyboard pin (item 5, the intermittent
// composer-keyboard gap). SwiftUI's stock avoidance follows UIKit's
// keyboard-frame notifications, and a presentation whose responder
// carries an input accessory (the chat prefix-key bar) can arrive in
// TWO notifications — the keyboard's own height first, the accessory's
// added height a beat later. Between them the composer parks at the
// accessory-less frame top and the transcript shows through the strip
// below it; whether the user SEES the strip depends on notification
// ordering, which is why the device finding was intermittent.
//
// The terminal solved the same two-stage problem by measuring the
// keyboard frame directly and coalescing presentations
// (TerminalKeyboardInset); this is the chat-side counterpart with the
// same discipline, owned by Chat/UI. The composer pins to the measured
// FINAL height: one number, set once per presentation.

/// The keyboard's settled overlap with the chat surface's bottom edge.
/// Presentations coalesce (60ms, inside the keyboard's own animation):
/// the two notification stages of an accessory-bearing presentation
/// fold into one inset, so the composer never renders at the transient
/// accessory-less frame.
@MainActor
@Observable
final class ChatKeyboardInset {
    /// How far the keyboard stack covers the chat surface's bottom edge.
    private(set) var height: CGFloat = 0

    /// The window the chat surface is mounted in. Keyboard frames are
    /// window-relative and notifications are process-wide; only the
    /// chat's own window can say what its keyboard covers.
    @ObservationIgnored private weak var window: UIWindow?
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?
    @ObservationIgnored private let notificationCenter: NotificationCenter
    /// Test seam: replaces the window-bottom-edge measurement with a
    /// direct height (tests inject geometry; production passes nil and
    /// the real window is measured).
    @ObservationIgnored private let measureOverride: (@MainActor (CGRect) -> CGFloat?)?
    /// The block-based observer tokens — RETAINED: NotificationCenter
    /// holds block registrations until explicitly removed (weak self
    /// silences delivery after dealloc but never unregisters), so the
    /// tokens must live as long as the inset and be removed in deinit.
    /// nonisolated(unsafe): only deinit (nonisolated) touches it after
    /// init, and removeObserver is thread-safe.
    @ObservationIgnored nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
    /// Long enough to fold a presentation's follow-up frame into the
    /// first, short enough to stay inside the keyboard's animation.
    private static let coalesceDelay = Duration.milliseconds(60)

    init(
        notificationCenter: NotificationCenter = .default,
        measure: (@MainActor (CGRect) -> CGFloat?)? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.measureOverride = measure
        for name: Notification.Name in [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillChangeFrameNotification,
        ] {
            observerTokens.append(
                notificationCenter.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] notification in
                    // Notification is not Sendable; the frame it carries is.
                    let endFrame = notification.userInfo?[
                        UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                    MainActor.assumeIsolated {
                        self?.keyboardWillPresent(endFrame: endFrame)
                    }
                })
        }
        observerTokens.append(
            notificationCenter.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.keyboardWillDismiss()
                }
            })
    }

    /// Removes every block registration and cancels pending coalescing
    /// work. NotificationCenter keeps block observers registered across
    /// the observer's dealloc (the review's leak); tokens make the
    /// teardown explicit and complete.
    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        coalesceTask?.cancel()
    }

    /// Measures against the window the chat surface is mounted in.
    /// Idempotent.
    func attach(to window: UIWindow) {
        guard self.window !== window else { return }
        self.window = window
    }

    /// Reconciles the inset against the window's keyboard layout guide
    /// (the design doc's "clear on zero coverage"): called on scene
    /// activation (unlock/foreground) — exactly the moment UIKit can
    /// drop or swallow keyboard notifications, leaving a measured height
    /// PINNED with no keyboard visible (the reported half-height
    /// surface: content squeezed to the top half with the keyboard
    /// down). The guide rests on the bottom safe area while no keyboard
    /// is docked, so a zero guide coverage clears the stale inset.
    func reconcileAfterSceneActivation() {
        guard measureOverride == nil, let window else { return }
        let measured = TerminalKeyboardInset.layoutGuideHeight(in: window)
        if let measured {
            coalesceTask?.cancel()
            coalesceTask = nil
            apply(measured)
        }
    }

    private func keyboardWillPresent(endFrame: CGRect?) {
        guard let endFrame else { return }
        // The measurement seam (tests inject geometry; production reads
        // the chat's own window).
        if let measureOverride {
            guard let height = measureOverride(endFrame) else { return }
            if height > 0 {
                coalesceTask?.cancel()
                coalesceTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.coalesceDelay)
                    guard !Task.isCancelled else { return }
                    self?.apply(height)
                }
            } else {
                coalesceTask?.cancel()
                coalesceTask = nil
                apply(0)
            }
            return
        }
        guard let window else { return }
        // The keyboard's END frame includes the accessory: UIKit
        // publishes it in the notification's userInfo even when the
        // accessory mounts a beat after the keyboard itself. Only the
        // chat's own window's keyboard counts.
        guard let scene = window.windowScene,
            TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: window.isKeyWindow,
                isSceneKeyWindow: scene.keyWindow === window,
                activationState: scene.activationState)
        else { return }
        let frameInWindow = window.convert(
            endFrame, from: window.screen.coordinateSpace)
        // The REAL geometry, extracted (tests drive it with
        // window-geometry inputs — frame + bounds + safe area — not a
        // precomputed result):
        let height = Self.bottomEdgeCoverage(
            frameInWindow: frameInWindow,
            windowBounds: window.bounds,
            bottomSafeArea: window.safeAreaInsets.bottom)
        guard height > 0 else {
            // Zero coverage: the keyboard left the bottom edge
            // (docked→floating, off-window) or the covered height
            // collapsed to zero. CLEAR the previous inset — the review's
            // case: the earlier code discarded the update and a stale
            // height stayed pinned under a floating keyboard.
            coalesceTask?.cancel()
            coalesceTask = nil
            apply(0)
            return
        }
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard !Task.isCancelled else { return }
            self?.apply(height)
        }
    }

    /// The inset for a keyboard frame against a window's geometry:
    /// BOTTOM-EDGE obstruction only (the review's floating-keyboard
    /// case). A docked keyboard reaches the window's bottom edge (1pt
    /// tolerance) and measures its covered height above the bottom
    /// safe area; a FLOATING keyboard (mid-window hover) never touches
    /// the bottom edge and measures ZERO however large its rect is.
    /// The same zero result covers a frame that slid off the window —
    /// every non-docked state clears the inset.
    nonisolated static func bottomEdgeCoverage(
        frameInWindow: CGRect,
        windowBounds: CGRect,
        bottomSafeArea: CGFloat
    ) -> CGFloat {
        let reachesBottomEdge = abs(
            frameInWindow.maxY - windowBounds.maxY) <= 1
        guard reachesBottomEdge else { return 0 }
        let covered = windowBounds.intersection(frameInWindow).height
        return max(0, covered - bottomSafeArea)
    }

    private func keyboardWillDismiss() {
        coalesceTask?.cancel()
        coalesceTask = nil
        apply(0)
    }

    private func apply(_ height: CGFloat) {
        coalesceTask = nil
        guard height != self.height else { return }
        self.height = height
    }
}

extension View {
    /// Attaches `inset` to the window this view is mounted in, so its
    /// measurements track the chat's own window (notifications are
    /// process-wide; only the window can attribute a frame).
    func chatKeyboardInsetWindow(_ inset: ChatKeyboardInset) -> some View {
        background {
            WindowReader { inset.attach(to: $0) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
