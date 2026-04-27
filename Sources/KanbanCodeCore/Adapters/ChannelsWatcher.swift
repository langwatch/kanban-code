import Foundation

/// File-system watcher for the chat channels directory. Uses DispatchSource with
/// a nonisolated factory so the event handler never inherits @MainActor (which
/// would crash the runtime when fired on a background queue — see CLAUDE.md).
///
/// Emits `.kanbanCodeChannelsChanged` when `channels.json` changes, and
/// `.kanbanCodeChannelMessagesChanged` (with channel name in userInfo) when any
/// `<name>.jsonl` is appended to. The reducer responds by dispatching refresh
/// actions.
public final class ChannelsWatcher: @unchecked Sendable {
    private let baseDir: String
    private let queue: DispatchQueue
    private var channelsFileSource: DispatchSourceFileSystemObject?
    private var channelsFileFd: Int32 = -1
    private var readStateSource: DispatchSourceFileSystemObject?
    private var readStateFd: Int32 = -1

    private var perChannelSources: [String: DispatchSourceFileSystemObject] = [:]
    private var perChannelFds: [String: Int32] = [:]
    private var dmDirSource: DispatchSourceFileSystemObject?
    private var dmDirFd: Int32 = -1
    private var perDMSources: [String: DispatchSourceFileSystemObject] = [:]
    private var perDMFds: [String: Int32] = [:]
    private let lock = NSLock()

    public init(baseDir: String? = nil) {
        let root = baseDir ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.baseDir = (root as NSString).appendingPathComponent("channels")
        self.queue = DispatchQueue(label: "kanban-code.channels-watcher", qos: .userInitiated)
    }

    public func start() {
        ensureDirs()
        watchChannelsFile()
        refreshChannelLogs()
        watchDMDirectory()
        refreshDMLogs()
        watchReadStateFile()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        // DispatchSource cancel handlers own fd cleanup. Closing here as well
        // risks double-close if the kernel reuses the descriptor number.
        channelsFileSource?.cancel()
        channelsFileSource = nil
        channelsFileFd = -1
        for (_, src) in perChannelSources { src.cancel() }
        perChannelSources.removeAll()
        perChannelFds.removeAll()
        readStateSource?.cancel(); readStateSource = nil
        readStateFd = -1
        dmDirSource?.cancel(); dmDirSource = nil
        dmDirFd = -1
        for (_, src) in perDMSources { src.cancel() }
        perDMSources.removeAll()
        perDMFds.removeAll()
    }

    /// Called by the UI after it learns about newly-created channels.
    public func syncChannelLogs(_ names: [String]) {
        lock.lock()
        let current = Set(perChannelSources.keys)
        let wanted = Set(names)
        let toAdd = wanted.subtracting(current)
        let toDrop = current.subtracting(wanted)
        lock.unlock()

        for name in toDrop { unwatchChannelLog(name: name) }
        for name in toAdd { watchChannelLog(name: name) }
    }

