import Foundation
import Testing
@testable import KanbanCodeRemoteKit

@Suite("Markdown tables")
struct MarkdownTableTests {
    private func parse(_ text: String, at start: Int = 0) -> (table: MarkdownTable, lineCount: Int)? {
        MarkdownTable.parse(text.components(separatedBy: "\n"), at: start)
    }

    @Test("a table is its header, the alignments of its separator row and its rows")
    func basic() throws {
        let text = """
            | What | Frees | Notes |
            |:---|---:|:---:|
            | `go-build` cache | 8 GB | **safe**, rebuilt on demand |
            | Old worktrees | 48 GB | see [the list](https://example.com) |
            after
            """
        let parsed = try #require(parse(text))
        #expect(parsed.lineCount == 4)
        #expect(parsed.table.header == ["What", "Frees", "Notes"])
        #expect(parsed.table.alignments == [.leading, .trailing, .center])
        #expect(parsed.table.rows == [
            ["`go-build` cache", "8 GB", "**safe**, rebuilt on demand"],
            ["Old worktrees", "48 GB", "see [the list](https://example.com)"],
        ])
    }

    @Test("the outer pipes are optional and a blank line ends the table")
    func noOuterPipes() throws {
        let parsed = try #require(parse("a | b\n--- | ---\n1 | 2\n\n3 | 4"))
        #expect(parsed.lineCount == 3)
        #expect(parsed.table.header == ["a", "b"])
        #expect(parsed.table.rows == [["1", "2"]])
    }

    @Test("a pipe in a code span or after a backslash stays in its cell")
    func pipesInsideCells() throws {
        #expect(MarkdownTable.cells(of: "| `a | b` | c \\| d |") == ["`a | b`", "c | d"])
        #expect(MarkdownTable.cells(of: "| ``x ` | y`` | z |") == ["``x ` | y``", "z"])
        // A backtick with no closing one is text, so the pipe after it splits.
        #expect(MarkdownTable.cells(of: "| it`s | fine |") == ["it`s", "fine"])
        #expect(MarkdownTable.cells(of: "| ends with \\|") == ["ends with |"])
    }

    @Test("a line with pipes and no separator row under it is text")
    func notATable() {
        #expect(parse("run a | b to pipe\nand then c | d") == nil)
        #expect(parse("| a | b |") == nil)
        #expect(parse("| a | b |\n| 1 | 2 |") == nil)
        // The separator row must have as many cells as the header.
        #expect(parse("| a | b |\n|---|\n| 1 | 2 |") == nil)
        #expect(parse("plain\n---") == nil)
    }

    @Test("rows are filled or cut to the header's columns")
    func raggedRows() throws {
        let parsed = try #require(parse("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |"))
        #expect(parsed.table.rows == [["1", ""], ["1", "2"]])
    }

    @Test("a table at the end of a message still being written stays a table at every length")
    func streaming() throws {
        let whole = "| What | Frees |\n|---|---:|\n| cache | 8 GB |\n| logs | 2 GB |"
        let headerEnd = whole.firstIndex(of: "\n")!
        var sawTable = false
        var index = whole.index(after: headerEnd)
        while index <= whole.endIndex {
            let partial = String(whole[..<index])
            let lines = partial.components(separatedBy: "\n")
            if let parsed = MarkdownTable.parse(lines, at: 0) {
                sawTable = true
                #expect(parsed.table.header == ["What", "Frees"])
                // Everything written is in the table; a line just begun is empty.
                #expect(parsed.lineCount == lines.count - (lines.last == "" ? 1 : 0))
                #expect(parsed.table.rows.allSatisfy { $0.count == 2 })
            } else {
                // Only before the first dash of the separator row.
                #expect(!sawTable, "went back to text at \(partial.debugDescription)")
            }
            if index == whole.endIndex { break }
            index = whole.index(after: index)
        }
        let done = try #require(parse(whole))
        #expect(done.table.alignments == [.leading, .trailing])
        #expect(done.table.rows == [["cache", "8 GB"], ["logs", "2 GB"]])
        // An unfinished separator row counts only as the last line.
        #expect(parse("| a | b |\n|--\nmore | text") == nil)
    }

    @Test("a table indented under a list item is read the same")
    func insideAList() throws {
        let text = "- Sizes:\n\n  | Folder | Size |\n  |---|---|\n  | a | 1 |\n- next"
        let parsed = try #require(parse(text, at: 2))
        #expect(parsed.lineCount == 3)
        #expect(parsed.table.rows == [["a", "1"]])
    }

    @Test("columns keep their width when they fit, share the rest when they do not, and scroll when too many")
    func widths() {
        let fits = MarkdownTable.columnWidths(ideal: [80, 60, 100], available: 360)
        #expect(fits.widths == [80, 60, 100] && fits.fits)

        // The narrow middle column keeps its width; the two long ones share the rest.
        let shared = MarkdownTable.columnWidths(ideal: [400, 60, 700], available: 360)
        #expect(shared.fits)
        #expect(shared.widths == [150, 60, 150])

        let scrolls = MarkdownTable.columnWidths(ideal: [300, 300, 300, 300, 90], available: 360)
        #expect(!scrolls.fits)
        #expect(scrolls.widths == [220, 220, 220, 220, 90])

        // Four wrapping columns fit at their floor, never under it.
        let floor = MarkdownTable.columnWidths(ideal: [300, 300, 300, 50], available: 360)
        #expect(floor.fits)
        #expect(floor.widths.reduce(0, +) <= 360.0001)
        #expect(floor.widths.allSatisfy { $0 >= 50 })
    }
}
