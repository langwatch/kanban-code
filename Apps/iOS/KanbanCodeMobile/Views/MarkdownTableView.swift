import SwiftUI
import UIKit
import KanbanCodeRemoteKit

/// A markdown table as a grid: the header in semibold, columns aligned as
/// the separator row says, inline markdown and text selection in every
/// cell. Columns are as wide as what they hold; when that is wider than
/// the chat the long columns wrap, and a table with too many columns for
/// that scrolls sideways on its own.
struct MarkdownTableView: View {
    let table: MarkdownTable

    private struct Cell: Identifiable {
        let id: Int
        let text: String
        let row: Int
        let column: Int
    }

    private var cells: [Cell] {
        let all = [table.header] + table.rows
        var out: [Cell] = []
        for (row, texts) in all.enumerated() {
            for (column, text) in texts.enumerated() {
                out.append(Cell(id: out.count, text: text, row: row, column: column))
            }
        }
        return out
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid(scrolls: false)
            ScrollView(.horizontal, showsIndicators: true) {
                grid(scrolls: true)
            }
            .accessibilityIdentifier("markdownTableScroll")
        }
    }

    private func grid(scrolls: Bool) -> some View {
        MarkdownTableLayout(columns: table.columnCount, scrolls: scrolls) {
            ForEach(cells) { cell in
                cellView(cell)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separator), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdownTable")
    }

    private func cellView(_ cell: Cell) -> some View {
        let alignment = cell.column < table.alignments.count ? table.alignments[cell.column] : .leading
        let body = UIFont.preferredFont(forTextStyle: .subheadline)
        let font = cell.row == 0 ? UIFont.systemFont(ofSize: body.pointSize, weight: .semibold) : body
        return SelectableText(text: SelectableTextStyle.markdown(cell.text, font: font),
                              alignment: Self.textAlignment(alignment))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.frameAlignment(alignment))
            .background(cell.row == 0 ? Color(.tertiarySystemFill) : Color.clear)
            .overlay(alignment: .top) {
                if cell.row > 0 {
                    Rectangle().fill(Color(.separator)).frame(height: 0.5)
                }
            }
    }

    private static func textAlignment(_ alignment: MarkdownTable.Alignment) -> NSTextAlignment {
        switch alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }

    private static func frameAlignment(_ alignment: MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }
}

/// Lays the cells of a table out in rows of `columns`, every column one
/// width and every row as tall as its tallest cell.
private struct MarkdownTableLayout: Layout {
    let columns: Int
    /// true for the table inside a sideways scroll view: columns take a
    /// comfortable width whatever room there is.
    let scrolls: Bool

    /// A wrapped column is given at least this much.
    static let minimumColumn: Double = 96

    struct Cache {
        /// The width of each column with every cell on one line.
        var ideal: [Double]
    }

    func makeCache(subviews: Subviews) -> Cache {
        var ideal = Array(repeating: 0.0, count: columns)
        for (index, subview) in subviews.enumerated() where columns > 0 {
            let width = Double(subview.sizeThatFits(.unspecified).width.rounded(.up))
            ideal[index % columns] = max(ideal[index % columns], width)
        }
        return Cache(ideal: ideal)
    }

    private func widths(for proposal: ProposedViewSize, cache: Cache) -> [Double] {
        if scrolls { return MarkdownTable.columnWidths(ideal: cache.ideal, available: 0, minimum: Self.minimumColumn).widths }
        guard let available = proposal.width, available.isFinite else {
            // The least the table can be drawn in: what decides whether it
            // fits the chat or scrolls.
            return cache.ideal.map { min($0, Self.minimumColumn) }
        }
        return MarkdownTable.columnWidths(ideal: cache.ideal, available: Double(available), minimum: Self.minimumColumn).widths
    }

    private func rowHeights(_ widths: [Double], subviews: Subviews) -> [CGFloat] {
        guard columns > 0 else { return [] }
        var heights: [CGFloat] = []
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil)).height
            if index % columns == 0 { heights.append(height) } else { heights[heights.count - 1] = max(heights[heights.count - 1], height) }
        }
        return heights
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let widths = widths(for: proposal, cache: cache)
        return CGSize(width: widths.reduce(0, +), height: Double(rowHeights(widths, subviews: subviews).reduce(0, +)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard columns > 0 else { return }
        let widths = widths(for: ProposedViewSize(width: bounds.width, height: nil), cache: cache)
        let heights = rowHeights(widths, subviews: subviews)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let column = index % columns
            let row = index / columns
            if column == 0, row > 0 { y += heights[row - 1] }
            let x = bounds.minX + widths[..<column].reduce(0, +)
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: widths[column], height: heights[row]))
        }
    }
}
