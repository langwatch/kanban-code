import Foundation
import Observation
import UIKit
import KanbanCodeRemoteKit

/// What is typed and attached for one card, kept per Mac and card until it
/// is sent: across leaving the card, switching tabs and relaunching the app.
/// Stashes set a message aside for later, as agtop's ctrl+s does.
@Observable
final class ComposerDraft {
    let key: String
    var text: String {
        didSet { if text != oldValue { save() } }
    }
    private(set) var images: [DraftImage]
    /// Messages set aside, oldest first.
    private(set) var stashes: [Stash]

    struct Stash: Codable, Identifiable, Equatable {
        let id: UUID
        var text: String
        /// JPEGs, as in the composer.
        var images: [Data]
        var at: Date

        /// One line for a menu.
        var preview: String {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let images = images.isEmpty ? "" : (images.count == 1 ? "1 image" : "\(images.count) images")
            return [line.isEmpty ? nil : String(line.prefix(60)), images.isEmpty ? nil : images]
                .compactMap { $0 }.joined(separator: " + ")
        }
    }

    struct DraftImage: Identifiable, Equatable {
        let id: UUID
        /// JPEG, already scaled down for sending.
        let data: Data
    }

    /// Images are scaled so their long side is at most this, then sent as JPEG.
    static let maxImageSide: CGFloat = 2048

    private let directory: URL?

    init(server: UUID, cardId: String) {
        key = "\(server.uuidString)|\(cardId)"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        directory = base?.appendingPathComponent("drafts", isDirectory: true)
            .appendingPathComponent(Self.fileSafe(key), isDirectory: true)
        text = UserDefaults.standard.string(forKey: Self.textKey(key)) ?? ""
        images = Self.loadImages(from: directory)
        stashes = Self.loadStashes(from: directory)
    }

    /// A draft that is never saved, for previews.
    init(preview text: String = "") {
        key = "preview"
        directory = nil
        self.text = text
        images = []
        stashes = []
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
    }

    var canAddImages: Bool { images.count < RemoteImage.maxCount }

    /// Adds a picked or captured image, scaled down and re-encoded as JPEG.
    /// Returns false when the image cannot be read or would be too big.
    @discardableResult
    func addImage(_ data: Data) -> Bool {
        guard canAddImages, let jpeg = Self.prepare(data) else { return false }
        images.append(DraftImage(id: UUID(), data: jpeg))
        saveImages()
        return true
    }

    func removeImage(_ id: UUID) {
        images.removeAll { $0.id == id }
        saveImages()
    }

    func clear() {
        text = ""
        images = []
        saveImages()
    }

    /// Puts a message into the composer, as if typed and attached.
    func load(text: String, images: [Data]) {
        self.text = text
        self.images = images.map { DraftImage(id: UUID(), data: $0) }
        saveImages()
    }

    /// Sets the composer's message aside and clears the composer.
    func stash() {
        guard !isEmpty else { return }
        stashes.append(Stash(id: UUID(), text: text, images: images.map(\.data), at: .now))
        saveStashes()
        clear()
    }

    /// Brings a stash back into the composer (the latest when `id` is nil).
    /// Whatever the composer holds is stashed in its place.
    func restore(_ id: UUID? = nil) {
        guard let target = id.flatMap({ id in stashes.first { $0.id == id } }) ?? stashes.last else { return }
        stashes.removeAll { $0.id == target.id }
        if !isEmpty {
            stashes.append(Stash(id: UUID(), text: text, images: images.map(\.data), at: .now))
        }
        saveStashes()
        load(text: target.text, images: target.images)
    }

    func deleteStash(_ id: UUID) {
        stashes.removeAll { $0.id == id }
        saveStashes()
    }

    var remoteImages: [RemoteImage] {
        images.map { RemoteImage(bytes: $0.data, mediaType: "image/jpeg") }
    }

    // MARK: Storage

    private func save() {
        guard directory != nil else { return }
        if text.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.textKey(key))
        } else {
            UserDefaults.standard.set(text, forKey: Self.textKey(key))
        }
    }

    private func saveImages() {
        guard let directory else { return }
        let fm = FileManager.default
        let folder = directory.appendingPathComponent("images", isDirectory: true)
        try? fm.removeItem(at: folder)
        Self.removeLooseImages(in: directory)
        guard !images.isEmpty else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, image) in images.enumerated() {
            try? image.data.write(to: folder.appendingPathComponent(String(format: "%02d.jpg", index)))
        }
    }

    private func saveStashes() {
        guard let directory else { return }
        let file = directory.appendingPathComponent("stashes.json")
        guard !stashes.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(stashes).write(to: file, options: .atomic)
    }

    private static func loadImages(from directory: URL?) -> [DraftImage] {
        guard let directory else { return [] }
        // Drafts from before images had their own folder keep them loose.
        for folder in [directory.appendingPathComponent("images", isDirectory: true), directory] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            let images = names.filter { $0.hasSuffix(".jpg") }.sorted().compactMap { name in
                (try? Data(contentsOf: folder.appendingPathComponent(name))).map { DraftImage(id: UUID(), data: $0) }
            }
            if !images.isEmpty { return images }
        }
        return []
    }

    private static func removeLooseImages(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".jpg") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func loadStashes(from directory: URL?) -> [Stash] {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("stashes.json")) else { return [] }
        return (try? JSONDecoder().decode([Stash].self, from: data)) ?? []
    }

    private static func textKey(_ key: String) -> String { "draft.text.\(key)" }

    private static func fileSafe(_ key: String) -> String {
        key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
    }

    /// Scales the image down and encodes it as JPEG under the server's limit.
    static func prepare(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxImageSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        for quality in [0.8, 0.6, 0.4] as [CGFloat] {
            if let jpeg = rendered.jpegData(compressionQuality: quality), jpeg.count <= RemoteImage.maxBytes {
                return jpeg
            }
        }
        return nil
    }
}
