import Foundation
import Synchronization
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The openers' pure seams: ChatLinkDetector's detection table (the tricky
// prose cases), OpenRouter's routing decisions, the per-domain allowlist's
// persistence, and OpenRouterCore's state machine against recording stubs.
// No SSH, no fixtures beyond strings — every input here is prose a chat
// pane could actually render.

// MARK: - LinkDetector table

@Suite("Chat Link Detection")
struct ChatLinkDetectorTests {
    private func detect(_ text: String) throws -> [(NSRange, ChatLinkTarget)] {
        let links = ChatLinkDetector.detect(in: text)
        links.forEach { link in
            let ns = text as NSString
            #expect(
                link.range.location + link.range.length <= ns.length,
                "range out of bounds: \(link)")
        }
        return links.map { ($0.range, $0.target) }
    }

    private func substring(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    // Bare URLs, trailing punctuation, prose wrapping

    @Test func bareURL() throws {
        let found = try detect("See https://example.com/a for details.")
        #expect(found.count == 1)
        let (range, target) = found[0]
        #expect(substring("See https://example.com/a for details.", range)
            == "https://example.com/a")
        #expect(target == .url("https://example.com/a"))
    }

    @Test func urlInParensKeepsBalancedClosingParen() throws {
        // A `(` inside the URL balances the trailing `)` — the paren belongs
        // to the URL (a real Wikipedia-style case).
        let text = "Ref (https://en.wikipedia.org/wiki/Foo_(bar)) end"
        let found = try detect(text)
        #expect(found.count == 1)
        #expect(substring(text, found[0].0) == "https://en.wikipedia.org/wiki/Foo_(bar)")
    }

    @Test func urlInParensStripsUnbalancedClosingParen() throws {
        let text = "Docs at (https://example.com/page)."
        let found = try detect(text)
        #expect(found.count == 1)
        #expect(substring(text, found[0].0) == "https://example.com/page")
    }

    @Test func trailingSentencePunctuationStripped() throws {
        let found = try detect("Read https://example.com/plan.md, then reply.")
        #expect(found.count == 1)
        #expect(found[0].1 == .url("https://example.com/plan.md"))
    }


    @Test func softWrapNeverJoinsAcrossLineBreak() throws {
        // ADR-0010: real line breaks are never guessed away. A URL wrapped
        // mid-token across lines opens only its complete fragment.
        let text = "Broken https://example.com/very\nlong/path here."
        let found = try detect(text)
        #expect(found.count == 1)
        #expect(found[0].1 == .url("https://example.com/very"))
    }

    @Test func noSchemeNoLink() throws {
        #expect(try detect("just example.com text").isEmpty)
        #expect(try detect("ftp://files.example.com/x").isEmpty)
        #expect(try detect("mailto:a@b.example").isEmpty)
    }

    @Test func wwwFormCanonicalizesScheme() throws {
        let found = try detect("Go to www.example.com now.")
        #expect(found.count == 1)
        guard case .url(let raw) = found[0].1 else {
            Issue.record("expected url target")
            return
        }
        // NSDataDetector canonicalizes the bare `www.` form to http.
        #expect(raw.lowercased().hasPrefix("http://www.example.com"))
    }

    @Test func markdownLinkClaimsWholeConstruct() throws {
        let text = "See [the docs](https://example.com/docs) for more."
        let found = try detect(text)
        #expect(found.count == 1)
        #expect(substring(text, found[0].0) == "[the docs](https://example.com/docs)")
        #expect(found[0].1 == .url("https://example.com/docs"))
    }

    @Test func markdownLinkTargetIsNotDoubleCounted() throws {
        // The URL inside the parens must not produce a second link.
        let text = "[x](https://example.com/a)"
        #expect(try detect(text).count == 1)
    }

    @Test func markdownLinkWithAbsolutePathTarget() throws {
        let text = "Edit [the config](/etc/herdr/config.toml) please."
        let found = try detect(text)
        #expect(found.count == 1)
        #expect(found[0].1 == .path("/etc/herdr/config.toml"))
    }

    @Test func markdownLinkUnrecognizedTargetClaimedButSilent() throws {
        // A relative target keeps the construct claimed (no phantom URL
        // from the label) but opens nothing.
        let text = "See [here](relative/x) now."
        #expect(try detect(text).isEmpty)
    }

    // Absolute POSIX paths

    @Test func barePath() throws {
        let found = try detect("Wrote it to /tmp/report.md earlier.")
        #expect(found.count == 1)
        #expect(found[0].1 == .path("/tmp/report.md"))
    }

    @Test func pathWithEscapedSpaces() throws {
        let text = "See /Users/jhou/My\\ Files/plan.md for the plan."
        let found = try detect(text)
        #expect(found.count == 1)
        guard case .path(let path) = found[0].1 else {
            Issue.record("expected path target")
            return
        }
        #expect(path == "/Users/jhou/My Files/plan.md")
        #expect(substring(text, found[0].0) == "/Users/jhou/My\\ Files/plan.md")
    }

    @Test func pathAfterSentencePunctuation() throws {
        let found = try detect("Config: /etc/nginx/nginx.conf, reload after.")
        #expect(found.count == 1)
        #expect(found[0].1 == .path("/etc/nginx/nginx.conf"))
    }

    @Test func relativePathNotDetected() throws {
        #expect(try detect("the file ./local/notes.md is here").isEmpty)
        #expect(try detect("see docs/readme.md here").isEmpty)
    }

    @Test func commentSlashesNotDetected() throws {
        #expect(try detect("a // b").isEmpty)
        #expect(try detect("x /* y */ z").isEmpty)
    }

    @Test func httpURLIsNotAlsoAPath() throws {
        // The URL phase claims its range first; the path scanner must not
        // register a second target inside it.
        let text = "Open https://example.com/a/b.md now."
        let found = try detect(text)
        #expect(found.count == 1)
        #expect(found[0].1 == .url("https://example.com/a/b.md"))
    }

    @Test func pathTrailingPunctuationStripped() throws {
        let found = try detect("Saved /tmp/out.txt.")
        #expect(found.count == 1)
        #expect(found[0].1 == .path("/tmp/out.txt"))
    }

    // URL↔target round-trip

    @Test func pathTargetRoundTripsThroughLinkURL() throws {
        let target = ChatLinkTarget.path("/Users/jhou/My Files/plan.md")
        let decoded = ChatLinkTarget(linkURL: target.linkURL)
        #expect(decoded == target)
    }

    @Test func urlTargetRoundTripsThroughLinkURL() throws {
        let target = ChatLinkTarget.url("https://example.com/a b")
            // (A space in a bare URL cannot survive URL(string:) — the
            // detector would not emit this; use an encodable form.)
        _ = target
        let encodable = ChatLinkTarget.url("https://example.com/a?q=1")
        #expect(ChatLinkTarget(linkURL: encodable.linkURL) == encodable)
    }

    @Test func oversizeTargetIgnored() throws {
        // A target over the ADR-0010 cap is ignored rather than truncated.
        let long = String(repeating: "a", count: ChatLinkDetector.maximumTargetLength)
        let text = "x /\(long).md y"
        #expect(try detect(text).isEmpty)
    }
}

