import Foundation
import UserNotifications

/// Sends notifications via macOS UNUserNotificationCenter.
/// Always available as a fallback when Pushover is not configured.
public final class MacOSNotificationClient: NotifierPort, @unchecked Sendable {

    public init() {}

    public func sendNotification(title: String, message: String, imageData: Data?, cardId: String?) async throws {
        // UNUserNotificationCenter requires a bundle identifier — unavailable under `swift run`.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()

        // Check current authorization status
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            KanbanCodeLog.info("notify", "Notification skipped: authorization=\(settings.authorizationStatus.rawValue)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        // Pass card ID for click-to-open handling
        if let cardId {
            content.userInfo = ["cardId": cardId]
        }

        // Attach rendered image (shows as thumbnail on notification)
        if let imageData {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("png")
            do {
                try imageData.write(to: tmpURL)
                let attachment = try UNNotificationAttachment(
                    identifier: "image",
                    url: tmpURL,
                    options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]
                )
                content.attachments = [attachment]
            } catch {
                KanbanCodeLog.info("notify", "Image attachment failed: \(error)")
            }
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Deliver immediately
        )

        do {
            try await center.add(request)
            KanbanCodeLog.info("notify", "macOS notification delivered: \(title)")
        } catch {
            KanbanCodeLog.info("notify", "Notification failed: \(error)")
            throw error
        }
    }

    public func isConfigured() -> Bool {
        true // Always available on macOS
    }
}
