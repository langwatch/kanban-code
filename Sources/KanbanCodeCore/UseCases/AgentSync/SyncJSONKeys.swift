import Foundation

/// Named top-level keys of a JSON object file, read and written as text:
/// the bytes of every other key stay exactly as their program wrote them.
///
/// What travels between machines is each named key's value with its
/// whitespace removed, so the same value gives the same bytes on every
/// platform, whatever else the file holds.
public enum SyncJSONKeys {
    struct Member {
        var key: String
        /// The key as written, quotes included.
        var rawKey: ArraySlice<UInt8>
        var value: ArraySlice<UInt8>
    }

    /// The projection of `data`, or nil when it is not a JSON object (a
    /// file caught half written, a list).
    public static func projection(of data: Data, keys: [String]) -> Data? {
        guard let members = members(of: data) else { return nil }
        var byKey: [String: Member] = [:]
        for member in members { byKey[member.key] = member }
        var out: [UInt8] = [UInt8(ascii: "{")]
        var first = true
        for key in Set(keys).sorted() {
            guard let member = byKey[key] else { continue }
            if !first { out.append(UInt8(ascii: ",")) }
            first = false
            out.append(contentsOf: member.rawKey)
            out.append(UInt8(ascii: ":"))
            out.append(contentsOf: minified(member.value))
        }
        out.append(UInt8(ascii: "}"))
        return Data(out)
    }

    /// The value of each named key `data` holds, without whitespace; nil
    /// when `data` is not a JSON object.
    public static func values(of data: Data, keys: [String]) -> [String: Data]? {
        guard let members = members(of: data) else { return nil }
        let named = Set(keys)
        var out: [String: Data] = [:]
        for member in members where named.contains(member.key) {
            out[member.key] = Data(minified(member.value))
        }
        return out
    }

    /// `data` with the named keys as `projection` has them: a key it holds
    /// is set (in place, or added at the end), a key it lacks is removed.
    /// Every other key keeps its bytes and its place. Nil when either side
    /// is not a JSON object. `data` itself comes back when nothing differs.
    public static func merge(into data: Data, keys: [String], from projection: Data) -> Data? {
        guard let local = members(of: data), let incoming = members(of: projection) else { return nil }
        let named = Set(keys)
        var wanted: [String: Member] = [:]
        for member in incoming where named.contains(member.key) { wanted[member.key] = member }

        var parts: [(key: ArraySlice<UInt8>, value: ArraySlice<UInt8>)] = []
        var seen: Set<String> = []
        var changed = false
        for member in local {
            guard named.contains(member.key) else {
                parts.append((member.rawKey, member.value))
                continue
            }
            guard let want = wanted[member.key], seen.insert(member.key).inserted else {
                changed = true
                continue
            }
            if minified(member.value) == minified(want.value) {
                parts.append((member.rawKey, member.value))
            } else {
                parts.append((member.rawKey, want.value))
                changed = true
            }
        }
        for key in keys where !seen.contains(key) {
            guard let want = wanted[key], seen.insert(key).inserted else { continue }
            parts.append((want.rawKey, want.value))
            changed = true
        }
        guard changed else { return data }

        let bytes = [UInt8](data)
        let indent = indentation(of: bytes, firstKey: local.first?.rawKey.startIndex)
        var out: [UInt8] = [UInt8(ascii: "{")]
        for (index, part) in parts.enumerated() {
            if index > 0 { out.append(UInt8(ascii: ",")) }
            if let indent {
                out.append(UInt8(ascii: "\n"))
                out.append(contentsOf: indent)
            }
            out.append(contentsOf: part.key)
            out.append(UInt8(ascii: ":"))
            if indent != nil { out.append(UInt8(ascii: " ")) }
            out.append(contentsOf: part.value)
        }
        if indent != nil, !parts.isEmpty { out.append(UInt8(ascii: "\n")) }
        out.append(UInt8(ascii: "}"))
        if bytes.last == UInt8(ascii: "\n") { out.append(UInt8(ascii: "\n")) }
        return Data(out)
    }

    /// The whitespace before the first key when the file puts each key on
    /// a line of its own (two spaces for an object with no key yet); nil
    /// for a file written on one line.
    private static func indentation(of bytes: [UInt8], firstKey: Int?) -> [UInt8]? {
        guard let firstKey else {
            return bytes.contains(UInt8(ascii: "\n")) ? Array("  ".utf8) : nil
        }
        var start = firstKey
        while start > 0, bytes[start - 1] == UInt8(ascii: " ") || bytes[start - 1] == UInt8(ascii: "\t") { start -= 1 }
        guard start > 0, bytes[start - 1] == UInt8(ascii: "\n") else { return nil }
        return Array(bytes[start..<firstKey])
    }

    // MARK: - Reading

    /// The top-level members of a JSON object, in order.
    static func members(of data: Data) -> [Member]? {
        // The whole text must be JSON: the scan below only finds where the
        // top-level values start and end.
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        let bytes = [UInt8](data)
        var i = 0
        skipSpace(bytes, &i)
        guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { return nil }
        i += 1
        var members: [Member] = []
        skipSpace(bytes, &i)
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { return members }
        while i < bytes.count {
            skipSpace(bytes, &i)
            guard let keyEnd = stringEnd(bytes, i) else { return nil }
            let rawKey = bytes[i..<keyEnd]
            guard let key = (try? JSONSerialization.jsonObject(with: Data([UInt8(ascii: "[")] + rawKey + [UInt8(ascii: "]")])) as? [String])?.first
            else { return nil }
            i = keyEnd
            skipSpace(bytes, &i)
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            skipSpace(bytes, &i)
            guard let valueEnd = valueEnd(bytes, i) else { return nil }
            members.append(Member(key: key, rawKey: rawKey, value: bytes[i..<valueEnd]))
            i = valueEnd
            skipSpace(bytes, &i)
            guard i < bytes.count else { return nil }
            if bytes[i] == UInt8(ascii: "}") { return members }
            guard bytes[i] == UInt8(ascii: ",") else { return nil }
            i += 1
        }
        return nil
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    private static func skipSpace(_ bytes: [UInt8], _ i: inout Int) {
        while i < bytes.count, isSpace(bytes[i]) { i += 1 }
    }

    /// The index after the closing quote of the string that starts at `start`.
    private static func stringEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "\"") else { return nil }
        var i = start + 1
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\\") {
                i += 2
            } else if bytes[i] == UInt8(ascii: "\"") {
                return i + 1
            } else {
                i += 1
            }
        }
        return nil
    }

    /// The index after the value that starts at `start`.
    private static func valueEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        switch bytes[start] {
        case UInt8(ascii: "\""):
            return stringEnd(bytes, start)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = start
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\""):
                    guard let end = stringEnd(bytes, i) else { return nil }
                    i = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default:
                    break
                }
                i += 1
            }
            return nil
        default:
            var i = start
            while i < bytes.count, !isSpace(bytes[i]), bytes[i] != UInt8(ascii: ","), bytes[i] != UInt8(ascii: "}") { i += 1 }
            return i > start ? i : nil
        }
    }

    /// A value with the whitespace outside its strings removed.
    static func minified(_ value: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(value.count)
        var inString = false
        var escaped = false
        for byte in value {
            if inString {
                out.append(byte)
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
                out.append(byte)
            } else if !isSpace(byte) {
                out.append(byte)
            }
        }
        return out
    }
}
