import Foundation
import KanbanCodeRemoteKit

/// One secret found in a file.
struct ScrubMatch: Sendable, Equatable {
    var offset: Int
    var length: Int
    /// The vault name the reference uses.
    var name: String
    var tag: String
    /// Set for a value the vault does not hold yet: it is saved under
    /// `name` before the file changes.
    var newValue: String?
}

/// Finds vault values (by fingerprint) and vendor-format keys (by pattern)
/// in the bytes of a file. It never holds a vault value.
struct ScrubScanner: Sendable {
    let key: ScrubKey
    /// Fingerprints by prefix.
    private let byPrefix: [UInt32: [ScrubFingerprint]]
    private let byMac: [String: ScrubFingerprint]
    /// One bit per prefix fingerprint (its low 24 bits), checked before the dictionary.
    private let bitmap: [UInt64]
    let patterns: ScrubPatterns

    /// The group new finds are saved under.
    static let foundProject = "scrubbed"
    static let foundEnvironment = "found"

    init(entries: [ScrubFingerprint], key: ScrubKey, patterns: ScrubPatterns = .on) {
        self.key = key
        self.patterns = patterns
        var byPrefix: [UInt32: [ScrubFingerprint]] = [:]
        var byMac: [String: ScrubFingerprint] = [:]
        var bitmap = [UInt64](repeating: 0, count: 1 << 18)
        for e in entries {
            byPrefix[e.prefix, default: []].append(e)
            byMac[e.mac] = e
            let bit = Int(e.prefix & 0xFF_FFFF)
            bitmap[bit >> 6] |= 1 << UInt64(bit & 63)
        }
        // The longest candidate first, so a value wins over a part of it.
        self.byPrefix = byPrefix.mapValues { $0.sorted { $0.length > $1.length } }
        self.byMac = byMac
        self.bitmap = bitmap
    }

    /// What changes the result of a scan: the fingerprints and the rules.
    var generation: String {
        let macs = byMac.keys.sorted().joined()
        return "v2:\(patterns.rawValue):" + key.macHex(Array(macs.utf8))
    }

    /// Matches in file order, none overlapping another, none across a line break.
    func scan(_ buf: UnsafeRawBufferPointer) -> [ScrubMatch] {
        var found = exact(buf)
        if patterns != .off { found += vendorKeys(buf, taken: found) }
        found.sort { $0.offset < $1.offset }
        var out: [ScrubMatch] = []
        var end = 0
        for m in found where m.offset >= end {
            out.append(m)
            end = m.offset + m.length
        }
        return out
    }

    private func exact(_ buf: UnsafeRawBufferPointer) -> [ScrubMatch] {
        let n = buf.count
        guard n >= ScrubIndex.minimumLength, !byPrefix.isEmpty, let base = buf.baseAddress else { return [] }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out: [ScrubMatch] = []
        var window: UInt64 = 0
        for i in 0..<7 { window = (window << 8) | UInt64(p[i]) }
        var skipUntil = 0
        bitmap.withUnsafeBufferPointer { bits in
            var i = 7
            while i < n {
                window = (window << 8) | UInt64(p[i])
                let fp = key.prefix(window)
                let bit = Int(fp & 0xFF_FFFF)
                if bits[bit >> 6] & (1 << UInt64(bit & 63)) != 0, let candidates = byPrefix[fp] {
                    let start = i - 7
                    if start >= skipUntil {
                        for e in candidates where start + e.length <= n {
                            let slice = UnsafeRawBufferPointer(start: base + start, count: e.length)
                            if slice.contains(0x0A) { continue }
                            if key.macHex(slice) == e.mac {
                                out.append(ScrubMatch(offset: start, length: e.length, name: e.name, tag: e.tag))
                                skipUntil = start + e.length
                                break
                            }
                        }
                    }
                }
                i += 1
            }
        }
        return out
    }

    // MARK: - Vendor formats

