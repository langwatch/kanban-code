import Compression
import Foundation

/// gzip (RFC 1952) around the raw DEFLATE stream of the Compression framework.
enum RemoteGzip {
    /// HTTP bodies smaller than this go out as they are.
    static let minimumBytes = 8 * 1024

    static func accepts(_ request: RemoteHTTPRequest) -> Bool {
        guard let header = request.header("accept-encoding")?.lowercased() else { return false }
        return header.split(separator: ",").contains { part in
            let fields = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.first == "gzip" else { return false }
            return !fields.dropFirst().contains { $0 == "q=0" || $0 == "q=0.0" }
        }
    }

    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 10 + 1024
        var deflated = Data(count: capacity)
        let written = deflated.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(deflated.prefix(written))
        appendLittleEndian(crc32(data), to: &out)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &out)
        return out
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
