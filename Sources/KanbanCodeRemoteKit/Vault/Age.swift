#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The age v1 file format (https://age-encryption.org/v1) with X25519
/// recipients, so a vault file opens with the `age` CLI and the recovery key:
///
///     age -d -i recovery.txt vault.age
///
/// Only what the vault needs: X25519 identities and recipients, P-256
/// recipients whose private half stays in a device (the `piv-p256` stanza
/// of age-plugin-se and age-plugin-yubikey), encrypt to one or more
/// recipients, decrypt with one identity. No passphrases, no armor.
public enum Age {
    public enum AgeError: Error, Equatable, CustomStringConvertible {
        case badKey(String)
        case malformed(String)
        case noMatchingIdentity
        case badMAC
        case badPayload

        public var description: String {
            switch self {
            case .badKey(let why): "bad age key: \(why)"
            case .malformed(let why): "not an age file: \(why)"
            case .noMatchingIdentity: "no identity matches a recipient of this file"
            case .badMAC: "the age header MAC does not match"
            case .badPayload: "the age payload failed to decrypt"
            }
        }
    }

    /// An X25519 secret key, `AGE-SECRET-KEY-1...` as text.
    public struct Identity: Sendable, Equatable {
        public let rawKey: Data

        public init(rawKey: Data) throws {
            guard rawKey.count == 32 else { throw AgeError.badKey("an X25519 key is 32 bytes") }
            self.rawKey = rawKey
        }

        public static func generate() -> Identity {
            let key = Curve25519.KeyAgreement.PrivateKey()
            return try! Identity(rawKey: key.rawRepresentation)
        }

        public init(text: String) throws {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let line = trimmed.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first { !$0.hasPrefix("#") && !$0.isEmpty } ?? ""
            let (hrp, data) = try Bech32.decode(line)
            guard hrp == "age-secret-key-" else { throw AgeError.badKey("expected AGE-SECRET-KEY-1...") }
            try self.init(rawKey: data)
        }

        public var text: String {
            Bech32.encode(hrp: "age-secret-key-", data: rawKey).uppercased()
        }