// MARK: - OpenRouter routing

@Suite("Open Router Routing")
struct OpenRouterRoutingTests {
    @Test func httpRoutesToBrowse() {
        let action = OpenRouter.route(
            .url("https://example.com/page"), embeddedBrowseAllowed: nil)
        #expect(
            action == .browse(
                url: URL(string: "https://example.com/page")!, allowed: nil))
    }

    @Test func allowedDomainCarriesDecision() {
        let action = OpenRouter.route(
            .url("https://example.com/page"), embeddedBrowseAllowed: true)
        #expect(action == .browse(url: URL(string: "https://example.com/page")!, allowed: true))
    }

    @Test func refusedDomainCarriesDecision() {
        let action = OpenRouter.route(
            .url("https://example.com/page"), embeddedBrowseAllowed: false)
        #expect(action == .browse(url: URL(string: "https://example.com/page")!, allowed: false))
    }

    @Test func nonHTTPURLReturnsNil() {
        #expect(OpenRouter.route(.url("ftp://example.com/x"), embeddedBrowseAllowed: nil) == nil)
        #expect(OpenRouter.route(.url("not a url"), embeddedBrowseAllowed: nil) == nil)
    }

    @Test func markdownPathRoutesToViewer() {
        #expect(
            OpenRouter.route(.path("/home/me/README.md"), embeddedBrowseAllowed: nil)
                == .viewMarkdown(path: "/home/me/README.md"))
        #expect(
            OpenRouter.route(.path("/home/me/notes.MD"), embeddedBrowseAllowed: nil)
                == .viewMarkdown(path: "/home/me/notes.MD"))
    }

    @Test func otherPathRoutesToShare() {
        #expect(
            OpenRouter.route(.path("/tmp/data.csv"), embeddedBrowseAllowed: nil)
                == .shareFile(path: "/tmp/data.csv"))
    }

    @Test func silentFetchCeiling() {
        #expect(OpenRouter.allowsSilentFetch(byteCount: 0))
        #expect(OpenRouter.allowsSilentFetch(byteCount: OpenRouter.maximumSilentFetchBytes))
        #expect(!OpenRouter.allowsSilentFetch(byteCount: OpenRouter.maximumSilentFetchBytes + 1))
    }

    @Test func localhostURLRoutesToLocalNotice() {
        let action = OpenRouter.route(
            .url("http://localhost:4173/preview"), embeddedBrowseAllowed: nil)
        guard case .localAddress(let notice) = action else {
            Issue.record("expected localAddress, got \(String(describing: action))")
            return
        }
        #expect(notice.loopbackHost == "localhost")
        #expect(notice.url.absoluteString == "http://localhost:4173/preview")
    }

    @Test func loopbackIPRoutesToLocalNotice() {
        for raw in [
            "http://127.0.0.1:8080/", "https://127.1.2.3/x",
            "http://0.0.0.0:3000", "http://app.localhost:9222",
        ] {
            guard case .localAddress = OpenRouter.route(
                .url(raw), embeddedBrowseAllowed: true)
            else {
                Issue.record("\(raw) must classify as a local address")
                continue
            }
        }
    }

    @Test func externalURLsNeverClassifyLocal() {
        // The phone may genuinely reach LAN addresses — that is the
        // user's network call, not ours.
        for raw in [
            "https://example.com/a", "http://192.168.1.4:8080",
            "https://10.0.0.5/x", "http://172.17.0.2:3000",
            "http://notlocalhost.example/", "http://localhost.com.evil.io/",
        ] {
            guard case .browse = OpenRouter.route(
                .url(raw), embeddedBrowseAllowed: nil)
            else {
                Issue.record("\(raw) must NOT classify as a local address")
                continue
            }
        }
    }
}

