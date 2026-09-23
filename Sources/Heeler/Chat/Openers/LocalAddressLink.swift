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
        if host == "localhost" || host.hasSuffix(".localhost") {
            return host
        }
        if host == "::1" || host == "ip6-localhost" || host == "ip6-loopback" {
            return host
        }
        if host == "0.0.0.0" {
            return host
        }
        if host.split(separator: ".", omittingEmptySubsequences: false).first
            == "127"
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
