import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Routes a tapped chat link to its surface, split in two files:
//
//   OpenRouter.swift    (this file) — the pure core. Routing decisions and
//                      the silent-fetch ceiling are static and testable on
//                      any platform; `OpenRouterCore` holds the live
//                      presentation state an OpenersPresenter interprets.
//   OpenersPresenter.swift — the UIKit/Safari surfaces (SFSafari embedded,
//                      sheets, alerts) driven by the core's state.
//
// Remote→local transfers are silent below the fetch cap: the markdown fetch
// shows no progress UI and fails with the pane's alert affordance if the
// transport cannot deliver. ADR-0011's one-SFTP-channel-per-op rule makes
// a single whole-file read the right shape.

/// Where the markdown viewer's fetch closure lives: the view wiring injects
/// `Transport.readTranscriptFile`-shaped fetches (whole-file silent reads);
/// tests inject closures over in-memory Data.
typealias RemoteFileFetcher = @Sendable (_ path: String) async throws -> Data

/// One fetched markdown document for the internal viewer.
struct MarkdownDocument: Equatable, Sendable, Identifiable {
    let path: String
    let contents: String

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// A remote file chosen for the download-then-share flow.
struct RemoteShareTarget: Equatable, Sendable, Identifiable {
    let path: String

    var id: String { path }
}

/// Why an open refused (or asked): either a URL awaiting the
/// embedded-vs-default-browser decision, or a plain refusal message.
struct OpenFailure: Equatable, Sendable, Identifiable {
    let askURL: URL?
    let reason: String?

    var id: String { askURL?.absoluteString ?? reason ?? "" }

    static func askURL(_ url: URL) -> OpenFailure {
        OpenFailure(askURL: url, reason: nil)
    }
}

/// Pure routing: which action a target resolves to, given the domain's
/// persisted allow decision (`nil` = ask). Enumerated as a namespace so
/// the whole decision table is testable without UIKit.
enum OpenRouter {
    /// Transfers at or below this many bytes fetch silently; larger opens
    /// refuse rather than present progress UI (v1's ceiling).
    static let maximumSilentFetchBytes: Int = 10 * 1024 * 1024

    static func allowsSilentFetch(byteCount: Int) -> Bool {
        byteCount <= maximumSilentFetchBytes
    }

    /// Which action a `ChatLinkTarget` opens. `nil` when the target is
    /// malformed (an unparsable URL).
    static func route(
        _ target: ChatLinkTarget, embeddedBrowseAllowed: Bool?
    ) -> OpenerAction? {
        switch target {
        case .url(let raw):
            guard let url = URL(string: raw),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else { return nil }
            return .browse(url: url, allowed: embeddedBrowseAllowed)
        case .path(let path):
            if path.lowercased().hasSuffix(".md") {
                return .viewMarkdown(path: path)
            }
            return .shareFile(path: path)
        }
    }
}

/// The live routing state for one chat pane: what is presented right now
/// and why. The presenter view interprets it; tests drive it directly.
@MainActor
final class OpenRouterCore: ObservableObject {
    @Published private(set) var browsing: URL?
    @Published private(set) var markdown: MarkdownDocument?
    @Published private(set) var shareTarget: RemoteShareTarget?
    /// A URL awaiting the embedded-vs-default decision (the ask sheet).
    @Published private(set) var ask: URL?
    /// A plain refusal message (the alert).
    @Published private(set) var refusal: String?
    /// The URL the pane should hand to `\.openURL` (default browser).
    /// The consuming view clears it after forwarding.
    @Published private(set) var defaultBrowserCandidate: URL?

    private(set) var lastAction: OpenerAction?
    private var fetchTask: Task<Void, Never>?

    private let allowlist: ChatLinkAllowlistStore

    init(allowlist: ChatLinkAllowlistStore = .shared) {
        self.allowlist = allowlist
    }

    /// Routes and presents one tapped target: URL targets present
    /// immediately (embedded view when the domain is allowed, ask sheet
    /// otherwise); markdown paths fetch silently then present the viewer;
    /// other remote paths present the share flow.
    func open(_ target: ChatLinkTarget) {
        let allowed = allowDecision(for: target)
        guard let action = OpenRouter.route(target, embeddedBrowseAllowed: allowed)
        else {
            refusal = "This link is not a valid web address."
            lastAction = nil
            return
        }
        lastAction = action
        switch action {
        case .browse(let url, let allowed):
            if allowed == true {
                browsing = url
            } else if allowed == false {
                defaultBrowserCandidate = url
            } else {
                ask = url
            }
        case .viewMarkdown(let path):
            fetchMarkdown(at: path)
        case .shareFile(let path):
            shareTarget = RemoteShareTarget(path: path)
        }
    }

    /// The ask sheet's decision: open embedded (persisting the allow) or
    /// hand off to the default browser.
    func resolveBrowse(url: URL, embedded: Bool) {
        ask = nil
        if let host = url.host {
            allowlist.setAllowsEmbeddedBrowse(embedded, host: host)
        }
        if embedded {
            browsing = url
        } else {
            defaultBrowserCandidate = url
        }
    }

    /// The ask sheet dismissed without a choice: keep the default-browser
    /// route but persist no decision (asks again next time).
    func cancelBrowseAsk() {
        guard let url = ask else { return }
        ask = nil
        defaultBrowserCandidate = url
    }

    func dismissBrowse() { browsing = nil }
    func dismissMarkdown() {
        fetchTask?.cancel()
        fetchTask = nil
        markdown = nil
    }
    func dismissShareTarget() { shareTarget = nil }
    func clearDefaultBrowserCandidate() { defaultBrowserCandidate = nil }
    func clearRefusal() { refusal = nil }

    private func allowDecision(for target: ChatLinkTarget) -> Bool? {
        guard case .url(let raw) = target,
            let url = URL(string: raw), let host = url.host
        else { return nil }
        return allowlist.allowsEmbeddedBrowse(host: host)
    }

    /// Silent remote fetch: no progress UI, cancellation-safe, one failure
    /// alert if the transport cannot deliver.
    private func fetchMarkdown(at path: String) {
        fetchTask?.cancel()
        markdown = nil
        let fetch = self.fetch
        fetchTask = Task { [weak self] in
            do {
                let data = try await fetch(path)
                guard let self, !Task.isCancelled else { return }
                guard OpenRouter.allowsSilentFetch(byteCount: data.count) else {
                    self.refusal = MarkdownViewerView.tooLargeMessage
                    return
                }
                self.markdown = MarkdownDocument(
                    path: path, contents: String(decoding: data, as: UTF8.self))
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.refusal = "Couldn't read \(path) on the host. It may be missing."
            }
        }
    }

    /// The silent remote-file fetch (Transport.readTranscriptFile in
    /// production; in-memory closures in tests). Injectable after init so
    /// the pane wiring can construct the router before the transport.
    var fetch: RemoteFileFetcher = { _ in
        throw CocoaError(.fileNoSuchFile)
    }
}