    private static let tokenBytes: [Bool] = {
        var t = [Bool](repeating: false, count: 256)
        for b in UInt8(ascii: "a")...UInt8(ascii: "z") { t[Int(b)] = true }
        for b in UInt8(ascii: "A")...UInt8(ascii: "Z") { t[Int(b)] = true }
        for b in UInt8(ascii: "0")...UInt8(ascii: "9") { t[Int(b)] = true }
        for b in "_-.+/=:".utf8 { t[Int(b)] = true }
        return t
    }()

    /// A run this long is a blob (an image, an archive), not a key.
    private static let longestToken = 4096

    private func vendorKeys(_ buf: UnsafeRawBufferPointer, taken: [ScrubMatch]) -> [ScrubMatch] {
        let n = buf.count
        guard n >= 20, let base = buf.baseAddress else { return [] }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out: [ScrubMatch] = []
        Self.tokenBytes.withUnsafeBufferPointer { isToken in
            var i = 0
            while i < n {
                guard isToken[Int(p[i])] else { i += 1; continue }
                let start = i
                var digits = 0
                while i < n, isToken[Int(p[i])] {
                    if p[i] >= 48 && p[i] <= 57 { digits += 1 }
                    i += 1
                }
                let length = i - start
                guard length >= 20, length <= Self.longestToken, digits >= 2 else { continue }
                let token = String(decoding: UnsafeRawBufferPointer(start: base + start, count: length), as: UTF8.self)
                for secret in SecretDetector.find(in: token, ruleIds: SecretDetector.vendorFormatRuleIds) {
                    guard ScrubIndex.looksSecret(secret.value), ScrubIndex.entropyBits(Array(secret.value.utf8)) >= 3.5 else { continue }
                    let offset = start + token.utf8.distance(from: token.utf8.startIndex, to: secret.range.lowerBound)
                    let bytes = Array(secret.value.utf8)
                    let end = offset + bytes.count
                    let following = UnsafeRawBufferPointer(start: base + end, count: min(3, n - end))
                    guard Self.plausibleKey(secret.value, cutShort: Self.marksCut(following)) else { continue }
                    if taken.contains(where: { $0.offset < offset + bytes.count && offset < $0.offset + $0.length }) { continue }
                    if let known = byMac[key.macHex(bytes)] {
                        out.append(ScrubMatch(offset: offset, length: bytes.count, name: known.name, tag: known.tag))
                        continue
                    }
                    let tag = key.tagHex(secret.value)
                    // Named by the value alone, so every master and every run gives it the same name.
                    let name = VaultSecretName(key: "\(SecretDetector.vendorName(of: secret))_\(tag.prefix(8))",
                                               project: Self.foundProject, environment: Self.foundEnvironment).canonical
                    out.append(ScrubMatch(offset: offset, length: bytes.count, name: name, tag: tag, newValue: secret.value))
                }
            }
        }
        return out
    }
}

// MARK: - Minted keys and the rest

extension ScrubScanner {
    /// Whether the bytes after a value say it was shortened or masked
    /// (`sk-abc123...`, `sk-abc123***`): what is left is not a usable key.
    static func marksCut(_ following: UnsafeRawBufferPointer) -> Bool {
        guard let first = following.first else { return false }
        if first == 0x2A { return true }
        if following.count >= 3 {
            if following[0] == 0x2E, following[1] == 0x2E, following[2] == 0x2E { return true }
            if following[0] == 0xE2, following[1] == 0x80, following[2] == 0xA6 { return true }
        }
        return false
    }

    /// Words a made up key carries and a minted one does not.
    private static let fixtureWords = [
        "test", "fake", "mock", "demo", "dumm", "examp", "sampl", "secret", "token", "invalid", "expired", "wrong",
        "local", "stub", "fixture", "foobar", "hello", "passw", "abc123", "123456", "abcdef", "qwert",
    ]
    private static let fixtureSegments: Set<String> = [
        "my", "your", "foo", "bar", "baz", "abc", "xyz", "key", "new", "old", "dev", "bad", "none", "null", "api", "app", "id",
    ]
    /// `sk-` families whose body is not one plain run.
    private static let knownProviderPrefixes = ["sk-proj-", "sk-ant-", "sk-lw-", "sk-or-", "sk-svcacct-", "sk-admin-"]
    private static let resend = try! NSRegularExpression(pattern: "^re_[A-Za-z0-9]{8}_[A-Za-z0-9]{24}$")

