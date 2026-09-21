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
    /// Long enough to fold a presentation's follow-up frame into the
    /// first, short enough to stay inside the keyboard's animation.
    private static let coalesceDelay = Duration.milliseconds(60)

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        for name: Notification.Name in [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillChangeFrameNotification,
        ] {
            notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                // Notification is not Sendable; the frame it carries is.
                let endFrame = notification.userInfo?[
                    UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                MainActor.assumeIsolated {
                    self?.keyboardWillPresent(endFrame: endFrame)
                }
            }
        }
        notificationCenter.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardWillDismiss()
            }
        }
    }

    /// Measures against the window the chat surface is mounted in.
    /// Idempotent.
    func attach(to window: UIWindow) {
        guard self.window !== window else { return }
        self.window = window
    }

    private func keyboardWillPresent(endFrame: CGRect?) {
        guard let endFrame, let window else { return }
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
        let covered = window.bounds.intersection(
            window.convert(endFrame, from: window.screen.coordinateSpace)).height
        let height = max(0, covered - window.safeAreaInsets.bottom)
        guard height > 0 else { return }
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard !Task.isCancelled else { return }
            self?.apply(height)
        }
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
