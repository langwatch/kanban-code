import Foundation
import KanbanCodeRemoteKit

/// Images that come with a remote prompt or task: checked, then written to
/// files that the app's own image flow (clipboard paste into tmux, agtop
/// `--image`) takes by path.
public enum RemotePromptImages {

    public struct Decoded: Equatable, Sendable {
        public var bytes: Data
        /// File extension of the format the bytes are in.
        public var fileExtension: String

        public init(bytes: Data, fileExtension: String) {
            self.bytes = bytes
            self.fileExtension = fileExtension
        }
    }

    /// Decodes and checks every image; the first bad one fails the request.
    /// The format comes from the bytes, not from `mediaType`.
    public static func decode(_ images: [RemoteImage]?) throws -> [Decoded] {
        guard let images, !images.isEmpty else { return [] }
        guard images.count <= RemoteImage.maxCount else {
            throw RemoteHostError.badRequest("at most \(RemoteImage.maxCount) images per request, got \(images.count)")
        }
        return try images.enumerated().map { index, image in
            guard let bytes = image.bytes, !bytes.isEmpty else {
                throw RemoteHostError.badRequest("image \(index + 1) is not valid base64")
            }
            guard bytes.count <= RemoteImage.maxBytes else {
                throw RemoteHostError.badRequest("image \(index + 1) is \(bytes.count) bytes, over the \(RemoteImage.maxBytes) byte limit")
            }
            guard let ext = fileExtension(of: bytes) else {
                throw RemoteHostError.badRequest("image \(index + 1) is not PNG, JPEG, GIF or WebP")
            }
            return Decoded(bytes: bytes, fileExtension: ext)
        }
    }

    /// Writes the images into `directory` and returns their paths, in order.
    public static func write(_ images: [Decoded], to directory: String, prefix: String = "kanban-remote") throws -> [String] {
        guard !images.isEmpty else { return [] }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return try images.map { image in
            let path = (directory as NSString).appendingPathComponent("\(prefix)-\(UUID().uuidString).\(image.fileExtension)")
            try image.bytes.write(to: URL(fileURLWithPath: path))
            return path
        }
    }

    /// Where a prompt's images go, as the Mac chat's own pasted images.
    public static var promptDirectory: String { NSTemporaryDirectory() }

    /// Where a task's images go: they stay with the card, as the New Task dialog's do.
    public static var taskDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/images")
    }

    static func fileExtension(of bytes: Data) -> String? {
        let b = [UInt8](bytes.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: Array("GIF8".utf8)) { return "gif" }
        if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) { return "webp" }
        return nil
    }
}

/// Scrolling a tmux terminal's history for a remote viewer, the way the
/// Mac's card terminal does with the wheel: copy-mode, moved by lines.
public enum RemoteTerminalScroll {
    /// tmux commands for one scroll of `lines` (up when positive). Copy-mode
    /// starts with `-e`, so scrolling back to the bottom leaves it; `-X`
    /// commands are no-ops outside copy-mode, so no key reaches the shell.
    public static func tmuxCommands(session: String, lines: Int) -> [[String]] {
        let count = min(abs(lines), 500)
        if lines > 0 {
            return [
                ["copy-mode", "-e", "-t", session],
                ["send-keys", "-t", session, "-X", "-N", "\(count)", "scroll-up"],
            ]
        }
        if lines < 0 {
            return [["send-keys", "-t", session, "-X", "-N", "\(count)", "scroll-down"]]
        }
        return []
    }
}