        public var recipient: Recipient {
            let key = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawKey)
            return try! Recipient(rawKey: key.publicKey.rawRepresentation)
        }
    }

    /// An X25519 public key, `age1...` as text.
    public struct Recipient: Sendable, Equatable, Hashable {
        public let rawKey: Data

        public init(rawKey: Data) throws {
            guard rawKey.count == 32 else { throw AgeError.badKey("an X25519 key is 32 bytes") }
            self.rawKey = rawKey
        }

        public init(text: String) throws {
            let (hrp, data) = try Bech32.decode(text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard hrp == "age" else { throw AgeError.badKey("expected age1...") }
            try self.init(rawKey: data)
        }

        public var text: String { Bech32.encode(hrp: "age", data: rawKey) }
    }

    /// A P-256 public key in compressed form (33 bytes), `age1se1...` as
    /// text. Its private half is a device key: see `AgeP256Key`.
    public struct P256Recipient: Sendable, Equatable, Hashable {
        public let compressed: Data

        public init(compressed: Data) throws {
            guard compressed.count == 33, (try? P256.KeyAgreement.PublicKey(compressedRepresentation: compressed)) != nil else {
                throw AgeError.badKey("a compressed P-256 key is 33 bytes")
            }
            self.compressed = compressed
        }

        public init(text: String) throws {
            let (hrp, data) = try Bech32.decode(text.trimmingCharacters(in: .whitespacesAndNewlines))
            guard hrp == "age1se" else { throw AgeError.badKey("expected age1se1...") }
            try self.init(compressed: data)
        }

        public var text: String { Bech32.encode(hrp: "age1se", data: compressed) }

        /// The stanza tag: the first four bytes of the key's SHA-256.
        var tag: Data { Data(SHA256.hash(data: compressed).prefix(4)) }
    }

    /// Either kind of recipient, by its text.
    public enum AnyRecipient: Sendable, Equatable, Hashable {
        case x25519(Recipient)
        case p256(P256Recipient)

        public init(text: String) throws {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("age1se1") {
                self = .p256(try P256Recipient(text: trimmed))
            } else {
                self = .x25519(try Recipient(text: trimmed))
            }
        }

        public var text: String {
            switch self {
            case .x25519(let r): r.text
            case .p256(let r): r.text
            }
        }
    }

    static let intro = "age-encryption.org/v1\n"
    static let p256Label = "piv-p256"
    static let x25519Label = "age-encryption.org/v1/X25519"
    static let chunkSize = 64 * 1024

    // MARK: - Encrypt

    public static func encrypt(_ plaintext: Data, to recipients: [Recipient]) throws -> Data {
        try encrypt(plaintext, to: recipients.map(AnyRecipient.x25519))
    }

    public static func encrypt(_ plaintext: Data, to recipients: [AnyRecipient]) throws -> Data {
        guard !recipients.isEmpty else { throw AgeError.badKey("no recipients") }
        let fileKey = randomBytes(16)
        var header = intro
        for recipient in recipients {
            switch recipient {
            case .x25519(let recipient):
                let ephemeral = Curve25519.KeyAgreement.PrivateKey()
                let share = ephemeral.publicKey.rawRepresentation
                let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.rawKey)
                let shared = try ephemeral.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) }
                let wrapKey = hkdf(ikm: shared, salt: share + recipient.rawKey, info: x25519Label)
                let sealed = try ChaChaPoly.seal(fileKey, using: wrapKey, nonce: ChaChaPoly.Nonce(data: Data(count: 12)))
                header += "-> X25519 \(b64(share))\n"
                header += wrapBody(b64(sealed.ciphertext + sealed.tag))
            case .p256(let recipient):
                let ephemeral = P256.KeyAgreement.PrivateKey()
                let share = ephemeral.publicKey.compressedRepresentation
                let theirs = try P256.KeyAgreement.PublicKey(compressedRepresentation: recipient.compressed)
                let shared = try ephemeral.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) }
                let wrapKey = hkdf(ikm: shared, salt: share + recipient.compressed, info: p256Label)
                let sealed = try ChaChaPoly.seal(fileKey, using: wrapKey, nonce: ChaChaPoly.Nonce(data: Data(count: 12)))
                header += "-> \(p256Label) \(b64(recipient.tag)) \(b64(share))\n"
                header += wrapBody(b64(sealed.ciphertext + sealed.tag))
            }
        }
        header += "---"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(header.utf8), using: hkdf(ikm: fileKey, salt: Data(), info: "header"))
        var out = Data((header + " " + b64(Data(mac)) + "\n").utf8)

        let nonce = randomBytes(16)
        out.append(nonce)
        let payloadKey = hkdf(ikm: fileKey, salt: nonce, info: "payload")
        var counter: UInt64 = 0
        var offset = 0
        repeat {
            let end = min(offset + chunkSize, plaintext.count)
            let last = end == plaintext.count
            let chunk = plaintext.subdata(in: offset..<end)
            let sealed = try ChaChaPoly.seal(chunk, using: payloadKey, nonce: try chunkNonce(counter, last: last))
            out.append(sealed.ciphertext)
            out.append(sealed.tag)
            counter += 1
            offset = end
        } while offset < plaintext.count
        return out
    }

    // MARK: - Decrypt

    /// One recipient stanza of a header.
    struct Stanza {
        var type: String
        var args: [String]
        var body: Data
    }

    public static func decrypt(_ file: Data, with identity: Identity) throws -> Data {
        try decrypt(file) { stanzas in
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identity.rawKey)
            let ownRecipient = key.publicKey.rawRepresentation
            for stanza in stanzas where stanza.type == "X25519" {
                guard stanza.args.count == 1, let share = unb64(stanza.args[0]), share.count == 32,
                      stanza.body.count == 32 else { throw AgeError.malformed("bad X25519 stanza") }
                let shared = try key.sharedSecretFromKeyAgreement(with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: share))
                    .withUnsafeBytes { Data($0) }
                guard shared != Data(count: 32) else { continue }
                let wrapKey = hkdf(ikm: shared, salt: share + ownRecipient, info: x25519Label)
                if let opened = openFileKey(stanza.body, wrapKey: wrapKey) { return opened }
            }
            return nil
        }
    }

    /// Decrypts with a P-256 key held by a device: the key agreement runs
    /// wherever the private half lives.
    public static func decrypt(_ file: Data, with key: any AgeP256Key) throws -> Data {
        try decrypt(file) { stanzas in
            let own = key.recipient
            let tag = b64(own.tag)
            for stanza in stanzas where stanza.type == p256Label {
                guard stanza.args.count == 2, stanza.args[0] == tag else { continue }
                guard let share = unb64(stanza.args[1]), share.count == 33, stanza.body.count == 32 else {
                    throw AgeError.malformed("bad piv-p256 stanza")
                }
                let shared = try key.sharedSecret(withEphemeral: share)
                let wrapKey = hkdf(ikm: shared, salt: share + own.compressed, info: p256Label)
                if let opened = openFileKey(stanza.body, wrapKey: wrapKey) { return opened }
            }
            return nil
        }
    }

    private static func openFileKey(_ body: Data, wrapKey: SymmetricKey) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: Data(count: 12)),
                                                  ciphertext: body.prefix(16), tag: body.suffix(16)) else { return nil }
        return try? ChaChaPoly.open(box, using: wrapKey)
    }

    /// The P-256 recipients a file names by tag, without opening it.
    public static func p256Tags(of file: Data) -> [String] {
        ((try? header(of: file))?.stanzas ?? []).filter { $0.type == p256Label }.compactMap(\.args.first)
    }

    private static func header(of file: Data) throws -> (stanzas: [Stanza], mac: Data, headerBytes: Data, payload: Data.Index) {
        var cursor = file.startIndex
        func readLine() throws -> String {
            guard let newline = file[cursor...].firstIndex(of: 0x0A) else { throw AgeError.malformed("header ends early") }
            let line = String(decoding: file[cursor..<newline], as: UTF8.self)
            cursor = file.index(after: newline)
            return line
        }

        guard try readLine() + "\n" == intro else { throw AgeError.malformed("unknown version line") }
        var stanzas: [Stanza] = []
        var macLine = ""
        while true {
            let line = try readLine()
            if line.hasPrefix("---") {
                macLine = line
                break
            }
            guard line.hasPrefix("-> ") else { throw AgeError.malformed("expected a stanza") }
            let parts = line.dropFirst(3).split(separator: " ").map(String.init)
            guard let type = parts.first else { throw AgeError.malformed("empty stanza") }
            var body = ""
            while true {
                let bodyLine = try readLine()
                body += bodyLine
                if bodyLine.count < 64 { break }
            }
            guard let bytes = unb64(body) else { throw AgeError.malformed("bad stanza body") }
            stanzas.append(Stanza(type: type, args: Array(parts.dropFirst()), body: bytes))
        }
        let headerEnd = cursor - macLine.utf8.count - 1 + 3  // up to and including "---"
        let headerBytes = file[file.startIndex..<headerEnd]
        guard macLine.hasPrefix("--- "), let mac = unb64(String(macLine.dropFirst(4))) else {
            throw AgeError.malformed("bad MAC line")
        }
        return (stanzas, mac, Data(headerBytes), cursor)
    }

    private static func decrypt(_ file: Data, unwrap: ([Stanza]) throws -> Data?) throws -> Data {
        let (stanzas, mac, headerBytes, payload) = try header(of: file)
        guard let fileKey = try unwrap(stanzas) else { throw AgeError.noMatchingIdentity }
        let hmacKey = hkdf(ikm: fileKey, salt: Data(), info: "header")
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: headerBytes, using: hmacKey) else {
            throw AgeError.badMAC
        }

        var cursor = payload
        guard file.distance(from: cursor, to: file.endIndex) >= 16 + 16 else { throw AgeError.badPayload }
        let nonce = file[cursor..<file.index(cursor, offsetBy: 16)]
        cursor = file.index(cursor, offsetBy: 16)
        let payloadKey = hkdf(ikm: fileKey, salt: Data(nonce), info: "payload")
        var plaintext = Data()
        var counter: UInt64 = 0
        let sealedChunk = chunkSize + 16
        while cursor < file.endIndex {
            let remaining = file.distance(from: cursor, to: file.endIndex)
            let size = min(sealedChunk, remaining)
            let last = remaining <= sealedChunk
            guard size >= 16 else { throw AgeError.badPayload }
            let chunk = file[cursor..<file.index(cursor, offsetBy: size)]
            let box = try ChaChaPoly.SealedBox(
                nonce: try chunkNonce(counter, last: last),
                ciphertext: chunk.prefix(size - 16),
                tag: chunk.suffix(16)
            )
            guard let opened = try? ChaChaPoly.open(box, using: payloadKey) else { throw AgeError.badPayload }
            if !last && opened.count != chunkSize { throw AgeError.badPayload }
            if last && opened.isEmpty && counter > 0 { throw AgeError.badPayload }
            plaintext.append(opened)
            cursor = file.index(cursor, offsetBy: size)
            counter += 1
        }
        guard counter > 0 else { throw AgeError.badPayload }
        return plaintext
    }

    // MARK: - Helpers

    public static func hkdf(ikm: Data, salt: Data, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    static func chunkNonce(_ counter: UInt64, last: Bool) throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        var c = counter
        for i in stride(from: 10, through: 3, by: -1) {
            bytes[i] = UInt8(c & 0xFF)
            c >>= 8
        }
        bytes[11] = last ? 1 : 0
        return try ChaChaPoly.Nonce(data: bytes)
    }

    static func randomBytes(_ count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }

    static func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    static func unb64(_ text: String) -> Data? {
        guard !text.contains("=") else { return nil }
        let padded = text + String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: padded)
    }

    /// Stanza body lines are 64 columns; the last one is always shorter,
    /// empty when the body fills its lines exactly.
    static func wrapBody(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while rest.count >= 64 {
            out += rest.prefix(64) + "\n"
            rest = rest.dropFirst(64)
        }
        return out + rest + "\n"
    }
}

