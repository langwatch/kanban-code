import Foundation

/// GitHub references written as `owner/repo#123` in chat text, so the phone
/// can turn them into tappable links the way the Mac does.
public enum IssueRefLinks {
    public struct Match: Equatable, Sendable {
        /// Range in the UTF-16 view of the text, ready for NSAttributedString.
        public var range: NSRange
        public var url: URL
    }

    // Not preceded by a letter, digit, `/`, `&` or `.`, so URL paths
    // (`github.com/owner/repo#1`) and HTML entities (`&#123`) are left alone.
    private static let regex = try? NSRegularExpression(
        pattern: #"(?<![&/.a-zA-Z0-9_-])([a-zA-Z0-9][a-zA-Z0-9-]*)/([a-zA-Z0-9_.-]+)#(\d+)\b"#
    )

    public static func matches(in text: String) -> [Match] {
        guard let regex else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let owner = ns.substring(with: m.range(at: 1))
            let repo = ns.substring(with: m.range(at: 2))
            let number = ns.substring(with: m.range(at: 3))
            guard let url = URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)") else { return nil }
            return Match(range: m.range, url: url)
        }
    }
}
