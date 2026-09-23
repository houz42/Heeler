import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// The v3 "Local address unavailable" seam (design doc: V3 link UX). A
// loopback/localhost link an agent emits points at a service on the
// ORIGINATING HOST Meadow is SSH'd into — not the phone — so it must
// never be handed to the browser (a phone's loopback would silently
// serve the wrong thing or an error). Classification is pure Foundation;
// the sheet that presents the notice lives in OpenersPresenter.swift.

/// Pure classification of an http(s) URL as a loopback/local address.
/// `nil` means the URL points off-box and follows normal browse policy.
enum LocalAddressLink {
    /// The loopback host of `url`, or `nil` when the URL is external.
    ///
    /// Loopback is exactly: `localhost` (and its reserved `*.localhost`
    /// subdomains, RFC 6761), the IPv4 `127.0.0.0/8` block, the IPv6
    /// `::1` and its `/etc/hosts` aliases, and the `0.0.0.0` wildcard
    /// (connecting to it means loopback). Private LAN addresses are
    /// deliberately NOT classified local: the phone may genuinely reach
    /// them, which is the user's network call, not ours.
    static func loopbackHost(of url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        // A trailing dot is DNS-root notation for the same name
        // ("localhost." == "localhost"); normalize once, up front.
        let normalized =
            host.hasSuffix(".") ? String(host.dropLast()) : host

        // `localhost` and its reserved `*.localhost` subdomains (RFC
        // 6761) — the dot form ("app.localhost") needs the split so
        // "notlocalhost" never matches.
        if normalized == "localhost"
            || normalized.hasSuffix(".localhost")
        {
            return host
        }
        // IPv6 loopback, in every textual form URL(string:) keeps:
        // the compressed `::1` and fully-expanded runs like
        // `0:0:0:0:0:0:0:1` (URL.host reports the brackets' inner
        // text verbatim), plus the /etc/hosts aliases.
        if normalized == "::1" || normalized == "0:0:0:0:0:0:0:1"
            || normalized == "ip6-localhost" || normalized == "ip6-loopback"
        {
            return host
        }
        if normalized == "0.0.0.0" {
            return host
        }
        // IPv4 127.0.0.0/8 — but ONLY a real dotted-quad: four numeric
        // labels 0–255 with a leading 127, so `127.example.com`,
        // `127.1` (a form URL(string:) keeps but whose loopback-ness
        // shells disagree on), and `127.256.0.1` (invalid octet)
        // never over-match. Anything non-numeric anywhere is an
        // ordinary name that happens to start with "127".
        let labels = normalized.split(
            separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.first == "127",
            labels.allSatisfy({ label in
                label.allSatisfy(\.isNumber)
                    && Int(label).map { $0 <= 255 } == true
            })
        {
            return host
        }
        return nil
    }
}

/// The payload for one tapped loopback link: the selectable URL, the
/// loopback host it names, and the identity of the originating agent
/// host (whose loopback it actually is). Presented by
/// `LocalAddressUnavailableSheet`; never carries a credential beyond
/// the URL text the agent itself emitted (nothing is executed or sent).
struct LocalAddressNotice: Equatable, Sendable, Identifiable {
    /// The full tapped URL, shown selectable and copyable verbatim.
    let url: URL
    /// The loopback host the URL addresses ("localhost", "127.0.0.1", …).
    let loopbackHost: String
    /// The originating agent host's display name; `nil` when the pane
    /// never knew one (the sheet then says "the agent's host").
    let hostName: String?

    var id: String { url.absoluteString }

    /// The host-identity line the sheet shows: the real host name when
    /// known, never a guess.
    var originLabel: String { hostName ?? "the agent's host" }
}
