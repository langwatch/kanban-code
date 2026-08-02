import Foundation

/// ASCII-case-insensitive substring search over raw bytes.
///
/// A quoted palette search only keeps lines containing one of its exact
/// phrases, so a transcript holding none of them cannot contribute anything.
/// Deciding that from the bytes costs a memory scan; deciding it from decoded
/// lines costs a `lowercased()` allocation per line, which on a hundred-megabyte
/// transcript is twenty seconds.
public enum ByteSearch {

    /// Lowercased UTF-8 bytes of each needle, or nil when any needle is not
    /// pure ASCII. Non-ASCII case folding is not a byte operation, so those
    /// queries have to fall back to the decoded path to stay correct.
    public static func asciiNeedles(_ needles: [String]) -> [[UInt8]]? {
        var prepared: [[UInt8]] = []
        for needle in needles {
            let bytes = Array(needle.lowercased().utf8)
            guard !bytes.isEmpty, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
            prepared.append(bytes)
        }
        return prepared.isEmpty ? nil : prepared
    }

    /// Whether `haystack` contains any needle, folding A-Z to a-z on both sides.
    ///
    /// Folds once into scratch memory and hands the scanning to `memmem`. A
    /// hand-rolled comparison loop is the obvious way to write this and is an
    /// order of magnitude slower, because the app ships as a debug build where
    /// every Swift subscript keeps its bounds check.
    public static func containsAny(
        _ haystack: UnsafeBufferPointer<UInt8>,
        needles: [[UInt8]]
    ) -> Bool {
        guard let base = haystack.baseAddress, !haystack.isEmpty else { return false }
        let count = haystack.count

        // A needle with no letters, like a PR number, matches the same either
        // way, so the whole fold pass can be skipped for it.
        let (caseless, cased) = needles.partitioned { needle in
            !needle.contains { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }
        }
        if search(base, count, for: caseless) { return true }
        guard !cased.isEmpty else { return false }

        let folded = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { folded.deallocate() }
        folded.update(from: base, count: count)
        for index in 0..<count {
            let byte = folded[index]
            if byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") { folded[index] = byte + 32 }
        }
        return search(folded, count, for: cased)
    }

    private static func search(
        _ haystack: UnsafePointer<UInt8>,
        _ count: Int,
        for needles: [[UInt8]]
    ) -> Bool {
        for needle in needles where needle.count <= count {
            let found = needle.withUnsafeBufferPointer { pointer -> Bool in
                guard let needleBase = pointer.baseAddress else { return false }
                return memmem(haystack, count, needleBase, pointer.count) != nil
            }
            if found { return true }
        }
        return false
    }

    /// The longest byte run present in every needle.
    ///
    /// A PR search expands to phrases like `#4480`, `pull/4480` and `pr 4480`,
    /// all built around the same number. Matching any of them implies matching
    /// that shared run, so a block without it cannot match at all, and one pass
    /// replaces one pass per phrase.
    public static func commonGate(_ needles: [[UInt8]], minimumLength: Int = 3) -> [UInt8]? {
        guard needles.count > 1,
              let shortest = needles.min(by: { $0.count < $1.count }),
              shortest.count >= minimumLength
        else { return nil }

        var length = shortest.count
        while length >= minimumLength {
            for offset in 0...(shortest.count - length) {
                let candidate = Array(shortest[offset..<(offset + length)])
                let sharedByAll = needles.allSatisfy { needle in
                    needle.withUnsafeBufferPointer { haystack in
                        candidate.withUnsafeBufferPointer { probe in
                            guard let hb = haystack.baseAddress, let pb = probe.baseAddress else { return false }
                            return memmem(hb, haystack.count, pb, probe.count) != nil
                        }
                    }
                }
                if sharedByAll { return candidate }
            }
            length -= 1
        }
        return nil
    }

    /// Whether the file at `path` contains any needle. Reads in blocks with an
    /// overlap so a needle straddling a block boundary is still found.
    public static func fileContainsAny(
        path: String,
        needles: [[UInt8]],
        chunkSize: Int = 1 << 20
    ) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }

        let overlap = (needles.map(\.count).max() ?? 1) - 1
        let gate = commonGate(needles).map { [$0] }
        var carry: [UInt8] = []
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                return false
            }
            // Scan the block in place. Copying it into a growing array first is
            // the obvious way to handle the seam between blocks and costs more
            // than the search: only the seam itself needs copying.
            if !carry.isEmpty {
                var seam = carry
                seam.append(contentsOf: chunk.prefix(overlap))
                if seam.withUnsafeBufferPointer({ containsAny($0, needles: needles) }) { return true }
            }
            let hit = chunk.withUnsafeBytes { raw -> Bool in
                let bytes = raw.bindMemory(to: UInt8.self)
                if let gate, !containsAny(bytes, needles: gate) { return false }
                return containsAny(bytes, needles: needles)
            }
            if hit { return true }
            carry = overlap > 0 ? Array(chunk.suffix(overlap)) : []
        }
    }

}

extension Array {
    /// Splits into (matching, rest) in one pass.
    fileprivate func partitioned(by belongsInFirst: (Element) -> Bool) -> ([Element], [Element]) {
        var first: [Element] = []
        var second: [Element] = []
        for element in self {
            if belongsInFirst(element) { first.append(element) } else { second.append(element) }
        }
        return (first, second)
    }
}

extension String {
    /// Whether this string contains any needle, compared ASCII-case-insensitively.
    /// Avoids the `lowercased()` copy that a per-line prefilter would otherwise
    /// pay on every line it rejects.
    public func containsAnyASCII(_ needles: [[UInt8]]) -> Bool {
        var copy = self
        return copy.withUTF8 { ByteSearch.containsAny($0, needles: needles) }
    }
}
