import AppKit
import MarkdownUI
import SwiftUI

/// What a chat row draws.
///
/// The three cases mirror the paths the chat used to take through SwiftUI, and
/// they have to stay distinct: a message without block markdown is rendered
/// inline only today, which leaves things like `- item` as literal text.
enum ChatTextContent: Hashable {
    /// Full markdown, including headings, lists, quotes, code and tables.
    case markdown(String)
    /// Inline markdown only. Block syntax stays literal.
    case inlineMarkdown(String)
    /// No markdown at all.
    case plain(String)
    /// An edit, drawn as removed lines followed by added lines.
    case diff(old: String, new: String)

    var rawText: String {
        switch self {
        case .markdown(let text), .inlineMarkdown(let text), .plain(let text): text
        case .diff(let old, let new): old + new
        }
    }

    /// Whether a row of this may report less width than it was offered.
    ///
    /// Running text may: laying it out again at the width of its longest line
    /// gives the same line breaks. Block layout may not, because a table sizes
    /// its columns against the width available and a block fill spans it, so
    /// asking for less would re-wrap the text taller than the height that came
    /// with the request.
    var shrinksToFit: Bool {
        switch self {
        case .inlineMarkdown, .plain: true
        case .markdown, .diff: false
        }
    }
}

/// Font and colour for the non markdown cases, and for the text a markdown
/// message inherits.
struct ChatTextAppearance: Hashable {
    var font: NSFont
    var foregroundColor: NSColor
    var italic: Bool = false
    var lineSpacing: CGFloat = 0
}

/// A search match to paint behind the text.
struct ChatTextHighlight: Hashable {
    var query: String
    var isCurrentMatch: Bool
}

/// Links laid over the built text.
///
/// References arrive already resolved rather than as a closure: the channel
/// resolves them against the pull requests it knows about, which a cache key
/// could never describe.
struct ChatTextLinks: Hashable, Sendable {
    /// Reference to destination, keyed by the reference exactly as written.
    var issueRefs: [String: URL] = [:]
    /// Whether plain http(s) URLs become links too.
    var urls: Bool = false

    var isEmpty: Bool { self.issueRefs.isEmpty && !self.urls }

    /// The links of a message as the agent wrote it: its `owner/repo#123`,
    /// `repo#123` and `#123` references, resolved against the card's repo
    /// when it has one, and its plain http(s) URLs.
    static func message(_ text: String, githubBaseURL: String?) -> ChatTextLinks {
        ChatTextLinks(
            issueRefs: text.contains("#")
                ? TerminalTranscript.issueRefs(in: text, githubBaseURL: githubBaseURL) : [:],
            urls: text.contains("http")
        )
    }
}

/// Builds the attributed string a chat row displays.
///
/// Results are cached: the chat re-renders on every poll and asks every
/// mounted message to rebuild, and a markdown parse plus table measurement per
/// message per pass shows up directly as scroll jank.
@MainActor
enum ChatAttributedText {

    private struct Key: Hashable {
        let content: ChatTextContent
        let appearance: ChatTextAppearance
        let highlight: ChatTextHighlight?
        let links: ChatTextLinks
        let width: CGFloat
    }

    private static var cache = LRUCache<Key, NSAttributedString>(limit: 400)

    static func make(
        content: ChatTextContent,
        appearance: ChatTextAppearance,
        highlight: ChatTextHighlight? = nil,
        links: ChatTextLinks = ChatTextLinks(),
        width: CGFloat
    ) -> NSAttributedString {
        // Table columns are sized from their content against the available
        // width, so the width belongs in the key.
        let key = Key(
            content: content, appearance: appearance, highlight: highlight, links: links,
            width: width.rounded()
        )
        if let cached = self.cache[key] { return cached }

        let result = self.build(
            content: content, appearance: appearance, highlight: highlight, links: links,
            width: width)
        self.cache[key] = result
        return result
    }

    private static func build(
        content: ChatTextContent,
        appearance: ChatTextAppearance,
        highlight: ChatTextHighlight?,
        links: ChatTextLinks,
        width: CGFloat
    ) -> NSAttributedString {
        let result: NSMutableAttributedString
        switch content {
        case .markdown(let markdown):
            let renderer = MarkdownAttributedStringRenderer(
                theme: chatMarkdownTheme,
                metrics: chatMarkdownMetrics,
                containerWidth: max(width, 1)
            )
            result = NSMutableAttributedString(
                attributedString: renderer.render(markdown: markdown))
        case .inlineMarkdown(let markdown):
            result = self.inlineMarkdown(markdown, appearance: appearance)
        case .plain(let text):
            result = NSMutableAttributedString(
                string: text, attributes: self.plainAttributes(appearance))
        case .diff(let old, let new):
            result = self.diff(old: old, new: new, appearance: appearance)
        }

        if !links.isEmpty {
            self.applyLinks(links, to: result)
        }
        if let highlight, !highlight.query.isEmpty {
            self.applyHighlight(highlight, to: result)
        }
        return result
    }