// MARK: - Allowlist persistence

@Suite("Chat Link Allowlist")
struct ChatLinkAllowlistTests {
    private func freshDefaults() throws -> UserDefaults {
        let name = "dev.houz42.meadow.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)
        defaults?.removePersistentDomain(forName: name)
        return defaults ?? .standard
    }

    @Test func defaultDecisionIsAsk() throws {
        let store = ChatLinkAllowlistStore(defaults: try freshDefaults())
        #expect(store.allowsEmbeddedBrowse(host: "example.com") == nil)
    }

    @Test func allowPersistsPerDomain() throws {
        let defaults = try freshDefaults()
        let store = ChatLinkAllowlistStore(defaults: defaults)
        store.setAllowsEmbeddedBrowse(true, host: "Example.COM")
        #expect(store.allowsEmbeddedBrowse(host: "example.com") == true)
        #expect(store.allowsEmbeddedBrowse(host: "other.com") == nil)
    }

    @Test func refusalPersistsIndependently() throws {
        let defaults = try freshDefaults()
        let store = ChatLinkAllowlistStore(defaults: defaults)
        store.setAllowsEmbeddedBrowse(true, host: "a.com")
        store.setAllowsEmbeddedBrowse(false, host: "b.com")
        #expect(store.allowsEmbeddedBrowse(host: "a.com") == true)
        #expect(store.allowsEmbeddedBrowse(host: "b.com") == false)
    }

