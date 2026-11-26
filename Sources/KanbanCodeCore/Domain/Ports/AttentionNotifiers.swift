import Foundation
import KanbanCodeRemoteKit

/// Posts and removes attention notifications on this Mac.
public protocol MacAttentionNotifier: Sendable {
    func post(_ request: AttentionRequest, cardName: String?) async
    func remove(id: String) async
    /// Opens the request's detail sheet in the app, with no system
    /// notification.
    func showInApp(_ request: AttentionRequest) async
    /// How many requests are open, for the Dock badge.
    func showOpenCount(_ count: Int) async
}

extension MacAttentionNotifier {
    public func showOpenCount(_ count: Int) async {}

    public func showInApp(_ request: AttentionRequest) async {
        KanbanCodeLog.warn("attention", "\(request.id) should open in the app, but this notifier has no app to open it in")
    }
}

public enum PhonePushLevel: String, Sendable, Equatable {
    /// Lands on the phone without sound or vibration.
    case passive
    /// Alerts with sound, through Focus where allowed.
    case timeSensitive
}

/// Sends attention requests to the phone: APNs to the iPhone app, Pushover,
/// or both through `PhonePushFanout`.
public protocol PhonePushSender: Sendable {
    func send(_ request: AttentionRequest, cardName: String?, level: PhonePushLevel) async throws
    /// Clears what was sent for a resolved request, where the channel can.
    func withdraw(_ request: AttentionRequest) async
    /// The channel takes a silent copy before the alert. A channel that
    /// cannot replace or delete a message says false, so the phone gets one
    /// entry per request: the alert.
    var sendsSilentCopy: Bool { get }
}

extension PhonePushSender {
    public var sendsSilentCopy: Bool { true }
}

/// Sends every request through each phone channel that is set up (APNs and
/// Pushover), so a channel that fails or has no device does not lose it. The
/// silent copy goes only to channels that can replace it with the alert; the
/// alert and the withdraw go to all. A send fails only when every channel it
/// went to failed.
public struct PhonePushFanout: PhonePushSender {
    public let senders: [any PhonePushSender]

    public init(_ senders: [any PhonePushSender]) {
        self.senders = senders
    }

    public var sendsSilentCopy: Bool { senders.contains { $0.sendsSilentCopy } }

    public func send(_ request: AttentionRequest, cardName: String?, level: PhonePushLevel) async throws {
        let targets = senders.filter { level != .passive || $0.sendsSilentCopy }
        var lastError: (any Error)?
        var delivered = 0
        for sender in targets {
            do {
                try await sender.send(request, cardName: cardName, level: level)
                delivered += 1
            } catch {
                lastError = error
                KanbanCodeLog.warn("attention", "\(type(of: sender)) \(level.rawValue) for \(request.id) failed: \(error)")
            }
        }
        if delivered == 0, let lastError { throw lastError }
    }

    public func withdraw(_ request: AttentionRequest) async {
        for sender in senders { await sender.withdraw(request) }
    }
}
