import Foundation

/// Where images pasted into a chat are kept while their prompt goes out:
/// `~/.kanban-code/images/chat`. The prompt journal names these paths, so a
/// send that fails can be sent again with its images. Files older than
/// `maxAge` are removed as new ones arrive.
public struct ChatImageStore: Sendable {
    public let directory: String
    public let maxAge: TimeInterval

    public init(kanbanHome: String? = nil, maxAge: TimeInterval = 30 * 24 * 3600) {
        let home = kanbanHome ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.directory = (home as NSString).appendingPathComponent("images/chat")
        self.maxAge = maxAge
    }

    /// Writes each image and returns their paths, in order. An image that
    /// cannot be written throws, so a prompt never leaves without one of its
    /// images.
    public func save(_ images: [Data], fileExtension: String = "png", now: Date = .now) throws -> [String] {
        guard !images.isEmpty else { return [] }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        prune(now: now)
        return try images.map { data in
            let path = (directory as NSString).appendingPathComponent("kanban-chat-\(UUID().uuidString).\(fileExtension)")
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return path
        }
    }

    /// Removes the images older than `maxAge`.
    public func prune(now: Date = .now) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for name in names {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > maxAge else { continue }
            try? fm.removeItem(atPath: path)
        }
    }
}
