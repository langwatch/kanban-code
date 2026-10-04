import Foundation

/// Where the assistant of a card's terminal runs, which decides how an
/// image pasted or dropped on that terminal reaches it.
public enum TerminalImageRoute: Equatable, Sendable {
    /// On this Mac: the assistant reads the Mac's clipboard itself.
    case local
    /// On a boxd or ssh machine this Mac drives.
    case machine(String)
    /// On another master, which owns the card.
    case peer(machineId: String, cardId: String)

    /// `peerCard` is the owner and id of the card when another master owns
    /// it; `machine` the machine this Mac runs the session on. The owner
    /// comes first: its terminal streams from there whatever this Mac knows
    /// of the session.
    public static func route(peerCard: (machineId: String, cardId: String)?, machine: String?) -> TerminalImageRoute {
        if let peerCard { return .peer(machineId: peerCard.machineId, cardId: peerCard.cardId) }
        if let machine { return .machine(machine) }
        return .local
    }
}

/// What a paste into a card's terminal does.
public enum TerminalPastePlan: Equatable, Sendable {
    /// A bracketed paste of the clipboard's text (empty when it has none:
    /// the assistant then looks for an image on the clipboard of its own
    /// machine).
    case text
    /// The image goes to the machine of `route` as a file, and the paste
    /// types the path of that file.
    case upload(TerminalImageRoute)

    /// Text on the clipboard wins over an image. An image alone is
    /// uploaded when the assistant runs somewhere else, since the clipboard
    /// it would read is not this Mac's.
    public static func plan(hasText: Bool, hasImage: Bool, route: TerminalImageRoute) -> TerminalPastePlan {
        guard !hasText, hasImage, route != .local else { return .text }
        return .upload(route)
    }
}

/// Images pasted into the terminal of a card from another master, kept as
/// files on the master that owns the card so the paste can type their path.
public enum PastedImages {
    /// The largest image taken.
    public static let maxBytes = 20 << 20
    /// A file older than this goes when the next one is stored.
    public static let keepFor: TimeInterval = 7 * 24 * 3600

    public static func directory(kanbanHome: String) -> String {
        (kanbanHome as NSString).appendingPathComponent("images/pasted")
    }

    /// Writes the image and returns its path. The format is read from the
    /// bytes: PNG, JPEG, GIF or WebP.
    public static func store(_ bytes: Data, kanbanHome: String, now: Date = Date()) throws -> String {
        guard !bytes.isEmpty else { throw RemoteHostError.badRequest("the body must be the image bytes") }
        guard bytes.count <= maxBytes else {
            throw RemoteHostError.badRequest("the image is \(bytes.count) bytes, over the \(maxBytes) byte limit")
        }
        guard let ext = RemotePromptImages.fileExtension(of: bytes) else {
            throw RemoteHostError.badRequest("the image is not PNG, JPEG, GIF or WebP")
        }
        let directory = directory(kanbanHome: kanbanHome)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        removeOld(in: directory, now: now)
        let name = String(UUID().uuidString.lowercased().prefix(8))
        let path = (directory as NSString).appendingPathComponent("\(name).\(ext)")
        try bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    static func removeOld(in directory: String, now: Date) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > keepFor else { continue }
            try? fm.removeItem(atPath: path)
        }
    }
}
