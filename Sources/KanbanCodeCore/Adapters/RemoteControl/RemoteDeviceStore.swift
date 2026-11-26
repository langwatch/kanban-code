#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import KanbanCodeRemoteKit
#if canImport(Security)
import Security
#endif
import Synchronization

/// Paired devices of the remote control server, kept in
/// `~/.kanban-code/remote/devices.json`:
///
/// ```json
/// {"devices":[{"id":"...","name":"iPhone","scope":"full","tokenHash":"<sha256 hex>",
///              "createdAt":"2026-09-26T10:00:00.000Z","lastSeenAt":null}]}
/// ```
///
/// Only the SHA-256 of a token is stored. `kanban remote pair` writes the same
/// file, so every read checks whether the file changed on disk first.
public final class RemoteDeviceStore: Sendable {
    public struct Record: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var scope: RemoteScope
        public var tokenHash: String
        public var createdAt: Date
        public var lastSeenAt: Date?
        /// The APNs token the device registered, if it takes pushes.
        public var push: RemotePushRegistration?

        public var device: RemoteDevice {
            RemoteDevice(id: id, name: name, scope: scope, createdAt: createdAt, lastSeenAt: lastSeenAt)
        }
    }

    private struct FileBody: Codable {
        var devices: [Record]
    }

    private struct FileStamp: Equatable {
        var mtime: timespec
        var size: off_t
        var inode: ino_t

        static func == (a: FileStamp, b: FileStamp) -> Bool {
            a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec && a.size == b.size && a.inode == b.inode
        }
    }

    private struct State {
        var records: [Record] = []
        var stamp: FileStamp?
        var loaded = false
    }

    public static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/remote/devices.json")
    }

    /// lastSeenAt is written at most this often per device.
    public static let lastSeenWriteInterval: TimeInterval = 60

    public let path: String
    private let state = Mutex(State())

    public init(path: String = RemoteDeviceStore.defaultPath) {
        self.path = path
    }

    // MARK: - Public API

    public func list() -> [RemoteDevice] {
        state.withLock { s in
            refresh(&s)
            return s.records.map(\.device)
        }
    }

    /// Pairs a new device. The token is returned once and never stored.
    @discardableResult
    public func add(name: String, scope: RemoteScope) throws -> (RemoteDevice, token: String) {
        let token = Self.makeToken()
        let record = Record(
            id: UUID().uuidString.lowercased(),
            name: name,
            scope: scope,
            tokenHash: Self.hash(token),
            createdAt: Date(),
            lastSeenAt: nil,
            push: nil
        )
        try state.withLock { s in
            refresh(&s)
            s.records.append(record)
            try save(&s)
        }
        return (record.device, token)
    }

    /// Removes a device. Returns false when no device had that id.
    @discardableResult
    public func revoke(id: String) throws -> Bool {
        try state.withLock { s in
            refresh(&s)
            let before = s.records.count
            s.records.removeAll { $0.id == id }
            guard s.records.count != before else { return false }
            try save(&s)
            return true
        }
    }

    /// The device a token belongs to, or nil. Compares every stored hash in
    /// constant time and stamps lastSeenAt (at most once a minute).
    public func authenticate(token: String) -> RemoteDevice? {
        let candidate = Array(Self.hash(token).utf8)
        return state.withLock { s -> RemoteDevice? in
            refresh(&s)
            var match: Int?
            for (i, record) in s.records.enumerated() where Self.constantTimeEqual(Array(record.tokenHash.utf8), candidate) {
                match = i
            }
            guard let i = match else { return nil }
            let now = Date()
            if s.records[i].lastSeenAt.map({ now.timeIntervalSince($0) >= Self.lastSeenWriteInterval }) ?? true {
                s.records[i].lastSeenAt = now
                try? save(&s)
            }
            return s.records[i].device
        }
    }

    /// A device that takes pushes, and the token it registered.
    public struct PushTarget: Sendable, Equatable {
        public var deviceId: String
        public var deviceName: String
        public var registration: RemotePushRegistration
    }

    /// Saves the APNs token of a device. The same token on another device
    /// record (the app paired again) moves to this one. Returns false when no
    /// device has that id.
    @discardableResult
    public func setPush(deviceId: String, _ registration: RemotePushRegistration?) throws -> Bool {
        try state.withLock { s in
            refresh(&s)
            guard let i = s.records.firstIndex(where: { $0.id == deviceId }) else { return false }
            var stamped = registration
            stamped?.updatedAt = Date()
            if let token = registration?.token {
                for j in s.records.indices where j != i && s.records[j].push?.token == token { s.records[j].push = nil }
            }
            s.records[i].push = stamped
            try save(&s)
            return true
        }
    }

    /// Forgets a device's token when it is still the one APNs refused.
    public func clearPush(deviceId: String, token: String) throws {
        try state.withLock { s in
            refresh(&s)
            guard let i = s.records.firstIndex(where: { $0.id == deviceId }), s.records[i].push?.token == token else { return }
            s.records[i].push = nil
            try save(&s)
        }
    }

    /// Every device with an APNs token: the full scope phones.
    public func pushTargets() -> [PushTarget] {
        state.withLock { s in
            refresh(&s)
            return s.records.compactMap { r in
                guard r.scope == .full, let push = r.push else { return nil }
                return PushTarget(deviceId: r.id, deviceName: r.name, registration: push)
            }
        }
    }

    /// Whether a device id is still paired (re-reading the file if it changed).
    public func contains(id: String) -> Bool {
        state.withLock { s in
            refresh(&s)
            return s.records.contains { $0.id == id }
        }
    }

    /// Re-reads the file when it changed on disk. Returns true when it did.
    @discardableResult
    public func reloadIfChanged() -> Bool {
        state.withLock { s in
            let before = s.records
            refresh(&s)
            return before != s.records
        }
    }

    // MARK: - Tokens

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func makeToken() -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var out = "kc_"
        while out.count < 43 {
            var bytes = [UInt8](repeating: 0, count: 64)
            #if canImport(Security)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
            #else
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = rng.next() }
            #endif
            // 248 = 4 * 62: rejecting bytes above it keeps every character equally likely.
            for b in bytes where b < 248 && out.count < 43 {
                out.append(alphabet[Int(b) % 62])
            }
        }
        return out
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    // MARK: - File

    private func currentStamp() -> FileStamp? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        #if canImport(Darwin)
        return FileStamp(mtime: st.st_mtimespec, size: st.st_size, inode: st.st_ino)
        #else
        return FileStamp(mtime: st.st_mtim, size: st.st_size, inode: st.st_ino)
        #endif
    }

    private func refresh(_ s: inout State) {
        let stamp = currentStamp()
        if s.loaded && stamp == s.stamp { return }
        s.loaded = true
        s.stamp = stamp
        guard stamp != nil, let data = FileManager.default.contents(atPath: path) else {
            s.records = []
            return
        }
        if let body = try? JSONDecoder.remote.decode(FileBody.self, from: data) {
            s.records = body.devices
        } else {
            KanbanCodeLog.warn("remote", "devices file \(path) is unreadable, treating it as empty")
            s.records = []
        }
    }

    private func save(_ s: inout State) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder.remote
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileBody(devices: s.records))
        let tmp = dir + "/.devices.\(UUID().uuidString).tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp, path) == 0 else {
            unlink(tmp)
            throw CocoaError(.fileWriteUnknown)
        }
        s.stamp = currentStamp()
    }
}
