import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Files attached to a prompt that are not images: a video, a PDF, a zip.
/// The file is copied to the machine where the card's assistant runs, and
/// the prompt carries one line per file, `[File: /absolute/path]`, which
/// the assistant reads like any path. Images keep going inline.
public enum PromptFiles {
    /// The largest file taken.
    public static let maxBytes: Int64 = 2 << 30
    /// Bytes per upload request; each request stays far under the server's
    /// body limit, so a large file never sits whole in memory.
    public static let chunkBytes = 8 << 20
    /// A stored file older than this goes when the next upload starts.
    public static let keepFor: TimeInterval = 14 * 24 * 3600

    static let linePrefix = "[File: "

    /// The prompt line that names a file.
    public static func line(path: String) -> String {
        "\(linePrefix)\(path)]"
    }

    /// `text` with one line per path after it.
    public static func appending(paths: [String], to text: String) -> String {
        guard !paths.isEmpty else { return text }
        let lines = paths.map(line(path:)).joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? lines : trimmed + "\n\n" + lines
    }

    /// The text without its file lines, and the paths they name, in order.
    public static func split(_ text: String) -> (text: String, paths: [String]) {
        guard text.contains(linePrefix) else { return (text, []) }
        var kept: [Substring] = []
        var paths: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let path = path(inLine: line) {
                paths.append(path)
            } else {
                kept.append(line)
            }
        }
        guard !paths.isEmpty else { return (text, []) }
        let rest = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (rest, paths)
    }

    static func path(inLine line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(linePrefix), trimmed.hasSuffix("]") else { return nil }
        let path = String(trimmed.dropFirst(linePrefix.count).dropLast())
        guard path.hasPrefix("/") || path.hasPrefix("~/"), !path.contains("\n") else { return nil }
        return path
    }

    /// A file name safe to keep on disk: the last path component, no
    /// control characters, no leading dots, at most 200 characters.
    public static func safeName(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? ""
        var cleaned = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "\\" })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.count > 200 {
            let ext = (cleaned as NSString).pathExtension
            let keep = 200 - (ext.isEmpty ? 0 : ext.count + 1)
            let stem = String((cleaned as NSString).deletingPathExtension.prefix(max(1, keep)))
            cleaned = ext.isEmpty ? stem : stem + "." + ext
        }
        return cleaned.isEmpty ? "file" : cleaned
    }

    /// Whether an upload id is one the server takes: letters, digits and
    /// dashes, so it is always one directory name.
    public static func isValidUploadId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    /// Whether the file goes as an inline image rather than a path.
    public static func isImage(fileName: String) -> Bool {
        imageExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// "12.4 MB", for chips.
    public static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The error shown for a file over `maxBytes`.
    public static func tooLargeMessage(name: String, size: Int64) -> String {
        "\(name) is \(formattedSize(size)), over the \(formattedSize(maxBytes)) limit for attachments"
    }

    /// The last path component, for chips.
    public static func displayName(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// Answer of `POST /v1/cards/{id}/files`.
public struct RemotePromptFile: Codable, Sendable, Equatable {
    /// The file on the machine the card's assistant runs on. Final once
    /// `received` equals `size`.
    public var path: String
    public var received: Int64
    public var size: Int64

    public init(path: String, received: Int64, size: Int64) {
        self.path = path
        self.received = received
        self.size = size
    }

    public var isComplete: Bool { received >= size }
}

/// One request of a file upload.
public struct RemotePromptFileChunk: Sendable, Equatable {
    public var upload: String
    public var name: String
    public var size: Int64
    public var offset: Int64
    public var data: Data

    public init(upload: String, name: String, size: Int64, offset: Int64, data: Data) {
        self.upload = upload
        self.name = name
        self.size = size
        self.offset = offset
        self.data = data
    }

    /// The chunk of a `POST /v1/cards/{id}/files` request, from its query
    /// and body.
    public static func parse(query: [String: String], body: Data) -> Result<RemotePromptFileChunk, PromptFileError> {
        guard let upload = query["upload"], PromptFiles.isValidUploadId(upload) else {
            return .failure(.badRequest("upload must be an id of letters, digits and dashes"))
        }
        guard let name = query["name"], !name.isEmpty else { return .failure(.badRequest("name is required")) }
        guard let size = Int64(query["size"] ?? ""), size >= 0 else { return .failure(.badRequest("size must be the file's byte count")) }
        guard let offset = Int64(query["offset"] ?? ""), offset >= 0 else { return .failure(.badRequest("offset must be a byte offset")) }
        return .success(RemotePromptFileChunk(upload: upload, name: name, size: size, offset: offset, data: body))
    }
}

public enum PromptFileError: Error, Equatable, LocalizedError {
    case badRequest(String)
    case tooLarge(String)
    /// The offset is not where the file stands; `expected` is.
    case offsetMismatch(expected: Int64)

    public var errorDescription: String? {
        switch self {
        case .badRequest(let message), .tooLarge(let message): message
        case .offsetMismatch(let expected): "the upload stands at byte \(expected)"
        }
    }
}

extension RemoteClient {
    /// POST /v1/cards/{id}/files: one chunk of a file for the card's
    /// prompt. The master that owns the card keeps it where the card's
    /// assistant runs.
    public func uploadPromptFileChunk(cardId: String, _ chunk: RemotePromptFileChunk) async throws -> RemotePromptFile {
        var request = makeRequest("POST", "v1/cards/\(Self.escape(cardId))/files", query: [
            URLQueryItem(name: "upload", value: chunk.upload),
            URLQueryItem(name: "name", value: chunk.name),
            URLQueryItem(name: "size", value: String(chunk.size)),
            URLQueryItem(name: "offset", value: String(chunk.offset)),
        ])
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = chunk.data
        // The last chunk may wait on the copy to a machine the master drives.
        request.timeoutInterval = 600
        let (body, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RemoteClientError.from(status: status, body: body) }
        do {
            return try JSONDecoder.remote.decode(RemotePromptFile.self, from: body)
        } catch {
            throw RemoteClientError.decoding(String(describing: error))
        }
    }

    /// Uploads a file for the card's prompt, `PromptFiles.chunkBytes` at a
    /// time read from disk, and returns its path where the card's
    /// assistant runs. `progress` gets the bytes sent and the total.
    public func uploadPromptFile(
        cardId: String, fileURL: URL, name: String? = nil,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> String {
        let fileName = PromptFiles.safeName(name ?? fileURL.lastPathComponent)
        let size = try PromptFileReader.size(of: fileURL)
        guard size <= PromptFiles.maxBytes else { throw PromptFileError.tooLarge(PromptFiles.tooLargeMessage(name: fileName, size: size)) }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let upload = UUID().uuidString.lowercased()
        var offset: Int64 = 0
        progress(0, size)
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: PromptFiles.chunkBytes) ?? Data()
            let answer = try await uploadPromptFileChunk(cardId: cardId, RemotePromptFileChunk(
                upload: upload, name: fileName, size: size, offset: offset, data: data))
            offset += Int64(data.count)
            progress(offset, size)
            if answer.isComplete { return answer.path }
            guard !data.isEmpty else { throw PromptFileError.badRequest("\(fileName) ended at byte \(offset), short of \(size)") }
        }
    }
}

public enum PromptFileReader {
    public static func size(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
