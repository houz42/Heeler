import Foundation
import Splash
import SwiftUI

// SPDX-License-Identifier: Apache-2.0
//
// Semantic syntax coloring for chat code blocks, on Splash (Swift-only
// grammar, MIT). MarkdownUI's `codeBlock` configuration carries the raw
// code string plus the fence's language tag — everything needed to hand
// the block to a highlighter. Only `swift` code is colored; any other
// language (or none) renders as plain monospace, the honest fallback for
// a Swift-only grammar.

/// The seam between MarkdownUI's code-block configuration and Splash:
/// `code` in, an attributed string with per-token foreground colors out.
/// Light/dark handled by the caller (the view reads the environment and
/// picks the token palette); this type is pure, so tests drive it
/// without a view.
enum ChatCodeHighlighter {
    /// One RGB color, Hashable where Splash's UIKit alias isn't.
    struct RGB: Hashable {
        let red: Double
        let green: Double
        let blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// One token color per Splash `TokenType`, in the chat theme.
    struct Palette: Hashable {
        let plain: RGB
        let keyword: RGB
        let string: RGB
        let type: RGB
        let call: RGB
        let number: RGB
        let comment: RGB
        let property: RGB
        let dotAccess: RGB
        let preprocessing: RGB
    }


    /// Charts' light scheme: keyword orange-red, string red, type/call
    /// blue, number purple, comment gray.
    static let light = Palette(
        plain: RGB(0.11, 0.11, 0.12),
        keyword: RGB(0.79, 0.18, 0.13),
        string: RGB(0.72, 0.14, 0.13),
        type: RGB(0.08, 0.26, 0.62),
        call: RGB(0.08, 0.26, 0.62),
        number: RGB(0.42, 0.17, 0.64),
        comment: RGB(0.42, 0.42, 0.45),
        property: RGB(0.08, 0.26, 0.62),
        dotAccess: RGB(0.08, 0.26, 0.62),
        preprocessing: RGB(0.42, 0.17, 0.64))

    /// Chat dark scheme: keyword orange, string coral, type/call mint,
    /// number purple, comment sage.
    static let dark = Palette(
        plain: RGB(0.93, 0.93, 0.95),
        keyword: RGB(0.95, 0.54, 0.17),
        string: RGB(1.0, 0.45, 0.40),
        type: RGB(0.48, 0.83, 0.90),
        call: RGB(0.48, 0.83, 0.90),
        number: RGB(0.72, 0.55, 0.95),
        comment: RGB(0.55, 0.62, 0.48),
        property: RGB(0.48, 0.83, 0.90),
        dotAccess: RGB(0.48, 0.83, 0.90),
        preprocessing: RGB(0.72, 0.55, 0.95))

    /// Whether a fence language tag selects Swift highlighting. The
    /// fence info string may carry extra tokens (`swift foo`); the first
    /// word decides.
    static func highlightsSwift(language: String?) -> Bool {
        guard let first = language?
            .split(separator: " ").first.map(String.init)?
            .lowercased()
        else { return false }
        return first == "swift"
    }

    /// Swift code with per-token colors applied. Callers gate on
    /// `highlightsSwift` for the fence language.
    static func attributed(
        _ code: String, palette: Palette, font: Splash.Font
    ) -> AttributedString {
        let theme = Splash.Theme(
            font: font,
            plainTextColor: color(palette.plain),
            tokenColors: [
                .keyword: color(palette.keyword),
                .string: color(palette.string),
                .type: color(palette.type),
                .call: color(palette.call),
                .number: color(palette.number),
                .comment: color(palette.comment),
                .property: color(palette.property),
                .dotAccess: color(palette.dotAccess),
                .preprocessing: color(palette.preprocessing),
            ])
        let highlighted = SyntaxHighlighter(
            format: AttributedStringOutputFormat(theme: theme)
        ).highlight(code)
        return AttributedString(highlighted)
    }

    private static func color(_ rgb: RGB) -> Splash.Color {
        Splash.Color(
            red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }
}
