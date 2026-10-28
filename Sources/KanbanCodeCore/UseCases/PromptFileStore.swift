import Foundation
import KanbanCodeRemoteKit

/// Files attached to prompts, kept under `<kanbanHome>/files/<upload>/<name>`
/// on the machine where the card's assistant runs. Each upload has its own
/// directory, so the file keeps its original name and extension.
public enum PromptFileStore {
    public static func directory(kanbanHome: String) -> String {
        (kanbanHome as NSString).appendingPathComponent("files")
    }

    /// Where an upload's file ends up.
    public static func path(upload: String, name: String, kanbanHome: String) -> String {
        ((directory(kanbanHome: kanbanHome) as NSString).appendingPathComponent(upload) as NSString)
            .appendingPathComponent(PromptFiles.safeName(name))
    }

    /// Writes one chunk of an upload. The bytes land in `<path>.part`, which
    /// becomes the file once all `size` bytes are there. A chunk must start
    /// where the part stands.
    public static func receive(_ chunk: RemotePromptFileChunk, kanbanHome: String, now: Date = Date()) throws -> RemotePromptFile {
        let name = PromptFiles.safeName(chunk.name)
        guard chunk.size <= PromptFiles.maxBytes else {
            throw PromptFileError.tooLarge(PromptFiles.tooLargeMessage(name: name, size: chunk.size))
        }
        guard chunk.offset + Int64(chunk.data.count) <= chunk.size else {
            throw PromptFileError.badRequest("the chunk runs past the file's \(chunk.size) bytes")
        }
        let final = path(upload: chunk.upload, name: name, kanbanHome: kanbanHome)
        let part = final + ".part"
        let fm = FileManager.default
        if fm.fileExists(atPath: final) {
            // A retried last chunk: the file is already whole.
            return RemotePromptFile(path: final, received: chunk.size, size: chunk.size)
        }
        if chunk.offset == 0 {
            removeOld(kanbanHome: kanbanHome, now: now)
            try fm.createDirectory(atPath: (final as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: part, contents: nil)
        }
        guard let attributes = try? fm.attributesOfItem(atPath: part),
              let current = (attributes[.size] as? NSNumber)?.int64Value else {
            throw PromptFileError.offsetMismatch(expected: 0)
        }
        guard current == chunk.offset else { throw PromptFileError.offsetMismatch(expected: current) }
        if !chunk.data.isEmpty {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: part))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: chunk.data)
        }
        let received = current + Int64(chunk.data.count)
        if received == chunk.size {
            try fm.moveItem(atPath: part, toPath: final)
            return RemotePromptFile(path: final, received: received, size: chunk.size)
        }
        return RemotePromptFile(path: final, received: received, size: chunk.size)
    }

    /// Copies a file on this machine into the store and returns the copy's
    /// path. On APFS the copy is a clone and takes no space of its own; it
    /// keeps the file readable after a dragged temporary file goes away.
    public static func importLocal(_ url: URL, kanbanHome: String, now: Date = Date()) throws -> String {
        let name = PromptFiles.safeName(url.lastPathComponent)
        let size = try PromptFileReader.size(of: url)
        guard size <= PromptFiles.maxBytes else {
            throw PromptFileError.tooLarge(PromptFiles.tooLargeMessage(name: name, size: size))
        }
        removeOld(kanbanHome: kanbanHome, now: now)
        let destination = path(upload: UUID().uuidString.lowercased(), name: name, kanbanHome: kanbanHome)
        try FileManager.default.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: destination))
        return destination
    }

    /// Removes upload directories older than `PromptFiles.keepFor`.
    static func removeOld(kanbanHome: String, now: Date) {
        let fm = FileManager.default
        let root = directory(kanbanHome: kanbanHome)
        for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let path = (root as NSString).appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > PromptFiles.keepFor else { continue }
            try? fm.removeItem(atPath: path)
        }
    }
}
