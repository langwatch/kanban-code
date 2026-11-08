import UIKit
import KanbanCodeRemoteKit

/// A markdown message cut into the pieces the chat draws. Headings,
/// paragraphs and lists between two code blocks or tables are one
/// attributed string, so one text view holds them and a selection runs
/// from the first heading to the last bullet. Code blocks and tables keep
/// views of their own (a sideways scroll, a grid).
enum MarkdownDocument {
    enum Segment {
        case text(NSAttributedString)
        case code(String)
        case table(MarkdownTable)
    }

    /// The blocks a message is made of, before styling.
    enum Block: Hashable {
        case code(String)
        case heading(String)
        case paragraph(String)
        case table(MarkdownTable)
    }

    /// Space between two blocks, as the chat spaces its views.
    static let blockSpacing: CGFloat = 8

    private final class Entry {
        let segments: [Segment]
        init(_ segments: [Segment]) { self.segments = segments }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 500
        return cache
    }()

    /// The segments of `text`, built once per text and text size: a row
    /// that scrolls back in or redraws reuses them.
    static func segments(for text: String,
                         sizeCategory: UIContentSizeCategory = UITraitCollection.current.preferredContentSizeCategory)
        -> [Segment] {
        let key = "\(sizeCategory.rawValue)\u{0}\(text)" as NSString
        if let hit = cache.object(forKey: key) { return hit.segments }
        let traits = UITraitCollection(preferredContentSizeCategory: sizeCategory)
        let built = segments(from: blocks(in: text), traits: traits)
        cache.setObject(Entry(built), forKey: key)
        return built
    }

    static func segments(from blocks: [Block], traits: UITraitCollection) -> [Segment] {
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let headline = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        var out: [Segment] = []
        var run: NSMutableAttributedString?
        func flush() {
            if let run, run.length > 0 { out.append(.text(run)) }
            run = nil
        }
        for block in blocks {
            switch block {
            case .code(let code):
                flush()
                out.append(.code(code))
            case .table(let table):
                flush()
                out.append(.table(table))
            case .heading(let line):
                append(SelectableTextStyle.markdown(line, font: headline), to: &run)
            case .paragraph(let para):
                append(SelectableTextStyle.markdown(para, font: body), to: &run)
            }
        }
        flush()
        return out
    }

    /// Adds a block to the text run: a line break before it, the block
    /// spacing above its first line, and wrapped bullet lines indented
    /// under their text rather than under the bullet.
    private static func append(_ block: NSAttributedString, to run: inout NSMutableAttributedString?) {
        let styled = NSMutableAttributedString(attributedString: block)
        let string = styled.string as NSString
        let spacesFirstLine = run != nil
        var first = true
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length),
                                   options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
            let style = NSMutableParagraphStyle()
            if first, spacesFirstLine { style.paragraphSpacingBefore = blockSpacing }
            first = false
            if let prefix = bulletPrefixLength(in: string.substring(with: range)), prefix > 0 {
                let font = styled.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
                    ?? .preferredFont(forTextStyle: .body)
                let bullet = string.substring(with: NSRange(location: range.location, length: prefix))
                style.headIndent = ceil((bullet as NSString).size(withAttributes: [.font: font]).width)
            }
            styled.addAttribute(.paragraphStyle, value: style, range: enclosing)
        }
        if let run {
            let breakAttributes = run.length > 0 ? run.attributes(at: run.length - 1, effectiveRange: nil) : [:]
            run.append(NSAttributedString(string: "\n", attributes: breakAttributes.filter { $0.key != .link }))
            run.append(styled)
        } else {
            run = styled
        }
    }

    /// Characters up to and with the "• " a list line starts with, its
    /// indent included, or nil for a line that is not a bullet.
    private static func bulletPrefixLength(in line: String) -> Int? {
        let indent = line.prefix { $0 == " " }
        guard line.dropFirst(indent.count).hasPrefix("• ") else { return nil }
        return (String(indent) + "• ").utf16.count
    }

    /// The blocks of a markdown message: fenced code, tables, headings
    /// and paragraphs, with `- ` and `* ` list items as bullet lines.
    static func blocks(in text: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { out.append(.paragraph(joined)) }
            paragraph = []
        }
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    out.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if let (table, lineCount) = MarkdownTable.parse(lines, at: index - 1) {
                flush()
                out.append(.table(table))
                index += lineCount - 1
                continue
            }
            if trimmed.hasPrefix("#") {
                flush()
                out.append(.heading(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                // A list starts its own block after a paragraph.
                if let last = paragraph.last, !last.trimmingCharacters(in: .whitespaces).hasPrefix("• ") { flush() }
                let indent = String(raw.prefix { $0 == " " })
                paragraph.append(indent + "• " + trimmed.dropFirst(2))
            } else {
                paragraph.append(raw)
            }
        }
        if let lines = code { out.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return out
    }
}