    // MARK: - Links

    /// The colour a link is drawn in.
    ///
    /// Read from the theme rather than restated, because the block markdown
    /// path takes it from there. A message without block syntax is rendered by
    /// the inline path instead, and a link that keeps the colour of the text
    /// around it does not read as one at all.
    static let linkColor: NSColor = {
        var attributes = AttributeContainer()
        chatMarkdownTheme.link._collectAttributes(in: &attributes)
        guard let color = attributes.foregroundColor else { return .linkColor }
        return NSColor(color)
    }()

    private static let issueRefRegex = try? NSRegularExpression(
        pattern: TerminalURLDetector.markdownIssueRefPattern, options: [])
    private static let urlRegex = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"'\])*]*[^\s<>"'\]).,:;!?]"#, options: [])

    private static func applyLinks(
        _ links: ChatTextLinks, to string: NSMutableAttributedString
    ) {
        let text = string.string
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)

        if !links.issueRefs.isEmpty, let regex = self.issueRefRegex {
            for match in regex.matches(in: text, range: full) {
                guard let url = links.issueRefs[nsText.substring(with: match.range)],
                    !self.isLinked(match.range, in: string)
                else { continue }
                self.setLink(url, color: .systemBlue, range: match.range, on: string)
            }
        }

        if links.urls, let regex = self.urlRegex {
            let color = NSColor(srgbRed: 0.45, green: 0.65, blue: 1.0, alpha: 1)
            for match in regex.matches(in: text, range: full) {
                guard let url = URL(string: nsText.substring(with: match.range)),
                    !self.isLinked(match.range, in: string)
                else { continue }
                self.setLink(url, color: color, range: match.range, on: string)
            }
        }
    }

    /// Whether markdown already made part of this range a link, whose own
    /// destination wins over one guessed from the text.
    private static func isLinked(_ range: NSRange, in string: NSAttributedString) -> Bool {
        guard NSMaxRange(range) <= string.length else { return true }
        var linked = false
        string.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
            guard value != nil else { return }
            linked = true
            stop.pointee = true
        }
        return linked
    }

    private static func setLink(
        _ url: URL, color: NSColor, range: NSRange, on string: NSMutableAttributedString
    ) {
        guard NSMaxRange(range) <= string.length else { return }
        string.addAttributes(
            [
                .link: url,
                .foregroundColor: color,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ],
            range: range
        )
    }

    // MARK: - Non markdown paths

    private static func plainAttributes(
        _ appearance: ChatTextAppearance
    ) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        // No trailing compensation here, unlike the block renderer. These paths
        // stand in for a single SwiftUI `Text`, where a newline is a line break
        // that line spacing applies across, not a block boundary.
        style.lineSpacing = appearance.lineSpacing
        return [
            .font: self.resolvedFont(appearance),
            .foregroundColor: appearance.foregroundColor,
            .paragraphStyle: style,
        ]
    }

    private static func resolvedFont(_ appearance: ChatTextAppearance) -> NSFont {
        guard appearance.italic else { return appearance.font }
        return NSFontManager.shared.convert(appearance.font, toHaveTrait: .italicFontMask)
    }

    /// Inline markdown through Foundation's parser, matching what the chat's
    /// lighter text path produces today.
    private static func inlineMarkdown(
        _ text: String, appearance: ChatTextAppearance
    ) -> NSMutableAttributedString {
        let base = self.plainAttributes(appearance)
        guard
            let parsed = try? AttributedString(
                markdown: text,
                options: .init(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        else {
            return NSMutableAttributedString(string: text, attributes: base)
        }

        let font = self.resolvedFont(appearance)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            guard !piece.isEmpty else { continue }
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []

            if intent.contains(.code) {
                // No chip behind it: this path feeds a plain SwiftUI `Text`
                // today, which styles a code run as monospaced and nothing more.
                attributes[.font] = NSFont.monospacedSystemFont(
                    ofSize: font.pointSize, weight: .regular)
            } else {
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty {
                    attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: traits)
                }
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = run.link {
                attributes[.link] = url
                attributes[.foregroundColor] = self.linkColor
            }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }

    // MARK: - Diffs

    /// An edit rendered as one run of text rather than a stack of coloured rows,
    /// so a drag can pass through it like any other block.
    ///
    /// The full width bands behind the lines are block decorations, because a
    /// background colour attribute only paints behind the glyphs and would stop
    /// at the end of each line.
    private enum DiffStyle {
        static let removedForeground = NSColor(srgbRed: 1, green: 0.4, blue: 0.4, alpha: 1)
        static let addedForeground = NSColor(srgbRed: 0.4, green: 0.9, blue: 0.4, alpha: 1)
        static let removedFill = NSColor.systemRed.withAlphaComponent(0.12)
        static let addedFill = NSColor.systemGreen.withAlphaComponent(0.1)
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 1
        /// One line's box, matching the row height these lines had as separate
        /// `Text` views: a 13pt text box with a point of padding either side.
        static let lineHeight: CGFloat = 15
    }

    private static func diff(
        old: String, new: String, appearance: ChatTextAppearance
    ) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        self.appendDiffLines(
            old.components(separatedBy: "\n"), marker: "- ",
            foreground: DiffStyle.removedForeground, fill: DiffStyle.removedFill,
            appearance: appearance, to: out
        )
        self.appendDiffLines(
            new.components(separatedBy: "\n"), marker: "+ ",
            foreground: DiffStyle.addedForeground, fill: DiffStyle.addedFill,
            appearance: appearance, to: out
        )
        return out
    }

    private static func appendDiffLines(
        _ lines: [String],
        marker: String,
        foreground: NSColor,
        fill: NSColor,
        appearance: ChatTextAppearance,
        to out: NSMutableAttributedString
    ) {
        guard !lines.isEmpty else { return }

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.firstLineHeadIndent = DiffStyle.horizontalPadding
        style.headIndent = DiffStyle.horizontalPadding
        style.tailIndent = -DiffStyle.horizontalPadding
        // The padding lives in the line box rather than in paragraph spacing,
        // which TextKit drops at the first and last paragraph of a run.
        style.minimumLineHeight = DiffStyle.lineHeight
        style.maximumLineHeight = DiffStyle.lineHeight

        if out.length > 0 {
            // The separator carries the attributes of the line it ends, or that
            // line would take its height from a terminator styled with the
            // system defaults.
            var previous = out.attributes(at: out.length - 1, effectiveRange: nil)
            previous[.markdownBlockDecoration] = nil
            out.append(NSAttributedString(string: "\n", attributes: previous))
        }
        // TextKit puts the whole difference between the natural line and the
        // forced box above the glyphs; the row it replaces put a point of it
        // below. Lift the text by the rest.
        let natural = NSLayoutManager().defaultLineHeight(for: appearance.font)
        let lift = max(DiffStyle.lineHeight - natural - DiffStyle.verticalPadding, 0)

        let body = lines.map { marker + $0 }.joined(separator: "\n")
        out.append(
            NSAttributedString(
                string: body,
                attributes: [
                    .font: appearance.font,
                    .foregroundColor: foreground,
                    .paragraphStyle: style,
                    .baselineOffset: lift,
                ]
            )
        )

        let decoration = MarkdownBlockDecoration(kind: .fill, color: fill)
        // The separator before this group belongs to the group above it: a
        // paragraph terminator lays out on the line it ends, and painting past
        // it would stretch this band up over that line.
        let bodyStart = out.length - body.utf16.count
        out.addAttribute(
            .markdownBlockDecoration, value: decoration,
            range: NSRange(location: bodyStart, length: body.utf16.count)
        )
    }

    // MARK: - Search highlighting

    private static func applyHighlight(
        _ highlight: ChatTextHighlight, to string: NSMutableAttributedString
    ) {
        let haystack = string.string
        let needle = highlight.query
        guard !needle.isEmpty else { return }

        let color: NSColor =
            highlight.isCurrentMatch
            ? NSColor.systemOrange.withAlphaComponent(0.4)
            : NSColor.systemYellow.withAlphaComponent(0.3)

        // Matched case insensitively in place rather than over a lowercased
        // copy, and converted through `NSRange(_:in:)`. Counting characters
        // gives an offset an emoji or an accent puts one or more short of the
        // UTF-16 offset the attribute is addressed by, so a match after one
        // paints the wrong words.
        var searchStart = haystack.startIndex
        while let found = haystack.range(
            of: needle, options: [.caseInsensitive], range: searchStart..<haystack.endIndex)
        {
            string.addAttribute(
                .backgroundColor, value: color, range: NSRange(found, in: haystack))
            searchStart = found.upperBound
        }
    }
}

/// A dictionary that evicts what was used least recently.
///
/// The keys of these caches are whole messages, so every touch has to be
/// O(1): an ordering array walked with `firstIndex` compared megabytes of
/// text on each cache hit, in the middle of layout. Recency is a counter
/// per entry instead, and eviction drops the older half in one sweep, so a
/// long conversation never stalls on the pass right after the cache fills.
struct LRUCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var use: Int
    }

    private var storage: [Key: Entry] = [:]
    private var tick = 0
    private let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    subscript(key: Key) -> Value? {
        mutating get {
            guard var entry = self.storage[key] else { return nil }
            self.tick += 1
            entry.use = self.tick
            self.storage[key] = entry
            return entry.value
        }
        set {
            guard let newValue else {
                self.storage[key] = nil
                return
            }
            self.tick += 1
            self.storage[key] = Entry(value: newValue, use: self.tick)
            if self.storage.count > self.limit {
                let uses = self.storage.values.map(\.use).sorted()
                let cutoff = uses[uses.count / 2]
                self.storage = self.storage.filter { $0.value.use > cutoff }
            }
        }
    }

    var count: Int { self.storage.count }
}