    @Test func corruptedValueDegradesToDecisionNeverCrash() throws {
        let defaults = try freshDefaults()
        let store = ChatLinkAllowlistStore(defaults: defaults)
        // A hand-planted wrong-typed value reads back through bool() as
        // some decision; the explicit presence check keeps a truly absent
        // key an "ask". Corrupt values degrade to a decision, never a crash.
        defaults.set(7, forKey: ChatLinkAllowlistStore.key(host: "x.com"))
        let decision = store.allowsEmbeddedBrowse(host: "x.com")
        #expect(decision == true || decision == false)
    }

    @Test func keyIsNamespacedAndHostSafe() {
        let key = ChatLinkAllowlistStore.key(host: "we.ird/host")
        #expect(key.hasPrefix("embeddedBrowse."))
        // The host cannot forge a collision with another host's key.
        #expect(key != ChatLinkAllowlistStore.key(host: "we.ird"))
    }
}

// MARK: - OpenRouterCore state machine (recording stubs)

@Suite("Open Router Core")
@MainActor
struct OpenRouterCoreTests {
    /// A fetch over one in-memory file map, recording every requested path
    /// so routing decisions are observable from the stub side.
    private final class RecordingFetcher: @unchecked Sendable {
        let requested = Mutex<[String]>([])
        private let files: [String: Data]
        private let error: Error?

        init(files: [String: Data] = [:], error: Error? = nil) {
            self.files = files
            self.error = error
        }

        var closure: RemoteFileFetcher {
            { [self] path in
                self.requested.withLock { $0.append(path) }
                if let error { throw error }
                return self.files[path] ?? Data()
            }
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "dev.houz42.meadow.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)
        defaults?.removePersistentDomain(forName: name)
        return defaults ?? .standard
    }

