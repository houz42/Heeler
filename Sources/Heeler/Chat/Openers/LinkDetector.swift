import Foundation

// SPDX-License-Identifier: Apache-2.0
//
// Pure detection of tappable targets in chat text, applying ADR-0010's
// lessons to the chat surface: real line breaks are never guessed away (a
// URL wrapped mid-token across lines opens only its complete fragment),
// targets over 32 KiB are ignored, and detection owns no UI. Foundation
// only, so the whole table is verifiable with standalone runners.
//
// Order matters: markdown `[label](target)` constructs claim their range
// first, then `NSDataDetector` finds bare URLs outside those ranges, and
// the path scanner runs last with both claimed ranges masked out — a URL
// like `https://example.com/a/b` must not also register as a path.

/// What one detected link opens.
enum ChatLinkTarget: Equatable, Hashable, Sendable {
    /// An http(s) URL (canonicalized to a full scheme for `www.` forms).
    case url(String)
    /// An absolute POSIX path on the Host, with backslash escapes resolved
    /// (`/a\ b.md` opens `/a b.md`).
    case path(String)

    private static let pathScheme = "heeler-chat"
    private static let pathHost = "file"

    /// The URL a SwiftUI `Text` link carries: real URLs pass through; paths
    /// ride a private scheme because `Text` links must be URLs.
    var linkURL: URL {
        switch self {
        case .url(let raw):
            return URL(string: raw) ?? URL(string: "about:blank")!
        case .path(let path):
            var components = URLComponents()
            components.scheme = Self.pathScheme
            components.host = Self.pathHost
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            return components.url!
        }
    }

    /// Recovers the target from the URL a `Text` link tap delivered.
    init(linkURL: URL) {
        if linkURL.scheme?.lowercased() == Self.pathScheme,
            linkURL.host?.lowercased() == Self.pathHost,
            let path = URLComponents(url: linkURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value
        {
            self = .path(path)
        } else {
            self = .url(linkURL.absoluteString)
        }
    }
}

/// One tappable range in chat text. `range` is UTF-16 based, matching
/// NSAttributedString's coordinate system (the view layer builds the
/// attributed string straight from these).
struct ChatLink: Equatable, Sendable {
    let range: NSRange
    let target: ChatLinkTarget
}

enum ChatLinkDetector {
    /// One target larger than this is ignored rather than truncated,
    /// mirroring ADR-0010's attach-link cap.
    static let maximumTargetLength = 32 * 1024

    private static let markdownRegex = try! NSRegularExpression(
        pattern: #"\[([^\[\]\r\n]+)\]\(\s*((?:[^()\s]|\\.)+)\s*\)"#)
    private static let urlDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Units stripped from the end of any candidate: sentence punctuation
    /// and quotes that prose wraps around targets.
    private static let trailingStrippers: Set<UInt16> = Set(
        ".,;:!\"'".unicodeScalars.map { UInt16($0.value) })

    /// Every detected target in reading order (markdown, then URLs, then
    /// paths — each phase skips ranges the previous phases claimed).
    static func detect(in text: String) -> [ChatLink] {
        guard !text.isEmpty else { return [] }
        let units = Array(text.utf16)
        var links: [ChatLink] = []
        var claimed = [Bool](repeating: false, count: units.count)

        detectMarkdown(in: text, into: &links, claimed: &claimed)
        detectURLs(in: text, units: units, into: &links, claimed: &claimed)
        detectPaths(in: text, units: units, into: &links, claimed: &claimed)
        return links
    }

    // MARK: markdown constructs

    private static func detectMarkdown(
        in text: String, into links: inout [ChatLink], claimed: inout [Bool]
    ) {
        let ns = text as NSString
        for match in markdownRegex.matches(
            in: text, range: NSRange(location: 0, length: ns.length))
        {
            claim(&claimed, match.range)
            let raw = ns.substring(with: match.range(at: 2))
            guard let target = markdownTarget(raw) else { continue }
            links.append(ChatLink(range: match.range, target: target))
        }
    }

    /// The target inside `[label](target)`: an http(s) URL or an absolute
    /// path. Anything else keeps the range claimed but opens nothing.
    /// Unescaping happens before punctuation trimming so an escaped `)`
    /// sheds correctly.
    private static func markdownTarget(_ raw: String) -> ChatLinkTarget? {
        let unescaped = unescape(raw)
        let trimmed = unescaped.trimmingCharacters(
            in: CharacterSet(charactersIn: ".,;:!?"))
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: trimmed) != nil ? .url(trimmed) : nil
        }
        if trimmed.hasPrefix("/") {
            return trimmed.count > 1 ? .path(trimmed) : nil
        }
        return nil
    }

    // MARK: bare URLs

