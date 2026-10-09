import Foundation

/// Something an agent cannot go on without: a question, a plan to approve,
/// a permission prompt, or a vault release. The master holds the open ones
/// and every device shows them until one of them resolves it.
public struct AttentionRequest: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case question
        case planApproval
        case permission
        case vaultApproval
    }

    public var id: String
    public var cardId: String?
    public var kind: Kind
    public var title: String
    public var body: String
    /// The answers offered, in order. Empty when the request takes free text
    /// or is answered only in the session itself.
    public var options: [String]
    public var createdAt: Date
    /// Resolving it from a device asks for Face ID / Touch ID first.
    public var requiresBiometry: Bool
    public var resolvedAt: Date?
    /// The chosen option (or free text) once resolved.
    public var resolution: String?
    /// Who resolved it: "mac", "phone", "session" (answered in the session
    /// itself), "timeout", or a device name.
    public var resolvedBy: String?
    /// Session the request came from, when an agent session raised it.
    public var sessionId: String?
    /// Id of the master that raised it and answers it; another master shows
    /// it and forwards the resolution there.
    public var machineId: String?
    /// The full picture of a vault request, for the detail sheet.
    public var vault: VaultApprovalDetails?
    /// What the answering device does with its own key before the approval
    /// counts: unlock owner-only secrets, mint AWS credentials.
    public var unseal: VaultUnsealChallenge?
    /// What the owner wrote for the agent when refusing a vault request.
    public var resolutionNote: String?
    /// Set while the device that refused may still send a note: the
    /// refusal reaches the agent when the note arrives or at this time.
    public var noteUntil: Date?

    public init(
        id: String,
        cardId: String?,
        kind: Kind,
        title: String,
        body: String,
        options: [String] = [],
        createdAt: Date = .now,
        requiresBiometry: Bool = false,
        resolvedAt: Date? = nil,
        resolution: String? = nil,
        resolvedBy: String? = nil,
        sessionId: String? = nil,
        machineId: String? = nil,
        vault: VaultApprovalDetails? = nil,
        unseal: VaultUnsealChallenge? = nil,
        resolutionNote: String? = nil,
        noteUntil: Date? = nil
    ) {
        self.id = id
        self.cardId = cardId
        self.kind = kind
        self.title = title
        self.body = body
        self.options = options
        self.createdAt = createdAt
        self.requiresBiometry = requiresBiometry
        self.resolvedAt = resolvedAt
        self.resolution = resolution
        self.resolvedBy = resolvedBy
        self.sessionId = sessionId
        self.machineId = machineId
        self.vault = vault
        self.unseal = unseal
        self.resolutionNote = resolutionNote
        self.noteUntil = noteUntil
    }

    /// Approving needs this device's vault key (Touch ID or Face ID).
    public var needsDeviceKey: Bool { !(unseal?.isEmpty ?? true) }

    public var isOpen: Bool { resolvedAt == nil }
}

/// Body of `POST /v1/attention/{id}/resolve`.
public struct AttentionResolveRequest: Codable, Sendable, Equatable {
    public var resolution: String
    /// The device acting, e.g. "phone"; the server fills it from the token
    /// when absent.
    public var by: String?
    /// What the device unlocked with its own key for this approval.
    public var unsealed: VaultUnsealed?
    /// With a refusal of a vault request: what the owner tells the agent.
    public var note: String?
    /// With a refusal of a vault request: the device shows a note field
    /// and sends `POST /v1/attention/{id}/note` next, so the refusal waits
    /// for it, up to `DenialNote.window`.
    public var noteFollows: Bool?

    public init(resolution: String, by: String? = nil, unsealed: VaultUnsealed? = nil,
                note: String? = nil, noteFollows: Bool? = nil) {
        self.resolution = resolution
        self.by = by
        self.unsealed = unsealed
        self.note = note
        self.noteFollows = noteFollows
    }
}

/// Body of `POST /v1/attention/{id}/note`: the note for a refusal sent
/// with `noteFollows`. No note (or an empty one) releases the refusal as
/// it is. `typing` sends no note yet: the owner is writing one, and the
/// refusal waits `DenialNote.typingWindow` more.
public struct AttentionNoteRequest: Codable, Sendable, Equatable {
    public var note: String?
    public var typing: Bool?

    public init(note: String?, typing: Bool? = nil) {
        self.note = note
        self.typing = typing
    }
}

/// The optional note the owner sends the agent with a refused vault request.
public enum DenialNote {
    /// Longest note kept, in characters.
    public static let limit = 500
    /// How long a refusal sent with `noteFollows` waits for its note.
    public static let window: TimeInterval = 20
    /// How long it waits from each sign that the owner is writing the note.
    public static let typingWindow: TimeInterval = 45
    /// The longest a refusal waits for its note, from the refusal.
    public static let maximumWait: TimeInterval = 120

    /// Until when a refusal made at `deniedAt` waits, once the owner was
    /// seen writing at `now`.
    public static func typingDeadline(deniedAt: Date, now: Date = Date()) -> Date {
        min(now.addingTimeInterval(typingWindow), deniedAt.addingTimeInterval(maximumWait))
    }
    /// How far past `noteUntil` a note is still taken, for the trip from
    /// the device to the master that holds the request.
    public static let slack: TimeInterval = 3

    /// A note as it is kept and sent: one line, without control
    /// characters, trimmed and cut to `limit`. Nil when that leaves no text.
    public static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                // A line break or a tab reads as a space; the rest goes.
                if scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    scalars.append(" ")
                }
            default:
                scalars.append(scalar)
            }
        }
        let words = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let cut = String(words.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? nil : cut
    }
}

/// Body of `GET /v1/attention`.
public struct AttentionListResponse: Codable, Sendable, Equatable {
    public var requests: [AttentionRequest]

    public init(requests: [AttentionRequest]) {
        self.requests = requests
    }
}

/// The note field a device shows after a refusal: how long it stays and
/// when the device tells the master that the owner is writing.
public struct DenialNotePacer: Sendable, Equatable {
    public let deniedAt: Date
    /// When the refusal goes to the agent as it is.
    public private(set) var deadline: Date
    private var lastSign: Date?
    /// Signs go out this far apart at most.
    public static let signInterval: TimeInterval = 8

    public init(deniedAt: Date = Date()) {
        self.deniedAt = deniedAt
        self.deadline = deniedAt.addingTimeInterval(DenialNote.window)
    }

    /// The text changed: moves the deadline, and says whether to send the
    /// master a typing sign now.
    public mutating func typed(now: Date = Date()) -> Bool {
        deadline = DenialNote.typingDeadline(deniedAt: deniedAt, now: now)
        if let lastSign, now.timeIntervalSince(lastSign) < Self.signInterval { return false }
        lastSign = now
        return true
    }
}