    private func refreshChannelLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: baseDir) else { return }
        let logs = files.filter { $0.hasSuffix(".jsonl") && !$0.contains("/") }
        let names = logs.map { ($0 as NSString).deletingPathExtension }
        syncChannelLogs(names)
    }

    private func ensureDirs() {
        try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        let dm = (baseDir as NSString).appendingPathComponent("dm")
        try? FileManager.default.createDirectory(atPath: dm, withIntermediateDirectories: true)
        // Touch channels.json if missing so the watcher has something to open.
        let file = (baseDir as NSString).appendingPathComponent("channels.json")
        if !FileManager.default.fileExists(atPath: file) {
            try? Data("{\"channels\":[]}".utf8).write(to: URL(fileURLWithPath: file))
        }
    }

    // MARK: - Channels.json

    private func watchChannelsFile() {
        guard channelsFileSource == nil else { return }
        attachChannelsFileWatcher()
    }

    /// (Re-)attach a watcher to channels.json. The file is rewritten atomically
    /// by both the CLI and the Swift store (`writeFile → renameSync(tmp, target)`),
    /// which orphans any existing fd. After a `.delete`/`.rename`, this re-opens
    /// a fresh fd on the new inode so we keep getting updates.
    private func attachChannelsFileWatcher() {
        let path = (baseDir as NSString).appendingPathComponent("channels.json")
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = Self.makeFileSource(fd: fd, queue: queue) { [weak self] in
            guard let self else { return }
            // When channels.json changes, re-scan the channels dir so any newly
            // created <name>.jsonl files also get per-file watchers attached.
            // Without this, the first message in a freshly-created channel is
            // invisible to the UI until the app is restarted.
            self.queue.async { self.refreshChannelLogs() }
            NotificationCenter.default.post(name: .kanbanCodeChannelsChanged, object: nil)
            // The writer uses atomic rename, which orphans our fd. Re-attach
            // so the NEXT change also fires.
            self.queue.async { self.reattachChannelsFile() }
        } onCancel: {
            close(fd)
        }
        lock.lock()
        channelsFileSource = source
        channelsFileFd = fd
        lock.unlock()
    }

    private func reattachChannelsFile() {
        lock.lock()
        let oldSource = channelsFileSource
        channelsFileSource = nil
        channelsFileFd = -1
        lock.unlock()
        oldSource?.cancel()
        attachChannelsFileWatcher()
    }

    // MARK: - Per-channel jsonl

    private func watchChannelLog(name: String) {
        let path = (baseDir as NSString).appendingPathComponent("\(name).jsonl")
        if !FileManager.default.fileExists(atPath: path) {
            // Touch the file so `open(O_EVTONLY)` succeeds.
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = Self.makeFileSource(fd: fd, queue: queue) {
            NotificationCenter.default.post(
                name: .kanbanCodeChannelMessagesChanged,
                object: nil,
                userInfo: ["channelName": name]
            )
        } onCancel: {
            close(fd)
        }
        lock.lock()
        perChannelSources[name] = source
        perChannelFds[name] = fd
        lock.unlock()
    }

    private func unwatchChannelLog(name: String) {
        lock.lock()
        let src = perChannelSources.removeValue(forKey: name)
        perChannelFds.removeValue(forKey: name)
        lock.unlock()
        src?.cancel()
    }

    // MARK: - Read state

    private func watchReadStateFile() {
        guard readStateSource == nil else { return }
        attachReadStateWatcher()
    }

    private func attachReadStateWatcher() {
        let path = (baseDir as NSString).appendingPathComponent("read-state.json")
        if !FileManager.default.fileExists(atPath: path) {
            try? "{}".write(toFile: path, atomically: true, encoding: .utf8)
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = Self.makeFileSource(fd: fd, queue: queue) { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .kanbanCodeReadStateChanged, object: nil)
            // Atomic-rename writers orphan the fd — re-attach.
            self.queue.async { self.reattachReadState() }
        } onCancel: {
            close(fd)
        }
        lock.lock()
        readStateSource = source
        readStateFd = fd
        lock.unlock()
    }

    private func reattachReadState() {
        lock.lock()
        let oldSource = readStateSource
        readStateSource = nil
        readStateFd = -1
        lock.unlock()
        oldSource?.cancel()
        attachReadStateWatcher()
    }

    // MARK: - DM directory + logs

    private var dmDir: String {
        (baseDir as NSString).appendingPathComponent("dm")
    }

    private func watchDMDirectory() {
        guard dmDirSource == nil else { return }
        let path = dmDir
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = Self.makeFileSource(fd: fd, queue: queue) { [weak self] in
            // Directory changed (likely new DM log file). Re-scan.
            self?.queue.async { self?.refreshDMLogs() }
            NotificationCenter.default.post(name: .kanbanCodeDMLogsChanged, object: nil)
        } onCancel: {
            close(fd)
        }
        dmDirSource = source
        dmDirFd = fd
    }

    private func refreshDMLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dmDir) else { return }
        let logs = files.filter { $0.hasSuffix(".jsonl") }
        let keys = logs.map { ($0 as NSString).deletingPathExtension }

        lock.lock()
        let current = Set(perDMSources.keys)
        let wanted = Set(keys)
        let toAdd = wanted.subtracting(current)
        let toDrop = current.subtracting(wanted)
        lock.unlock()

        for key in toDrop { unwatchDMLog(key: key) }
        for key in toAdd { watchDMLog(key: key) }
    }

    private func watchDMLog(key: String) {
        let path = (dmDir as NSString).appendingPathComponent("\(key).jsonl")
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = Self.makeFileSource(fd: fd, queue: queue) {
            NotificationCenter.default.post(
                name: .kanbanCodeDMLogsChanged,
                object: nil,
                userInfo: ["dmKey": key]
            )
        } onCancel: {
            close(fd)
        }
        lock.lock()
        perDMSources[key] = source
        perDMFds[key] = fd
        lock.unlock()
    }

    private func unwatchDMLog(key: String) {
        lock.lock()
        let src = perDMSources.removeValue(forKey: key)
        perDMFds.removeValue(forKey: key)
        lock.unlock()
        src?.cancel()
    }

    // MARK: - Nonisolated factory (critical: keeps event handler out of @MainActor)

    private nonisolated static func makeFileSource(
        fd: Int32,
        queue: DispatchQueue,
        onEvent: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) -> DispatchSourceFileSystemObject {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: queue
        )
        src.setEventHandler { onEvent() }
        src.setCancelHandler { onCancel() }
        src.resume()
        return src
    }
}

public extension Notification.Name {
    /// Posted when `channels.json` changes on disk.
    static let kanbanCodeChannelsChanged = Notification.Name("kanbanCodeChannelsChanged")

    /// Posted when `<name>.jsonl` changes. `userInfo["channelName"] as? String` is the channel name.
    static let kanbanCodeChannelMessagesChanged = Notification.Name("kanbanCodeChannelMessagesChanged")

    /// Posted when anything under `channels/dm/` changes.
    /// `userInfo["dmKey"] as? String` is the pair key (sorted cardIds/handles joined by `__`).
    static let kanbanCodeDMLogsChanged = Notification.Name("kanbanCodeDMLogsChanged")

    /// Posted when `channels/read-state.json` changes (e.g. another process marked a channel read).
    static let kanbanCodeReadStateChanged = Notification.Name("kanbanCodeReadStateChanged")
}
