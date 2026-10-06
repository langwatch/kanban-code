#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The session tokens of the cards this master runs. A card session gets
/// a random token in its environment (`KANBAN_CARD_TOKEN`) when it starts
/// or resumes; a process that left the session's process tree (detached,
/// reparented to init) still carries it, and kv sends it so the master can
/// tell which card it belongs to.
///
/// Only the SHA-256 of each token is kept, in `vault/card-tokens.json`,
/// so tokens survive a restart of the master. A card keeps its last
/// `perCard` tokens: a host that is already running ignores the
/// environment of a later start, and processes started before a restart
/// still carry the earlier token. A token whose card has no live session is
/// refused and, after a grace period, removed.
public actor VaultCardTokens {
    public static let environmentName = "KANBAN_CARD_TOKEN"
    /// How long a token stays on file while its card shows no session,
    /// which covers the time a launch takes to record its session.
    public static let grace: TimeInterval = 15 * 60
    /// How many tokens of one card stay valid, the newest.
    public static let perCard = 8

    struct Entry: Codable, Sendable, Equatable {
        var hash: String
        var cardId: String
        var issuedAt: Date
    }

    public let path: String
    private var entries: [Entry]?

    public init(directory: String) {
        path = directory + "/card-tokens.json"
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func load() -> [Entry] {
        if let entries { return entries }
        let loaded = FileManager.default.contents(atPath: path)
            .flatMap { try? JSONDecoder.vault.decode([Entry].self, from: $0) } ?? []
        entries = loaded
        return loaded
    }

    private func save(_ list: [Entry]) {
        entries = list
        guard let data = try? JSONEncoder.vault.encode(list) else { return }
        try? VaultFiles.writeAtomically(data, to: path, mode: 0o600)
    }

    /// A fresh token for a card's new session. The card's earlier ones
    /// keep working up to `perCard`, the oldest dropped first.
    public func issue(cardId: String, now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let token = "kct_" + bytes.map { String(format: "%02x", $0) }.joined()
        let list = load()
        let kept = list.filter { $0.cardId == cardId }.suffix(Self.perCard - 1)
        save(list.filter { $0.cardId != cardId } + kept + [Entry(hash: Self.hash(token), cardId: cardId, issuedAt: now)])
        return token
    }

    /// The card a token belongs to, when that card still has a live
    /// session (`liveCards`). Tokens of cards without one are dropped once
    /// the grace period is over.
    public func verify(_ token: String?, liveCards: Set<String>, now: Date = Date()) -> String? {
        let list = load()
        let kept = list.filter { liveCards.contains($0.cardId) || now.timeIntervalSince($0.issuedAt) < Self.grace }
        if kept != list { save(kept) }
        guard let token, !token.isEmpty else { return nil }
        let hash = Self.hash(token)
        guard let entry = kept.first(where: { $0.hash == hash }), liveCards.contains(entry.cardId) else { return nil }
        return entry.cardId
    }

    /// The card of the token whose SHA-256 is `hash`, under the same rules:
    /// what a peer master asks for a token one of its callers carried.
    public func verify(hash: String, liveCards: Set<String>) -> String? {
        guard let entry = load().first(where: { $0.hash == hash }), liveCards.contains(entry.cardId) else { return nil }
        return entry.cardId
    }

    /// The card a token on file was issued for, whether or not that card
    /// still has a session. Nothing is removed: a check of the token a
    /// session carries, not a caller asking to be placed.
    public func issuedCard(of token: String) -> String? {
        let hash = Self.hash(token)
        return load().first { $0.hash == hash }?.cardId
    }

    public func drop(cardId: String) {
        let list = load()
        let kept = list.filter { $0.cardId != cardId }
        if kept != list { save(kept) }
    }

    public var count: Int { load().count }
}
