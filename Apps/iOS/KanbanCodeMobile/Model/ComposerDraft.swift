import Foundation
import Observation
import UIKit
import KanbanCodeRemoteKit

/// What is typed and attached for one card, kept per Mac and card until it
/// is sent: across leaving the card, switching tabs and relaunching the app.
@Observable
final class ComposerDraft {
    let key: String
    var text: String {
        didSet { if text != oldValue { save() } }
    }
    private(set) var images: [DraftImage]

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
    }

    /// A draft that is never saved, for previews.
    init(preview text: String = "") {
        key = "preview"
        directory = nil
        self.text = text
        images = []
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
        try? fm.removeItem(at: directory)
        guard !images.isEmpty else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, image) in images.enumerated() {
            try? image.data.write(to: directory.appendingPathComponent(String(format: "%02d.jpg", index)))
        }
    }

    private static func loadImages(from directory: URL?) -> [DraftImage] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".jpg") }.sorted().compactMap { name in
            (try? Data(contentsOf: directory.appendingPathComponent(name))).map { DraftImage(id: UUID(), data: $0) }
        }
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
