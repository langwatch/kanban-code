import Foundation
import KanbanCodeRemoteKit
#if canImport(UserNotifications)
import UserNotifications

/// Attention notifications in the macOS notification center. Each request
/// gets a category whose actions are its options, so a question can be
/// answered from the banner; clicking it opens the card and the request's
/// detail sheet.
public actor MacAttentionNotificationClient: MacAttentionNotifier {
    /// userInfo keys of an attention notification.
    public static let requestIdKey = "attentionId"
    public static let optionPrefix = "attention-option-"
    public static let categoryPrefix = "attention-"

    private var categories: [String: UNNotificationCategory] = [:]

    public init() {}

    public func post(_ request: AttentionRequest, cardName: String?) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            KanbanCodeLog.warn("attention", "Mac notification for \(request.id) not posted: Kanban Code may not notify (authorization=\(settings.authorizationStatus.rawValue))")
            return
        }
        if let problem = Self.deliveryProblem(settings) {
            KanbanCodeLog.warn("attention", "Mac notification for \(request.id) may go unseen: \(problem)")
        }
        let categoryId = Self.categoryPrefix + request.id
        let actions = request.options.prefix(10).enumerated().map { index, option in
            UNNotificationAction(
                identifier: Self.optionPrefix + String(index), title: option,
                options: AttentionAnswerGate.need(for: request, option: option) == .nothing ? [] : [.authenticationRequired])
        }
        categories[categoryId] = UNNotificationCategory(
            identifier: categoryId, actions: Array(actions), intentIdentifiers: [], options: [])
        center.setNotificationCategories(Set(categories.values))

        let content = UNMutableNotificationContent()
        let copy = AttentionCopy.notification(for: request, cardName: cardName)
        content.title = copy.title
        content.body = copy.body.isEmpty ? Self.kindLine(request.kind) : copy.body
        content.sound = .default
        content.categoryIdentifier = categoryId
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = request.cardId ?? "attention"
        var info: [String: String] = [Self.requestIdKey: request.id]
        if let cardId = request.cardId { info["cardId"] = cardId }
        content.userInfo = info
        do {
            try await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
            KanbanCodeLog.info("attention", "Mac notification posted for \(request.id)")
        } catch {
            KanbanCodeLog.warn("attention", "Mac notification failed for \(request.id): \(error)")
        }
    }

    public func remove(id: String) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
        if categories.removeValue(forKey: Self.categoryPrefix + id) != nil {
            center.setNotificationCategories(Set(categories.values))
        }
    }

    /// What in this Mac's notification settings can make an attention
    /// notification go unseen, or nil when it stays on screen.
    public static func deliveryProblem() async -> String? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return deliveryProblem(await UNUserNotificationCenter.current().notificationSettings())
    }

    static func deliveryProblem(_ settings: UNNotificationSettings) -> String? {
        switch settings.authorizationStatus {
        case .authorized, .provisional: break
        case .notDetermined: return "Kanban Code has not asked to send notifications yet"
        default: return "notifications for Kanban Code are off in System Settings"
        }
        switch settings.alertStyle {
        case .none: return "they show no banner, only in Notification Center"
        case .banner: return "they are temporary banners that close after 5 seconds"
        default: return nil
        }
    }

    static func kindLine(_ kind: AttentionRequest.Kind) -> String {
        switch kind {
        case .question: "Waiting for your answer"
        case .planApproval: "Plan waiting for your approval"
        case .permission: "Waiting for your permission"
        case .vaultApproval: "A secret is waiting for your approval"
        }
    }
}
#endif