    private static func detectURLs(
        in text: String, units: [UInt16], into links: inout [ChatLink],
        claimed: inout [Bool]
    ) {
        guard let urlDetector else { return }
        let ns = text as NSString
        for match in urlDetector.matches(
            in: text, range: NSRange(location: 0, length: ns.length))
        {
            guard match.resultType == .link, let detected = match.url else { continue }
            guard !overlaps(claimed, match.range) else { continue }
            let range = trimmed(match.range, in: units)
            guard range.length > 0, range.length <= maximumTargetLength else { continue }
            let raw = ns.substring(with: range)
            if let url = URL(string: raw),
                let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            {
                links.append(ChatLink(range: range, target: .url(raw)))
                claim(&claimed, range)
            } else if raw.lowercased().hasPrefix("www."),
                let scheme = detected.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                detected.host?.lowercased() == raw.lowercased()
            {
                // `www.` forms: the visible text carries no scheme, but the
                // detector hands back the canonical full URL.
                links.append(
                    ChatLink(range: range, target: .url(detected.absoluteString)))
                claim(&claimed, range)
            }
        }
    }

    // MARK: absolute POSIX paths

    private static func detectPaths(
        in text: String, units: [UInt16], into links: inout [ChatLink],
        claimed: inout [Bool]
    ) {
        let ns = text as NSString
        var index = 0
        while index < units.count {
            guard units[index] == ascii("/"), !claimed[index],
                isPathStart(units, at: index)
            else {
                index += 1
                continue
            }
            var end = index
            while end < units.count {
                if claimed[end] { break }
                let unit = units[end]
                if unit == ascii("\\"), end + 1 < units.count,
                    units[end + 1] != 0x0A, units[end + 1] != 0x0D
                {
                    end += 2  // backslash-escaped character (`\ ` etc.)
                    continue
                }
                if isPathCharacter(unit) {
                    end += 1
                    continue
                }
                break
            }
            var candidate = NSRange(location: index, length: end - index)
            candidate = trimmed(candidate, in: units)
            if isValidPath(units, candidate) {
                let raw = ns.substring(with: candidate)
                links.append(
                    ChatLink(range: candidate, target: .path(unescape(raw))))
                claim(&claimed, candidate)
                index = candidate.location + candidate.length
            } else {
                index += 1
            }
        }
    }

    /// A path starts at a `/` that follows start-of-text, whitespace, or
    /// prose-opening punctuation — never mid-word (relative paths like
    /// `./a/b` therefore never partially match).
    private static func isPathStart(_ units: [UInt16], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = units[index - 1]
        if isWhitespace(previous) { return true }
        switch previous {
        case ascii("("), ascii("["), ascii("{"), ascii("<"), ascii(","),
            ascii(";"), ascii(":"), ascii("\""), ascii("'"), ascii(">"),
            ascii("="), ascii("&"), ascii("|"):
            return true
        default:
            return false
        }
    }

    /// Raw path characters. Anything else — spaces included — must arrive
    /// backslash-escaped. Non-ASCII conservatively terminates a path.
    private static func isPathCharacter(_ unit: UInt16) -> Bool {
        switch unit {
        case ascii("."), ascii("-"), ascii("_"), ascii("+"), ascii("@"),
            ascii("~"), ascii("/"):
            return true
        default:
            return (unit >= ascii("0") && unit <= ascii("9"))
                || (unit >= ascii("A") && unit <= ascii("Z"))
                || (unit >= ascii("a") && unit <= ascii("z"))
        }
    }

    private static func isValidPath(_ units: [UInt16], _ range: NSRange) -> Bool {
        guard range.length >= 2, range.length <= maximumTargetLength else {
            return false
        }
        // `//` is a comment false positive far more often than a real
        // POSIX path; `/*` and friends are rejected by the name check below.
        guard units[range.location + 1] != ascii("/") else { return false }
        var index = range.location + 1
        while index < range.location + range.length, units[index] != ascii("/") {
            if isPathCharacter(units[index]) { return true }
            index += 1
        }
        return false
    }

    // MARK: shared helpers

    /// Strips sentence punctuation and closing parens the candidate cannot
    /// balance (prose wrapping), preserving at least one unit.
    private static func trimmed(_ range: NSRange, in units: [UInt16]) -> NSRange {
        var length = range.length
        while length > 1 {
            let last = units[range.location + length - 1]
            if trailingStrippers.contains(last) {
                length -= 1
                continue
            }
            if last == ascii(")"),
                hasUnbalancedClose(units, range.location, length)
            {
                length -= 1
                continue
            }
            break
        }
        return NSRange(location: range.location, length: length)
    }

    /// Whether the candidate holds more `)` than `(` — a trailing `)` then
    /// belongs to the surrounding sentence, not the target.
    private static func hasUnbalancedClose(
        _ units: [UInt16], _ start: Int, _ length: Int
    ) -> Bool {
        var open = 0
        var close = 0
        for index in start..<(start + length) {
            if units[index] == ascii("(") { open += 1 }
            if units[index] == ascii(")") { close += 1 }
        }
        return close > open
    }

    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\\", let escaped = iterator.next() {
                result.append(escaped)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == ascii(" ") || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    private static func overlaps(_ claimed: [Bool], _ range: NSRange) -> Bool {
        let end = min(range.location + range.length, claimed.count)
        var index = max(range.location, 0)
        while index < end {
            if claimed[index] { return true }
            index += 1
        }
        return false
    }

    private static func claim(_ claimed: inout [Bool], _ range: NSRange) {
        let end = min(range.location + range.length, claimed.count)
        var index = max(range.location, 0)
        while index < end {
            claimed[index] = true
            index += 1
        }
    }

    private static func ascii(_ character: Character) -> UInt16 {
        UInt16(character.asciiValue ?? 0)
    }
}
