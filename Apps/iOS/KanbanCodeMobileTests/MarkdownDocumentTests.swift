import XCTest
import UIKit
import KanbanCodeRemoteKit
@testable import KanbanCodeMobile

final class MarkdownDocumentTests: XCTestCase {
    private let reply = """
    # Summary

    I changed **two** files and ran `swift test`.

    - first bullet with a [link](https://example.com/a)
    - second bullet
      - nested bullet

    See langwatch/langwatch#123 for the rest.
    """

    @MainActor private func texts(_ segments: [MarkdownDocument.Segment]) -> [NSAttributedString] {
        segments.compactMap { if case .text(let text) = $0 { text } else { nil } }
    }

    @MainActor func testHeadingsParagraphsAndListsAreOneString() {
        let segments = MarkdownDocument.segments(for: reply, sizeCategory: .large)
        XCTAssertEqual(segments.count, 1)
        let text = try! XCTUnwrap(texts(segments).first)
        XCTAssertEqual(text.string, """
        Summary
        I changed two files and ran swift test.
        • first bullet with a link
        • second bullet
          • nested bullet
        See langwatch/langwatch#123 for the rest.
        """)
    }

    @MainActor func testStylesSurviveInTheOneString() throws {
        let text = try XCTUnwrap(texts(MarkdownDocument.segments(for: reply, sizeCategory: .large)).first)
        let string = text.string as NSString

        let heading = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertEqual(heading?.pointSize, UIFont.preferredFont(forTextStyle: .headline,
                                                                compatibleWith: .init(preferredContentSizeCategory: .large)).pointSize)

        let bold = text.attribute(.font, at: string.range(of: "two").location, effectiveRange: nil) as? UIFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)

        let code = string.range(of: "swift test")
        XCTAssertNotNil(text.attribute(.backgroundColor, at: code.location, effectiveRange: nil))
        let codeFont = text.attribute(.font, at: code.location, effectiveRange: nil) as? UIFont
        XCTAssertTrue(codeFont?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ?? false)

        let link = text.attribute(.link, at: string.range(of: "link").location, effectiveRange: nil) as? URL
        XCTAssertEqual(link, URL(string: "https://example.com/a"))
        XCTAssertNotNil(text.attribute(.link, at: string.range(of: "langwatch/langwatch#123").location, effectiveRange: nil))
    }

    @MainActor func testBlocksAreSpacedAndBulletsHang() throws {
        let text = try XCTUnwrap(texts(MarkdownDocument.segments(for: reply, sizeCategory: .large)).first)
        let string = text.string as NSString
        func style(_ needle: String) -> NSParagraphStyle? {
            text.attribute(.paragraphStyle, at: string.range(of: needle).location, effectiveRange: nil) as? NSParagraphStyle
        }
        XCTAssertEqual(style("Summary")?.paragraphSpacingBefore, 0)
        XCTAssertEqual(style("I changed")?.paragraphSpacingBefore, MarkdownDocument.blockSpacing)
        XCTAssertEqual(style("• first")?.paragraphSpacingBefore, MarkdownDocument.blockSpacing)
        // Lines of one list are not spaced apart.
        XCTAssertEqual(style("• second")?.paragraphSpacingBefore, 0)
        XCTAssertGreaterThan(style("• second")?.headIndent ?? 0, 0)
        XCTAssertGreaterThan(style("  • nested")?.headIndent ?? 0, style("• second")?.headIndent ?? 0)
        XCTAssertEqual(style("See langwatch")?.headIndent, 0)
    }

    @MainActor func testCodeAndTablesSplitTheTextInOrder() {
        let markdown = """
        Before the code.

        ```swift
        let x = 1
        ```

        Between.

        | a | b |
        |---|---|
        | 1 | 2 |

        After.
        """
        let segments = MarkdownDocument.segments(for: markdown, sizeCategory: .large)
        XCTAssertEqual(segments.count, 5)
        guard case .text(let before) = segments[0], case .code(let code) = segments[1],
              case .text(let between) = segments[2], case .table(let table) = segments[3],
              case .text(let after) = segments[4] else {
            return XCTFail("unexpected segments \(segments)")
        }
        XCTAssertEqual(before.string, "Before the code.")
        XCTAssertEqual(code, "let x = 1")
        XCTAssertEqual(between.string, "Between.")
        XCTAssertEqual(table.header, ["a", "b"])
        XCTAssertEqual(after.string, "After.")
    }

    @MainActor func testSegmentsAreBuiltOncePerTextAndSize() throws {
        let markdown = "cached \(UUID().uuidString)"
        let first = try XCTUnwrap(texts(MarkdownDocument.segments(for: markdown, sizeCategory: .large)).first)
        let again = try XCTUnwrap(texts(MarkdownDocument.segments(for: markdown, sizeCategory: .large)).first)
        XCTAssertTrue(first === again)
        let bigger = try XCTUnwrap(texts(MarkdownDocument.segments(for: markdown, sizeCategory: .accessibilityLarge)).first)
        XCTAssertFalse(first === bigger)
        let font = bigger.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertGreaterThan(font?.pointSize ?? 0, (first.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 0)
    }
}
