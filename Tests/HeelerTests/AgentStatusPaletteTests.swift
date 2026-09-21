import Testing
import SwiftUI

@testable import Heeler

/// The status palette is the Console's only colour vocabulary: the card
/// badge and the keyboard switcher's dot both read from it, so a status must
/// never borrow another's hue — and an unreadable status must never borrow an
/// actionable one's.
@Suite("Agent status palette")
struct AgentStatusPaletteTests {
    private static let styles: [UIUserInterfaceStyle] = [.light, .dark]
    /// Both palette roles, so every invariant holds for wash and ink alike.
    private static let roles: [(String, @Sendable (AgentStatus) -> UIColor)] = [
        ("tint", { $0.tintUIColor }),
        ("ink", { $0.inkUIColor }),
    ]

    private func rgba(
        _ color: UIColor, _ style: UIUserInterfaceStyle
    ) -> [CGFloat] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }

    @Test func everyActionableStatusGetsItsOwnHue() {
        for style in Self.styles {
            for (role, color) in Self.roles {
                let tints = [AgentStatus.blocked, .done, .working, .idle].map {
                    rgba(color($0), style)
                }
                for (index, tint) in tints.enumerated() {
                    #expect(
                        !tints.dropFirst(index + 1).contains(tint),
                        "\(role) \(style)")
                }
            }
        }
    }

    /// herdr's API has no stability guarantee: a status this build cannot
    /// read must look as inert as Idle, never as loud as Blocked or Done.
    @Test func unreadableStatusesShareTheMutedTint() {
        for style in Self.styles {
            for (role, color) in Self.roles {
                let muted = rgba(color(.idle), style)
                #expect(rgba(color(.unknown), style) == muted, "\(role) \(style)")
                #expect(
                    rgba(color(AgentStatus(rawValue: "haunted")), style) == muted,
                    "\(role) \(style)")
            }
        }
    }

    /// The colours are herdr's, not UIKit's — the phone and the TUI have to
    /// agree on what green means.
    @Test func huesMatchHerdrsCatppuccinFlavours() {
        let expected: [(AgentStatus, light: UInt32, dark: UInt32)] = [
            (.blocked, light: 0xD20F39, dark: 0xF38BA8),
            (.done, light: 0x40A02B, dark: 0xA6E3A1),
            (.working, light: 0xDF8E1D, dark: 0xF9E2AF),
        ]
        for (status, light, dark) in expected {
            #expect(hex(rgba(status.tintUIColor, .light)) == light, "\(status.rawValue) light")
            #expect(hex(rgba(status.tintUIColor, .dark)) == dark, "\(status.rawValue) dark")
        }
    }

    /// The regression that prompted the ink role: Latte yellow measured
    /// 2.3:1 as badge text on its own capsule. Every ink must clear WCAG
    /// 4.5:1 for the badge's caption text over its wash, and 3:1 as the
    /// switcher's bare dot on the card background.
    @Test func inksStayLegibleOnTheirWashes() {
        let statuses = [AgentStatus.blocked, .done, .working, .idle]
        for style in Self.styles {
            // secondarySystemGroupedBackground: the Console card and the
            // terminal chrome the switcher chips sit over.
            let card: [CGFloat] =
                style == .dark
                ? [44 / 255, 44 / 255, 46 / 255, 1] : [1, 1, 1, 1]
            for status in statuses {
                let ink = rgba(status.inkUIColor, style)
                let wash = blend(
                    rgba(status.tintUIColor, style), alpha: 0.15, over: card)
                #expect(
                    contrastRatio(ink, wash) >= 4.5,
                    "\(status.rawValue) \(style) on capsule")
                #expect(
                    contrastRatio(ink, card) >= 3,
                    "\(status.rawValue) \(style) as dot")
            }
        }
    }

    private func hex(_ components: [CGFloat]) -> UInt32 {
        components.prefix(3).reduce(0) { packed, component in
            packed << 8 | UInt32((component * 255).rounded())
        }
    }

    private func blend(
        _ top: [CGFloat], alpha: CGFloat, over bottom: [CGFloat]
    ) -> [CGFloat] {
        zip(top, bottom).map { $0 * alpha + $1 * (1 - alpha) }
    }

    /// WCAG 2 contrast ratio from sRGB components.
    private func contrastRatio(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
        let (lighter, darker) = luminance(a) > luminance(b)
            ? (luminance(a), luminance(b)) : (luminance(b), luminance(a))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ components: [CGFloat]) -> CGFloat {
        let linear = components.prefix(3).map { channel in
            channel <= 0.04045
                ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
    @Test func kindTilePairIsAdaptiveAndMatchesThePrototypeHues() throws {
        // The kind tile consumes the SAME assets as every other accent
        // surface (one source of truth): AccentColor and AccentWash in
        // Assets.xcassets. Resolve both trait pairs and confirm the light
        // matches the prototype (#22644D glyph on #EAF2ED wash) and dark
        // flips to the dark pair (#9ACFB2 on #2D4236).
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        let accent = try #require(UIColor(named: "AccentColor"))
        let wash = try #require(UIColor(named: "AccentWash"))

        func rgb(_ color: UIColor, _ style: UITraitCollection) -> [Int] {
            var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
            color.resolvedColor(with: style).getRed(&r, green: &g, blue: &b, alpha: &a)
            return [Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())]
        }

        #expect(rgb(accent, light) == [0x22, 0x64, 0x4D],
            "light accent must be the prototype's #22644D")
        #expect(rgb(accent, dark) == [0x9A, 0xCF, 0xB2],
            "dark accent must be the prototype's #9ACFB2")
        #expect(rgb(wash, light) == [0xEA, 0xF2, 0xED],
            "light wash must be the prototype's #EAF2ED")
        #expect(rgb(wash, dark) == [0x2D, 0x42, 0x36],
            "dark wash must be the prototype's #2D4236")

        // The tile tokens themselves must be the same colours the asset
        // declares — the single-source contract (no re-hardcoded hexes).
        #expect(rgb(AgentKindTilePalette.accent, light) == rgb(accent, light),
            "tile accent == AccentColor (light)")
        #expect(rgb(AgentKindTilePalette.accent, dark) == rgb(accent, dark),
            "tile accent == AccentColor (dark)")
        #expect(rgb(AgentKindTilePalette.wash, light) == rgb(wash, light),
            "tile wash == AccentWash (light)")
        #expect(rgb(AgentKindTilePalette.wash, dark) == rgb(wash, dark),
            "tile wash == AccentWash (dark)")
    }

    /// The app-wide accent itself: `Color.accentColor` must resolve to the
    /// same asset pair (the tint every control inherits), not system blue.
    @Test func appAccentColorMatchesTheDesignPair() throws {
        let ui = UIColor(Color.accentColor).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(
            Int((r * 255).rounded()) == 0x22
                && Int((g * 255).rounded()) == 0x64
                && Int((b * 255).rounded()) == 0x4D,
            "Color.accentColor must resolve to #22644D in light mode")
    }

    /// Review finding (v2 accent round 1): white on the DARK-mode accent
    /// #9ACFB2 measures 1.76:1 — illegible. The pending card's Confirm
    /// button must therefore pair the accent fill with an ADAPTIVE ink:
    /// white on the light-mode accent (#22644D, 7.0:1), the prototype's
    /// dark ink #17251D on the dark-mode accent (9.06:1). Selected
    /// options use the WASH fill with primary ink (10.8:1 dark,
    /// 13.97:1 light), never white-on-accent.
    @Test func onAccentInkStaysLegibleOnBothAccents() throws {
        let accent = try #require(UIColor(named: "AccentColor"))
        let wash = try #require(UIColor(named: "AccentWash"))
        let darkInk = UIColor(red: 0x17 / 255, green: 0x25 / 255, blue: 0x1D / 255, alpha: 1)
        let white = UIColor.white

        func rgba(_ color: UIColor, _ style: UIUserInterfaceStyle) -> [CGFloat] {
            var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
            color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                .getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b, a]
        }

        // Confirm's fill/ink pairing, both appearances.
        #expect(
            Self.contrastRatio(rgba(white, .light), rgba(accent, .light)) >= 4.5,
            "white must clear 4.5:1 on the light accent #22644D")
        #expect(
            Self.contrastRatio(rgba(darkInk, .dark), rgba(accent, .dark)) >= 4.5,
            "the dark ink #17251D must clear 4.5:1 on the dark accent #9ACFB2")
        // The regression this test exists for: white on the dark accent.
        #expect(
            Self.contrastRatio(rgba(white, .dark), rgba(accent, .dark)) < 4.5,
            "white on #9ACFB2 must be recognized as illegible (1.76:1)")

        // Selected options: primary ink (white in dark, black in light)
        // on the WASH fill, both appearances.
        #expect(
            Self.contrastRatio(rgba(white, .dark), rgba(wash, .dark)) >= 4.5,
            "white must clear 4.5:1 on the dark wash #2D4236")
        #expect(
            Self.contrastRatio(
                rgba(UIColor.black, .light), rgba(wash, .light)) >= 4.5,
            "black must clear 4.5:1 on the light wash #EAF2ED")
    }

    private static func contrastRatio(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
        let (lighter, darker) = luminance(a) > luminance(b)
            ? (luminance(a), luminance(b)) : (luminance(b), luminance(a))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ components: [CGFloat]) -> CGFloat {
        let linear = components.prefix(3).map { channel in
            channel <= 0.04045
                ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

}
