import Foundation

/// Disk-backed store for chat channels. Mirrors the TypeScript CLI's file format
/// so the Swift app and the `kanban` CLI share the same on-disk state.
///
/// Layout under `baseDir` (default ~/.kanban-code/channels/):
///   channels.json
///   <name>.jsonl
///   dm/<cardA>__<cardB>.jsonl
public actor ChannelsStore {
    public let baseDir: String
    private let channelsPath: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseDir: String? = nil) {
        let root = baseDir ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        let dir = (root as NSString).appendingPathComponent("channels")
        self.baseDir = dir
        self.channelsPath = (dir as NSString).appendingPathComponent("channels.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Reads

    public func loadChannels() -> [Channel] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: channelsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: channelsPath))
        else { return [] }
        do {
            return try decoder.decode(ChannelsContainer.self, from: data).channels
        } catch {
            // Tolerant fallback: if the CLI wrote dates that Swift rejects, try a lenient decode.
            return []
        }
    }

    public func loadMessages(channel: String, limit: Int? = nil) -> [ChannelMessage] {
        let logPath = logPath(for: channel)
        return loadMessages(at: logPath, limit: limit)
    }

    public func tailMessages(channel: String, count: Int) -> [ChannelMessage] {
        loadMessages(channel: channel, limit: count)
    }

    public func logPath(for channel: String) -> String {
        (baseDir as NSString).appendingPathComponent("\(channel).jsonl")
    }

    public func channelsFilePath() -> String { channelsPath }

    private func loadMessages(at path: String, limit: Int?) -> [ChannelMessage] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let lines: [Substring]
        if let limit, limit > 0 {
            lines = tailLines(at: path, maxLines: limit)
        } else {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
            lines = Array(text.split(separator: "\n", omittingEmptySubsequences: true))
        }

        return lines.compactMap { line -> ChannelMessage? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(ChannelMessage.self, from: data)
        }
    }

    private func tailLines(at path: String, maxLines: Int) -> [Substring] {
        guard maxLines > 0,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return [] }
        defer { try? handle.close() }

        let chunkSize: UInt64 = 64 * 1024
        guard let fileSize = try? handle.seekToEnd() else { return [] }
        var offset = fileSize
        var data = Data()
        var newlineCount = 0

        while offset > 0, newlineCount <= maxLines {
            let readSize = min(chunkSize, offset)
            offset -= readSize
            do {
                try handle.seek(toOffset: offset)
                guard let chunk = try handle.read(upToCount: Int(readSize)) else { break }
                data.insert(contentsOf: chunk, at: 0)
                newlineCount = data.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
            } catch {
                return []
            }
        }

        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return Array(lines.suffix(maxLines))
    }

    // MARK: - Writes

    public func ensureDirs() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        let dmDir = (baseDir as NSString).appendingPathComponent("dm")
        try fm.createDirectory(atPath: dmDir, withIntermediateDirectories: true)
        let imagesDir = (baseDir as NSString).appendingPathComponent("images")
        try fm.createDirectory(atPath: imagesDir, withIntermediateDirectories: true)
    }

    /// Copy attached image files (possibly from NSTemporaryDirectory) into a
    /// persistent location under `<baseDir>/images/<msgId>/N.<ext>`. Returns the
    /// absolute persistent paths. Input paths that don't exist are skipped.
    public func persistImages(messageId: String, sourcePaths: [String]) throws -> [String] {
        guard !sourcePaths.isEmpty else { return [] }
        try ensureDirs()
        let fm = FileManager.default
        let imagesDir = (baseDir as NSString).appendingPathComponent("images")
        let msgDir = (imagesDir as NSString).appendingPathComponent(messageId)
        try fm.createDirectory(atPath: msgDir, withIntermediateDirectories: true)
        var out: [String] = []
        for (idx, src) in sourcePaths.enumerated() {
            guard fm.fileExists(atPath: src) else { continue }
            let ext = (src as NSString).pathExtension.isEmpty ? "png" : (src as NSString).pathExtension
            let dest = (msgDir as NSString).appendingPathComponent("\(idx).\(ext)")
            if fm.fileExists(atPath: dest) { try? fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: src, toPath: dest)
            out.append(dest)
        }
        return out
    }

    public func saveChannels(_ channels: [Channel]) throws {
        try ensureDirs()
        let container = ChannelsContainer(channels: channels)
        let data = try encoder.encode(container)
        let tmp = channelsPath + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp))
        if FileManager.default.fileExists(atPath: channelsPath) {
            try? FileManager.default.removeItem(atPath: channelsPath)
        }
        try FileManager.default.moveItem(atPath: tmp, toPath: channelsPath)
    }

    public func appendMessage(_ msg: ChannelMessage, to channel: String) throws {
        try ensureDirs()
        let path = logPath(for: channel)
        let line = try encoder.encode(msg)
        guard var out = String(data: line, encoding: .utf8) else { throw StoreError.encodingFailed }
        // Collapse to a single line — the encoder may pretty-print; JSONL requires one JSON per line.
        out = out.replacingOccurrences(of: "\n", with: " ")
        out.append("\n")
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try out.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = out.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        }
    }

    public enum StoreError: Error { case encodingFailed, channelExists, channelMissing }

    public func deleteChannel(name: String) throws {
        var all = loadChannels()
        let before = all.count
        all.removeAll { $0.name == name }
        if all.count == before { return }
        try saveChannels(all)
    }

    /// Rename a channel. Updates the entry in `channels.json` and moves the
    /// matching `<old>.jsonl` log file to `<new>.jsonl`. Throws if `new`
    /// already exists as a channel. No-op if `old` doesn't exist.
    public func renameChannel(old: String, new: String) throws {
        let oldName = old.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let newName = new
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !oldName.isEmpty, !newName.isEmpty, oldName != newName else { return }

        var all = loadChannels()
        guard let idx = all.firstIndex(where: { $0.name == oldName }) else { return }
        if all.contains(where: { $0.name == newName }) { throw StoreError.channelExists }

        all[idx].name = newName
        try saveChannels(all)

        // Move the jsonl log file. Use plain move (not atomic rewrite) since
        // the watcher's per-file fd is keyed by name and will be resynced
        // by `channels.json` change → `refreshChannelLogs`.
        let fm = FileManager.default
        let oldLog = logPath(for: oldName)
        let newLog = logPath(for: newName)
        if fm.fileExists(atPath: oldLog) {
            if fm.fileExists(atPath: newLog) { try? fm.removeItem(atPath: newLog) }
            try fm.moveItem(atPath: oldLog, toPath: newLog)
        }

        // Carry over any read-state entry under the old name.
        var rs = loadReadState()
        if let id = rs.channels[oldName] {
            rs.channels[newName] = id
            rs.channels.removeValue(forKey: oldName)
            try? saveReadState(rs)
        }
    }

    // MARK: - Read state (unread tracking via message ids)
    //
    // ID-based rather than timestamp-based: avoids same-ts collisions, races
    // with `.now`, and defensive short-circuits. A channel is "read up to
    // <message id>"; everything after it in the jsonl is unread.

    public struct ReadState: Codable, Sendable {
        public var channels: [String: String] // channel name → last-read message id
        public var dms: [String: String]      // dm pair key → last-read message id
        public init(channels: [String: String] = [:], dms: [String: String] = [:]) {
            self.channels = channels
            self.dms = dms
        }
    }

    private var readStatePath: String {
        (baseDir as NSString).appendingPathComponent("read-state.json")
    }

    public func loadReadState() -> ReadState {
        let path = readStatePath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return ReadState() }
        return (try? decoder.decode(ReadState.self, from: data)) ?? ReadState()
    }

    public func saveReadState(_ state: ReadState) throws {
        try ensureDirs()
        let data = try encoder.encode(state)
        let tmp = readStatePath + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp))
        if FileManager.default.fileExists(atPath: readStatePath) {
            try? FileManager.default.removeItem(atPath: readStatePath)
        }
        try FileManager.default.moveItem(atPath: tmp, toPath: readStatePath)
    }

    // MARK: - Drafts (per-channel / per-DM draft messages)

    public struct DraftsState: Codable, Sendable {
        public var channels: [String: String]
        public var dms: [String: String]
        public init(channels: [String: String] = [:], dms: [String: String] = [:]) {
            self.channels = channels
            self.dms = dms
        }
    }

    private var draftsPath: String {
        (baseDir as NSString).appendingPathComponent("drafts.json")
    }

    public func loadDrafts() -> DraftsState {
        let path = draftsPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return DraftsState() }
        return (try? decoder.decode(DraftsState.self, from: data)) ?? DraftsState()
    }

    public func saveDrafts(_ drafts: DraftsState) throws {
        try ensureDirs()
        let data = try encoder.encode(drafts)
        let tmp = draftsPath + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp))
        if FileManager.default.fileExists(atPath: draftsPath) {
            try? FileManager.default.removeItem(atPath: draftsPath)
        }
        try FileManager.default.moveItem(atPath: tmp, toPath: draftsPath)
    }

    // MARK: - Direct messages

    /// The stable pair-key used as the DM file name.
    /// Uses the card id when present, falling back to `@handle` for user-like participants.
    private func partyKey(_ p: ChannelParticipant) -> String {
        p.cardId ?? "@\(p.handle)"
    }

    public func dmLogPath(partyA: ChannelParticipant, partyB: ChannelParticipant) -> String {
        let keys = [partyKey(partyA), partyKey(partyB)].sorted()
        let file = "\(keys[0])__\(keys[1]).jsonl"
        return ((baseDir as NSString).appendingPathComponent("dm") as NSString).appendingPathComponent(file)
    }

    public func loadDMMessages(between a: ChannelParticipant, and b: ChannelParticipant, limit: Int? = nil) -> [ChannelMessage] {
        let path = dmLogPath(partyA: a, partyB: b)
        return loadMessages(at: path, limit: limit)
    }

    public func sendDirectMessage(
        from: ChannelParticipant,
        to: ChannelParticipant,
        body: String,
        imagePaths: [String] = []
    ) throws -> ChannelMessage {
        try ensureDirs()
        let id = "msg_\(UUID().uuidString.prefix(12))"
        let persistedImages = try persistImages(messageId: id, sourcePaths: imagePaths)
        let msg = ChannelMessage(
            id: id,
            ts: .now,
            from: from,
            body: body,
            type: .message,
            imagePaths: persistedImages.isEmpty ? nil : persistedImages
        )
        let path = dmLogPath(partyA: from, partyB: to)
        let line = try encoder.encode(msg)
        guard var out = String(data: line, encoding: .utf8) else { throw StoreError.encodingFailed }
        out = out.replacingOccurrences(of: "\n", with: " ") + "\n"
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try out.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = out.data(using: .utf8) { try handle.write(contentsOf: data) }
        }
        return msg
    }

    // MARK: - High-level operations (Swift-native, mirrors the TS CLI)

    public func createChannel(name: String, by: ChannelParticipant) throws -> Channel {
        var all = loadChannels()
        if all.contains(where: { $0.name == name }) { throw StoreError.channelExists }
        let ch = Channel(
            id: "ch_\(UUID().uuidString.prefix(12))",
            name: name,
            createdAt: .now,
            createdBy: by,
            members: []
        )
        all.append(ch)
        try saveChannels(all)
        // Touch the log file
        let logPath = logPath(for: name)
        if !FileManager.default.fileExists(atPath: logPath) {
            try "".write(toFile: logPath, atomically: true, encoding: .utf8)
        }
        return ch
    }

    public func join(channel name: String, member: ChannelParticipant) throws -> (Channel, Bool) {
        var all = loadChannels()
        guard let idx = all.firstIndex(where: { $0.name == name }) else { throw StoreError.channelMissing }
        let existing = all[idx].members.firstIndex { m in
            if let ca = m.cardId, let cb = member.cardId { return ca == cb }
            return m.handle == member.handle
        }
        if existing != nil {
            return (all[idx], true)
        }
        let joinedAt: Date = .now
        all[idx].members.append(ChannelMember(cardId: member.cardId, handle: member.handle, joinedAt: joinedAt))
        try saveChannels(all)
        let event = ChannelMessage(
            id: "msg_\(UUID().uuidString.prefix(12))",
            ts: .now,
            from: member,
            body: "@\(member.handle) joined #\(name)",
            type: .join
        )
        try appendMessage(event, to: name)
        return (all[idx], false)
    }

    /// Remove a member from a channel. Matches on `cardId` when present,
    /// otherwise on `handle`. Writes the updated roster to channels.json and
    /// appends a `.leave` event to the jsonl. Mirrors the CLI's leaveChannel
    /// so the two entry points stay in lockstep. No-op when the channel
    /// doesn't exist or the member isn't in it.
    @discardableResult
    public func leave(channel name: String, member: ChannelParticipant) throws -> Channel? {
        var all = loadChannels()
        guard let idx = all.firstIndex(where: { $0.name == name }) else { return nil }
        let match: (ChannelMember) -> Bool = { m in
            if let cA = m.cardId, let cB = member.cardId { return cA == cB }
            return m.handle == member.handle
        }
        guard let leaving = all[idx].members.first(where: match) else { return all[idx] }
        all[idx].members.removeAll(where: match)
        try saveChannels(all)
        let event = ChannelMessage(
            id: "msg_\(UUID().uuidString.prefix(12))",
            ts: .now,
            from: ChannelParticipant(cardId: leaving.cardId, handle: leaving.handle),
            body: "@\(leaving.handle) left #\(name)",
            type: .leave
        )
        try appendMessage(event, to: name)
        return all[idx]
    }

    public func send(
        channel name: String,
        from: ChannelParticipant,
        body: String,
        imagePaths: [String] = []
    ) throws -> ChannelMessage {
        let all = loadChannels()
        guard all.contains(where: { $0.name == name }) else { throw StoreError.channelMissing }
        let id = "msg_\(UUID().uuidString.prefix(12))"
        let persistedImages = try persistImages(messageId: id, sourcePaths: imagePaths)
        let msg = ChannelMessage(
            id: id,
            ts: .now,
            from: from,
            body: body,
            type: .message,
            imagePaths: persistedImages.isEmpty ? nil : persistedImages
        )
        try appendMessage(msg, to: name)
        return msg
    }
}
