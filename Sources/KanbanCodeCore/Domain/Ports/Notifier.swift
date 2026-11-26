import Foundation

/// Port for sending notifications to the user.
public protocol NotifierPort: Sendable {
    /// Send a notification with optional image attachment and card ID for click handling.
    func sendNotification(title: String, message: String, imageData: Data?, cardId: String?) async throws

    /// Check if this notifier is configured and ready.
    func isConfigured() -> Bool
}

public enum NotificationError: Error, LocalizedError {
    case apnsFailed
    case pushoverFailed
    case macOSNotificationFailed

    public var errorDescription: String? {
        switch self {
        case .apnsFailed: "No iPhone took the push"
        case .pushoverFailed: "Pushover refused the message"
        case .macOSNotificationFailed: "macOS notification failed"
        }
    }
}
