import Foundation

/// What a master says when an answer cannot be taken. None of it names the
/// request by its id: the human reads these.
public enum AttentionAnswerCopy {
    public static let gone = "This request is no longer open."
    public static let ownerUnreachable = "The machine that asked is not reachable."
    public static let sessionGone = "The session that asked is not running any more."
    public static let noteTooLate = "The refusal already reached the agent without a note."
    public static let needsDeviceKey = "Approving this unlocks a secret with the device's own key: answer it in Kanban Code on the Mac or the phone."

    /// "This was already answered on the phone: Approve once."
    public static func alreadyAnswered(by: String?, resolution: String?) -> String {
        let who: String = switch by {
        case "phone": " on the phone"
        case "mac": " on the Mac"
        case "session": " in the session"
        case "timeout": " by the timeout"
        case "peer", nil: ""
        case .some(let device): " on \(device)"
        }
        let what = resolution.map { ": \($0)" } ?? ""
        return "This was already answered\(who)\(what)."
    }
}

/// What a device asks of its owner before it sends an answer. Refusing
/// releases and changes no secret, so it never asks for anything; only
/// an approval can need the device key or a confirmation.
public enum AttentionAnswerGate {
    public enum Need: Sendable, Equatable {
        /// The answer goes out as it is.
        case nothing
        /// The device key opens what the request names (Touch ID or Face ID).
        case deviceKey(VaultUnsealChallenge)
        /// The owner confirms with Touch ID, Face ID or the device password.
        case confirmation
    }

    public static func need(for request: AttentionRequest, option: String) -> Need {
        if AttentionCopy.isDenial(option) { return .nothing }
        if let challenge = request.unseal, !challenge.isEmpty { return .deviceKey(challenge) }
        return request.requiresBiometry ? .confirmation : .nothing
    }

    public enum Passed: Sendable, Equatable {
        /// Send the answer, with what the device key opened.
        case send(VaultUnsealed?)
        /// The owner backed out of the confirmation.
        case cancelled
    }

    /// Runs what `need` asks for. `unlock` and `confirm` are the device's
    /// own prompts; neither is called for a refusal. An error of `unlock`
    /// is thrown on. It runs on the caller's actor, so the prompts may
    /// touch what the caller is isolated to.
    public static func pass(
        isolation: isolated (any Actor)? = #isolation,
        _ request: AttentionRequest, option: String,
        unlock: (VaultUnsealChallenge) async throws -> VaultUnsealed,
        confirm: () async -> Bool
    ) async throws -> Passed {
        switch need(for: request, option: option) {
        case .nothing: return .send(nil)
        case .deviceKey(let challenge): return .send(try await unlock(challenge))
        case .confirmation: return await confirm() ? .send(nil) : .cancelled
        }
    }
}

/// Which open requests a device shows when it follows several masters.
public enum AttentionFleet {
    /// One master's list.
    public struct Source: Sendable {
        public var machineId: String
        /// Its event stream is connected, so its list is current.
        public var isLive: Bool
        public var requests: [AttentionRequest]

        public init(machineId: String, isLive: Bool, requests: [AttentionRequest]) {
            self.machineId = machineId
            self.isLive = isLive
            self.requests = requests
        }
    }

    /// A request to show and the index of the source to answer it on.
    public struct Entry: Sendable, Equatable {
        public var request: AttentionRequest
        public var source: Int
    }

    /// The open requests across `sources`, oldest first, each once.
    ///
    /// A master lists its own requests and mirrors those of its peers, a
    /// few seconds behind. The master that raised a request is the
    /// authority: while it is live, its list decides whether the request
    /// is open, and a mirror's stale copy is not shown. `hidden` are the
    /// ones this device answered or is answering.
    public static func visible(_ sources: [Source], hidden: Set<String> = []) -> [Entry] {
        let live = Set(sources.filter(\.isLive).map(\.machineId))
        var byId: [String: Entry] = [:]
        for (index, source) in sources.enumerated() {
            for request in source.requests where request.isOpen && !hidden.contains(request.id) {
                let owner = request.machineId ?? source.machineId
                let owns = owner == source.machineId
                if !owns && live.contains(owner) { continue }
                if byId[request.id] == nil || owns {
                    byId[request.id] = Entry(request: request, source: index)
                }
            }
        }
        return byId.values.sorted {
            ($0.request.createdAt, $0.request.id) < ($1.request.createdAt, $1.request.id)
        }
    }
}

/// The answers a device is sending and has sent, so a tapped request
/// shows its progress at once, cannot be answered twice, and leaves the
/// list as soon as its master took the answer.
public struct AttentionAnswerState: Sendable, Equatable {
    /// Request id -> the option being sent.
    public private(set) var sending: [String: String] = [:]
    /// Answered from here, or found already settled: not shown again.
    public private(set) var settled: Set<String> = []
    /// Request id -> why the last answer did not go through.
    public private(set) var errors: [String: String] = [:]
    /// A short note for the list after a request turned out settled.
    public private(set) var note: String?

    public init() {}

    public func isSending(_ id: String) -> Bool { sending[id] != nil }

    /// Starts an answer. False when one is on its way or it is settled:
    /// the tap does nothing.
    public mutating func begin(_ id: String, option: String) -> Bool {
        guard sending[id] == nil, !settled.contains(id) else { return false }
        sending[id] = option
        errors[id] = nil
        note = nil
        return true
    }

    /// The human backed out before the answer was sent (Face ID refused).
    public mutating func cancelled(_ id: String) {
        sending[id] = nil
    }

    public mutating func succeeded(_ id: String) {
        sending[id] = nil
        settled.insert(id)
    }

    /// The call failed. An answer the master refuses because the request
    /// is settled already takes the row away with a note; anything else
    /// keeps the row, with the error and working buttons.
    public mutating func failed(_ id: String, error: Error) {
        sending[id] = nil
        if let remote = error as? RemoteClientError {
            switch remote {
            case .conflict(let message) where Self.saysSettled(message):
                settled.insert(id)
                note = message
                return
            case .notFound:
                settled.insert(id)
                note = AttentionAnswerCopy.gone
                return
            default:
                break
            }
        }
        errors[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func saysSettled(_ message: String) -> Bool {
        message.contains("already answered") || message.contains("already resolved") || message == AttentionAnswerCopy.gone
    }

    public mutating func clearNote() {
        note = nil
    }

    /// Forgets settled ids no master lists any more.
    public mutating func prune(listed: Set<String>) {
        settled = settled.intersection(listed)
        errors = errors.filter { listed.contains($0.key) }
    }
}
