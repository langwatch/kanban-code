import Foundation

/// The last name each peer master reported, by machine id, in
/// `~/.kanban-code/known-machines.json`. Cards owned by a peer that has not
/// answered since launch (or is unreachable) show this name instead of the
/// raw machine id.
public struct KnownMachinesStore: Sendable {
    public let filePath: String

    public init(basePath: String? = nil) {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        self.filePath = (base as NSString).appendingPathComponent("known-machines.json")
    }

    /// The stored names; empty when the file is missing or unreadable.
    public func read() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let names = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return names.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    public func write(_ names: [String: String]) throws {
        let dir = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(names).write(to: URL(fileURLWithPath: filePath), options: .atomic)
    }
}