    /// Whether a value in a vendor's format reads as a key some service
    /// minted, and not as a fixture, an example or an identifier that
    /// happens to share the prefix. Only such a value is saved and replaced.
    static func plausibleKey(_ value: String, cutShort: Bool = false) -> Bool {
        guard !cutShort, value.utf8.count <= 300 else { return false }
        var body = Substring(value)
        // The vendor's own words come first and are not judged.
        for prefix in ["sk_live_", "sk_test_", "rk_live_", "rk_test_", "secret_", "key-", "github_pat_", "dckr_pat_", "lin_api_"]
        where body.hasPrefix(prefix) {
            body = body.dropFirst(prefix.count)
        }
        let lower = body.lowercased()
        if fixtureWords.contains(where: { lower.contains($0) }) { return false }
        let segments = body.split(whereSeparator: { "-_.:".contains($0) })
        // After the vendor prefix (two segments at most), a word is a sign of a hand written value.
        for segment in segments.dropFirst(min(2, max(segments.count - 1, 0))) {
            if fixtureSegments.contains(segment.lowercased()) { return false }
            if segment.count >= 4, segment.count <= 12, segment.allSatisfy({ $0 >= "a" && $0 <= "z" }) { return false }
        }
        // The random part: one run of letters and digits, long enough and varied.
        var longest = Substring(), current = body.startIndex
        var index = body.startIndex
        while true {
            let atEnd = index == body.endIndex
            if atEnd || !(body[index].isASCII && (body[index].isLetter || body[index].isNumber)) {
                if body.distance(from: current, to: index) > longest.count { longest = body[current..<index] }
                if atEnd { break }
                current = body.index(after: index)
            }
            index = body.index(after: index)
        }
        guard longest.count >= 12, Set(longest).count >= 8 else { return false }
        if value.hasPrefix("sk-"), !knownProviderPrefixes.contains(where: { value.hasPrefix($0) }) {
            // A bare `sk-` key is one run: `sk-<48 letters and digits>`, `sk-<32 hex>`.
            guard longest.count == value.count - 3, longest.count >= 32 else { return false }
        }
        if value.hasPrefix("re_") {
            return resend.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
        }
        return true
    }
}

/// The kind of file a replacement lands in: what must still parse after it.
enum ScrubFileKind: Sendable, Equatable {
    /// One JSON document per line.
    case jsonl
    /// One JSON document.
    case json
    case text

    static func of(path: String) -> ScrubFileKind {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name.contains(".jsonl") { return .jsonl }
        if name.contains(".json") { return .json }
        return .text
    }
}

enum ScrubRewriter {
    /// A line with its matches replaced by references, the same length as
    /// before: each value becomes its reference followed by spaces, so no
    /// other byte of the line moves and only the bytes of the value are
    /// written. `matches` are relative to the line. Returns nil when nothing
    /// could be replaced, and leaves out a value cut by an escape or too
    /// short for any reference.
    static func rewrite(line: UnsafeRawBufferPointer, matches: [ScrubMatch], kind: ScrubFileKind) -> (bytes: [UInt8], applied: [ScrubMatch])? {
        var out = [UInt8](line)
        var applied: [ScrubMatch] = []
        var cursor = 0
        for m in matches {
            guard m.offset >= cursor, m.offset + m.length <= line.count,
                  let reference = ScrubIndex.reference(name: m.name, tag: m.tag, length: m.length) else { continue }
            // A value right after a backslash starts inside an escape.
            if kind != .text, m.offset > 0, line[m.offset - 1] == 0x5C { continue }
            let padded = reference + [UInt8](repeating: 0x20, count: m.length - reference.count)
            out.replaceSubrange(m.offset..<(m.offset + m.length), with: padded)
            cursor = m.offset + m.length
            applied.append(m)
        }
        guard !applied.isEmpty, out.count == line.count else { return nil }
        return (out, applied)
    }

    static func isJSON(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return false }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: bytes.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }
}