    @Test func allowedDomainPresentsSafariImmediately() throws {
        let defaults = try makeDefaults()
        let store = ChatLinkAllowlistStore(defaults: defaults)
        store.setAllowsEmbeddedBrowse(true, host: "example.com")
        let router = OpenRouterCore(allowlist: store)
        router.open(.url("https://example.com/page"))
        #expect(router.browsing == URL(string: "https://example.com/page"))
        #expect(router.ask == nil)
        #expect(router.lastAction == .browse(
            url: URL(string: "https://example.com/page")!, allowed: true))
    }

    @Test func refusedDomainRoutesToDefaultBrowser() throws {
        let defaults = try makeDefaults()
        let store = ChatLinkAllowlistStore(defaults: defaults)
        store.setAllowsEmbeddedBrowse(false, host: "example.com")
        let router = OpenRouterCore(allowlist: store)
        router.open(.url("https://example.com/page"))
        #expect(router.browsing == nil)
        #expect(router.ask == nil)
        #expect(router.defaultBrowserCandidate == URL(string: "https://example.com/page"))
    }

    @Test func unknownDomainAsks() throws {
        let router = OpenRouterCore(
            allowlist: ChatLinkAllowlistStore(defaults: try makeDefaults()))
        router.open(.url("https://fresh.example/page"))
        #expect(router.ask == URL(string: "https://fresh.example/page"))
        #expect(router.browsing == nil)
        #expect(router.defaultBrowserCandidate == nil)
    }

    @Test func askResolvedEmbeddedPersistsAndPresents() throws {
        let defaults = try makeDefaults()
        let store = ChatLinkAllowlistStore(defaults: defaults)
        let router = OpenRouterCore(allowlist: store)
        router.open(.url("https://fresh.example/page"))
        router.resolveBrowse(url: URL(string: "https://fresh.example/page")!, embedded: true)
        #expect(router.ask == nil)
        #expect(router.browsing == URL(string: "https://fresh.example/page"))
        #expect(store.allowsEmbeddedBrowse(host: "fresh.example") == true)
        // And the next open on the same domain no longer asks.
        router.open(.url("https://fresh.example/other"))
        #expect(router.ask == nil)
        #expect(router.browsing == URL(string: "https://fresh.example/other"))
    }

    @Test func askCancelledRoutesToDefaultBrowserWithoutPersisting() throws {
        let defaults = try makeDefaults()
        let store = ChatLinkAllowlistStore(defaults: defaults)
        let router = OpenRouterCore(allowlist: store)
        router.open(.url("https://fresh.example/page"))
        router.cancelBrowseAsk()
        #expect(router.ask == nil)
        #expect(router.defaultBrowserCandidate == URL(string: "https://fresh.example/page"))
        // No decision persisted: the next tap asks again.
        router.open(.url("https://fresh.example/page"))
        #expect(router.ask == URL(string: "https://fresh.example/page"))
    }

    @Test func markdownPathFetchesSilentlyThenPresents() async throws {
        let fetcher = RecordingFetcher(files: [
            "/home/me/README.md": Data("# Hello\n\nWorld".utf8),
        ])
        let router = OpenRouterCore(
            allowlist: ChatLinkAllowlistStore(defaults: try makeDefaults()))
        router.fetch = fetcher.closure
        router.open(.path("/home/me/README.md"))
        #expect(router.markdown == nil)  // silent: nothing while fetching
        try await waitFor { router.markdown != nil }
        #expect(router.markdown?.contents == "# Hello\n\nWorld")
        #expect(router.markdown?.fileName == "README.md")
        #expect(fetcher.requested.withLock { $0 } == ["/home/me/README.md"])
    }

    @Test func markdownFetchFailureShowsRefusalNotMarkdown() async throws {
        struct Boom: Error {}
        let fetcher = RecordingFetcher(error: Boom())
        let router = OpenRouterCore(
            allowlist: ChatLinkAllowlistStore(defaults: try makeDefaults()))
        router.fetch = fetcher.closure
        router.open(.path("/gone/README.md"))
        try await waitFor { router.refusal != nil }
        #expect(router.markdown == nil)
        #expect(router.refusal?.contains("/gone/README.md") == true)
    }

    @Test func oversizeMarkdownRefusesSilently() async throws {
        let oversize = Data(repeating: 0x61, count: OpenRouter.maximumSilentFetchBytes + 1)
        let fetcher = RecordingFetcher(files: ["/big/doc.md": oversize])
        let router = OpenRouterCore(
            allowlist: ChatLinkAllowlistStore(defaults: try makeDefaults()))
        router.fetch = fetcher.closure
        router.open(.path("/big/doc.md"))
        try await waitFor { router.refusal != nil || router.markdown != nil }
        #expect(router.markdown == nil)
        #expect(router.refusal == MarkdownViewerView.tooLargeMessage)
    }

    @Test func otherRemotePathPresentsShareFlowWithoutFetching() throws {
        let fetcher = RecordingFetcher()
        let router = OpenRouterCore(
            allowlist: ChatLinkAllowlistStore(defaults: try makeDefaults()))
        router.fetch = fetcher.closure
        router.open(.path("/tmp/data.csv"))
        #expect(router.shareTarget == RemoteShareTarget(path: "/tmp/data.csv"))
        #expect(fetcher.requested.withLock { $0 }.isEmpty)
    }

    @Test func invalidURLTargetSetsRefusal() throws {
        let router = OpenRouterCore(
            allowlist: ChatLinkAllowlistStore(defaults: try makeDefaults()))
        router.open(.url("not a url"))
        #expect(router.refusal != nil)
        #expect(router.lastAction == nil)
    }

    @Test func localhostLinkPresentsNoticeWithHostName() throws {
        let router = OpenRouterCore(
            allowlist: ChatLinkAllowlistStore(defaults: try makeDefaults()))
        router.hostName = "Studio Mac"
        router.open(.url("http://localhost:4173/preview"))
        #expect(router.localNotice?.originLabel == "Studio Mac")
        #expect(router.localNotice?.loopbackHost == "localhost")
        #expect(router.localNotice?.url
            == URL(string: "http://localhost:4173/preview"))
        // NEVER a browser path for a loopback link.
        #expect(router.browsing == nil)
        #expect(router.ask == nil)
        #expect(router.defaultBrowserCandidate == nil)
    }

    @Test func localhostNoticeWithoutHostNameNeverGuesses() throws {
        let router = OpenRouterCore(
            allowlist: ChatLinkAllowlistStore(defaults: try makeDefaults()))
        router.open(.url("http://127.0.0.1:9222"))
        #expect(router.localNotice?.hostName == nil)
        #expect(router.localNotice?.originLabel == "the agent's host")
    }

    @Test func dismissingLocalNoticeKeepsRouterClean() throws {
        let router = OpenRouterCore(
            allowlist: ChatLinkAllowlistStore(defaults: try makeDefaults()))
        router.hostName = "Studio Mac"
        router.open(.url("http://localhost:4173/preview"))
        router.dismissLocalNotice()
        #expect(router.localNotice == nil)
        // A subsequent loopback tap presents again (Close preserved
        // nothing stale).
        router.open(.url("http://localhost:4173/preview"))
        #expect(router.localNotice?.originLabel == "Studio Mac")
    }

    @Test func allowlistDecisionNeverOverridesLoopbackRefusal() throws {
        // Even a domain persisted "Open Here" must not open a
        // localhost link embedded — classification precedes policy.
        let defaults = try makeDefaults()
        let store = ChatLinkAllowlistStore(defaults: defaults)
        store.setAllowsEmbeddedBrowse(true, host: "localhost")
        let router = OpenRouterCore(allowlist: store)
        router.open(.url("http://localhost:4173/preview"))
        #expect(router.browsing == nil)
        #expect(router.localNotice != nil)
    }

    @Test func loopbackEdgeFormsReviewPins() {
        // Review finding 1: the trailing-dot root form, the expanded
        // IPv6 loopback run, and the FALSE positives a prefix match
        // used to let through.
        for raw in [
            "http://localhost.:8080/", "http://app.localhost.:9222",
            "http://[0:0:0:0:0:0:0:1]:80/", "http://127.0.0.1.:3000",
        ] {
            guard case .localAddress = OpenRouter.route(
                .url(raw), embeddedBrowseAllowed: nil)
            else {
                Issue.record("\(raw) must classify as a local address")
                continue
            }
        }
        // A host that merely STARTS with 127 is an ordinary name —
        // never blocked.
        for raw in [
            "http://127.example.com/x", "http://127.1/x",
            "http://127.256.0.1/x",
        ] {
            guard case .browse = OpenRouter.route(
                .url(raw), embeddedBrowseAllowed: nil)
            else {
                Issue.record("\(raw) must NOT classify as a local address")
                continue
            }
        }
    }

    @Test func swipeDismissClearsRouterNoticeForRetrigger() throws {
        // Review finding 2: the sheet's binding writes nil back to
        // the router on ANY dismissal, so an identical URL re-triggers.
        let router = OpenRouterCore(
            allowlist: ChatLinkAllowlistStore(defaults: try makeDefaults()))
        router.open(.url("http://localhost:4173/preview"))
        #expect(router.localNotice != nil)
        // The sheet's set(nil) — what a swipe-down performs.
        router.dismissLocalNotice()
        #expect(router.localNotice == nil)
        // The SAME URL opens again (no stale state left behind).
        router.open(.url("http://localhost:4173/preview"))
        #expect(router.localNotice != nil)
    }


    @Test func dismissingMarkdownCancelsInflightFetch() async throws {
        let fetcher = RecordingFetcher(files: ["/home/me/README.md": Data("x".utf8)])
        let router = OpenRouterCore(
            allowlist: ChatLinkAllowlistStore(defaults: try makeDefaults()))
        router.fetch = fetcher.closure
        router.open(.path("/home/me/README.md"))
        router.dismissMarkdown()
        #expect(router.markdown == nil)
        // A subsequent open re-arms cleanly.
        router.open(.path("/home/me/README.md"))
        try await waitFor { router.markdown != nil }
    }

    /// Polls until `condition` holds, bounded, on the main actor.
    private func waitFor(
        _ condition: @MainActor () -> Bool, timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("waitFor timed out")
    }
}
