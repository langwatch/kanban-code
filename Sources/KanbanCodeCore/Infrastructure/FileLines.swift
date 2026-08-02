import Foundation

/// Newline-delimited lines read from a file in large blocks.
///
/// `FileHandle.bytes.lines` walks the file one byte at a time through an async
/// iterator, which costs roughly a fifth of a second per megabyte. Session
/// transcripts routinely pass a hundred megabytes, so a palette search that
/// scans them was spending twenty seconds on a single file. Reading in blocks
/// and splitting on newlines does the same job at I/O speed.
///
/// Blank lines are dropped, which every `.jsonl` reader here wants anyway, and a
/// trailing carriage return is trimmed so CRLF files parse.
public struct FileLines: AsyncSequence, Sendable {
    public typealias Element = String

    public static let defaultChunkSize = 1 << 20

    private let handle: FileHandle
    private let chunkSize: Int

    public init(handle: FileHandle, chunkSize: Int = FileLines.defaultChunkSize) {
        self.handle = handle
        self.chunkSize = Swift.max(4096, chunkSize)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let handle: FileHandle
        private let chunkSize: Int
        private var buffer = Data()
        private var ready: [String] = []
        private var readyIndex = 0
        private var reachedEnd = false

        init(handle: FileHandle, chunkSize: Int) {
            self.handle = handle
            self.chunkSize = chunkSize
        }

        public mutating func next() async throws -> String? {
            while true {
                if readyIndex < ready.count {
                    defer { readyIndex += 1 }
                    return ready[readyIndex]
                }
                if reachedEnd { return nil }

                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty {
                    reachedEnd = true
                    guard !buffer.isEmpty else { return nil }
                    stage(buffer)
                    buffer = Data()
                    continue
                }

                buffer.append(chunk)
                // Split only up to the last newline: that keeps every decoded
                // block whole-lines, so a multi-byte character can never be cut
                // across two chunks.
                guard let lastNewline = Self.lastNewlineOffset(in: buffer) else { continue }
                stage(buffer.prefix(lastNewline))
                buffer = buffer.count > lastNewline + 1
                    ? Data(buffer.dropFirst(lastNewline + 1))
                    : Data()
                await Task.yield()
            }
        }

        /// Offset of the last newline byte, scanned over raw memory. `Data`'s
        /// Collection conformance is slow enough that going through it here
        /// costs more than reading the file did.
        static func lastNewlineOffset(in data: Data) -> Int? {
            data.withUnsafeBytes { raw -> Int? in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                var index = raw.count - 1
                while index >= 0 {
                    if base[index] == UInt8(ascii: "\n") { return index }
                    index -= 1
                }
                return nil
            }
        }

        /// Splits on the newline *byte*. Swift treats "\r\n" as a single
        /// Character, so splitting the decoded string leaves CRLF lines joined.
        private mutating func stage(_ block: Data) {
            var lines: [String] = []
            block.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var start = 0
                while start < raw.count {
                    let found = memchr(base + start, Int32(UInt8(ascii: "\n")), raw.count - start)
                    let breakAt = found.map { UnsafeRawPointer($0) - UnsafeRawPointer(base) } ?? raw.count
                    var end = breakAt
                    if end > start, base[end - 1] == UInt8(ascii: "\r") { end -= 1 }
                    if end > start {
                        lines.append(String(
                            decoding: UnsafeBufferPointer(start: base + start, count: end - start),
                            as: UTF8.self
                        ))
                    }
                    start = breakAt + 1
                }
            }
            ready = lines
            readyIndex = 0
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(handle: handle, chunkSize: chunkSize)
    }
}

extension FileHandle {
    /// Lines read in blocks. See ``FileLines`` for why this exists.
    public var blockLines: FileLines { FileLines(handle: self) }
}
