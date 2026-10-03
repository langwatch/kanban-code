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
        unseal: VaultUnsealChallenge? = nil
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

    public init(resolution: String, by: String? = nil, unsealed: VaultUnsealed? = nil) {
        self.resolution = resolution
        self.by = by
        self.unsealed = unsealed
    }
}

/// Body of `GET /v1/attention`.
public struct AttentionListResponse: Codable, Sendable, Equatable {
    public var requests: [AttentionRequest]

    public init(requests: [AttentionRequest]) {
        self.requests = requests
    }
}
