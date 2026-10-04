import Foundation

/// A GitHub-flavored markdown table, read from the lines of a message.
/// The phone's chat draws it as a grid; cells keep their inline markdown.
public struct MarkdownTable: Equatable, Hashable, Sendable {
    public enum Alignment: Equatable, Hashable, Sendable {
        case leading
        case center
        case trailing
    }

    public var header: [String]
    /// One per column, from the separator row (`:---`, `:---:`, `---:`).
    public var alignments: [Alignment]
    /// Every row has as many cells as the header: a short row is filled
    /// with empty cells, a long one is cut.
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }

    public var columnCount: Int { header.count }

    /// The table that starts at `lines[start]` and how many lines it takes,
    /// or nil when no table starts there.
    ///
    /// A table is a header row with a pipe, then a separator row with as
    /// many cells, then rows until a blank line or a line with no pipe. In
    /// a message still being written, a separator row that is the last
    /// line may be unfinished: it counts once every cell written so far is
    /// a separator cell, so the header does not show as text first.
    public static func parse(_ lines: [String], at start: Int) -> (table: MarkdownTable, lineCount: Int)? {
        guard start + 1 < lines.count, lines[start].contains("|"),
              let header = cells(of: lines[start]), !header.isEmpty else { return nil }
        let isLast = start + 2 == lines.count
        guard var alignments = separator(lines[start + 1], columns: header.count, unfinished: isLast) else { return nil }
        while alignments.count < header.count { alignments.append(.leading) }
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let line = lines[index]
            guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  var row = cells(of: line) else { break }
            if row.count > header.count { row = Array(row.prefix(header.count)) }
            while row.count < header.count { row.append("") }
            rows.append(row)
            index += 1
        }
        return (MarkdownTable(header: header, alignments: alignments, rows: rows), index - start)
    }

    /// The cells of a row. A pipe inside a code span or after a backslash
    /// is part of its cell; the pipes that open and close the row are not
    /// cells.
    public static func cells(of line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let chars = Array(trimmed)
        var cells: [String] = []
        var current = ""
        var index = 0
        /// Length of the backtick run that opened the code span we are in.
        var fence = 0
        var sawPipe = false
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count, chars[index + 1] == "|" {
                // Inside a code span the backslash would show, so it goes.
                current.append("|")
                index += 2
                continue
            }
            if char == "`" {
                var run = 0
                while index + run < chars.count, chars[index + run] == "`" { run += 1 }
                if fence == 0 {
                    // A run with no closing run of the same length is plain text.
                    if hasClosingRun(chars, from: index + run, length: run) { fence = run }
                } else if run == fence {
                    fence = 0
                }
                current.append(String(repeating: "`", count: run))
                index += run
                continue
            }
            if char == "|", fence == 0 {
                sawPipe = true
                cells.append(current)
                current = ""
                index += 1
                continue
            }
            current.append(char)
            index += 1
        }
        cells.append(current)
        guard sawPipe else { return nil }
        if trimmed.hasPrefix("|") { cells.removeFirst() }
        if endsWithUnescapedPipe(chars), !cells.isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func hasClosingRun(_ chars: [Character], from start: Int, length: Int) -> Bool {
        var index = start
        while index < chars.count {
            guard chars[index] == "`" else { index += 1; continue }
            var run = 0
            while index + run < chars.count, chars[index + run] == "`" { run += 1 }
            if run == length { return true }
            index += run
        }
        return false
    }

    private static func endsWithUnescapedPipe(_ chars: [Character]) -> Bool {
        guard chars.last == "|" else { return false }
        return chars.count < 2 || chars[chars.count - 2] != "\\"
    }

    /// The alignments of a separator row, or nil when `line` is not one
    /// for a header of `columns` cells.
    static func separator(_ line: String, columns: Int, unfinished: Bool) -> [Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.allSatisfy({ "|-: ".contains($0) }) else { return nil }
        var parts = trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmed.hasPrefix("|") { parts.removeFirst() }
        if trimmed.hasSuffix("|"), !parts.isEmpty { parts.removeLast() }
        // The cell being written at the end of a message may still be empty or a lone colon.
        if unfinished, let last = parts.last, !last.contains("-") { parts.removeLast() }
        guard !parts.isEmpty, parts.count == columns || (unfinished && parts.count < columns) else { return nil }
        var out: [Alignment] = []
        for part in parts {
            let dashes = part.drop { $0 == ":" }.prefix { $0 == "-" }
            let tail = part.drop { $0 == ":" }.dropFirst(dashes.count)
            guard !dashes.isEmpty, tail.isEmpty || tail == ":" else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): out.append(.center)
            case (false, true): out.append(.trailing)
            default: out.append(.leading)
            }
        }
        return out
    }

    /// The widths of the columns for a table drawn in `available` points.
    ///
    /// - Parameters:
    ///   - ideal: the width each column takes with every cell on one line.
    ///   - minimum: the least a column that wraps may be given.
    /// - Returns: the widths, and whether they fit `available`. Columns
    ///   narrower than their share keep their width and the others share
    ///   the rest. When even the minimums do not fit, the widths are the
    ///   comfortable ones for a table that scrolls sideways.
    public static func columnWidths(ideal: [Double], available: Double, minimum: Double = 96,
                                    comfortable: Double = 220) -> (widths: [Double], fits: Bool) {
        guard !ideal.isEmpty else { return ([], true) }
        if ideal.reduce(0, +) <= available { return (ideal, true) }
        let floors = ideal.map { min($0, minimum) }
        guard floors.reduce(0, +) <= available else {
            return (ideal.map { min($0, comfortable) }, false)
        }
        // Columns that fit their share keep their width; the rest share what is left.
        var widths = ideal
        var open = Set(ideal.indices)
        var left = available
        while !open.isEmpty {
            let share = left / Double(open.count)
            let small = open.filter { ideal[$0] <= share }
            if small.isEmpty {
                // A wrapped column is never narrower than its floor.
                var rest = left
                var wrapping = open.sorted { floors[$0] > floors[$1] }
                while let column = wrapping.first {
                    let each = rest / Double(wrapping.count)
                    widths[column] = max(floors[column], each)
                    rest -= widths[column]
                    wrapping.removeFirst()
                }
                break
            }
            for column in small {
                left -= ideal[column]
                open.remove(column)
            }
        }
        return (widths, true)
    }
}
