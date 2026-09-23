import Foundation
import Testing

@testable import Heeler

/// The address classes iOS gates behind the Local Network permission
/// (WWDC 20). Every dial consults this classification before probing, so a
/// wrong mask either prompts needlessly (global addresses) or silently
/// skips the prompt (private ones) — the exact bug this file pins down.
struct LocalNetworkPermissionTests {
    @Test(arguments: [
        // RFC 1918 — the LAN path this whole feature is about.
        ("192.168.31.71", true),
        ("10.0.0.1", true),
        // 172.16/12 mask boundaries: the block starts at 172.16, ends 172.31.
        ("172.15.255.255", false),
        ("172.16.0.0", true),
        ("172.29.228.247", true),
        ("172.31.255.255", true),
        ("172.32.0.0", false),
        // Loopback — the E2E fixtures' sshd and Jump Host tunnels — never gated.
        ("127.0.0.1", false),
        // CGNAT 100.64/10 mask boundaries.
        ("100.63.255.255", false),
        ("100.64.0.0", true),
        ("100.127.255.255", true),
        ("100.128.0.0", false),
        // Link-local.
        ("169.254.1.1", true),
        // Global addresses are never gated.
        ("8.8.8.8", false),
        ("1.2.3.4", false),
        // IPv6: loopback exempt, ULA and link-local gated.
        ("::1", false),
        ("fd00::1", true),
        ("fc00::1", true),
        ("fe80::1", true),
        ("2001:db8::1", false),
        // IPv4-mapped IPv6: the embedded IPv4 decides.
        ("::ffff:192.168.31.71", true),
        ("::ffff:8.8.8.8", false),
        // Hostnames: cannot know where they resolve, so they probe.
        ("jhou-pc", true),
        ("CMF79KM7YF.local", true),
        ("example.com", true),
        // Empty is not an address; treating it as needing the probe is
        // safe (the dial fails on its own terms either way).
        ("", true),
    ])
    func addressClassification(address: String, gated: Bool) {
        #expect(LocalNetworkPermission.isRequired(for: address) == gated)
    }
}