/// A P-256 private key that never leaves where it lives: the Secure Enclave
/// of a device, or memory in tests. It only answers the key agreement.
public protocol AgeP256Key: Sendable {
    var recipient: Age.P256Recipient { get }
    /// The ECDH shared secret (32 bytes) with an ephemeral public key in
    /// compressed form.
    func sharedSecret(withEphemeral compressed: Data) throws -> Data
}

/// BIP 173 Bech32, as age uses it for keys (no length limit).
enum Bech32 {
    static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    static func polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(v)
            for i in 0..<5 where (top >> UInt32(i)) & 1 == 1 {
                chk ^= gen[i]
            }
        }
        return chk
    }

    static func hrpExpand(_ hrp: String) -> [UInt8] {
        let bytes = Array(hrp.utf8)
        return bytes.map { $0 >> 5 } + [0] + bytes.map { $0 & 31 }
    }

    static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var out: [UInt8] = []
        let maxv = (1 << to) - 1
        for value in data {
            guard Int(value) >> from == 0 else { return nil }
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((acc << (to - bits)) & maxv)) }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        return out
    }

    static func encode(hrp: String, data: Data) -> String {
        let values = convertBits(Array(data), from: 8, to: 5, pad: true)!
        let mod = polymod(hrpExpand(hrp) + values + [0, 0, 0, 0, 0, 0]) ^ 1
        let checksum = (0..<6).map { UInt8((mod >> UInt32(5 * (5 - $0))) & 31) }
        return hrp + "1" + String((values + checksum).map { charset[Int($0)] })
    }

    static func decode(_ text: String) throws -> (hrp: String, data: Data) {
        guard text == text.lowercased() || text == text.uppercased() else { throw Age.AgeError.badKey("mixed case") }
        let lower = text.lowercased()
        guard let sep = lower.lastIndex(of: "1"), sep != lower.startIndex else { throw Age.AgeError.badKey("no separator") }
        let hrp = String(lower[..<sep])
        var values: [UInt8] = []
        for ch in lower[lower.index(after: sep)...] {
            guard let i = charset.firstIndex(of: ch) else { throw Age.AgeError.badKey("bad character") }
            values.append(UInt8(i))
        }
        guard values.count >= 6, polymod(hrpExpand(hrp) + values) == 1 else { throw Age.AgeError.badKey("bad checksum") }
        guard let bytes = convertBits(Array(values.dropLast(6)), from: 5, to: 8, pad: false) else {
            throw Age.AgeError.badKey("bad padding")
        }
        return (hrp, Data(bytes))
    }
}
