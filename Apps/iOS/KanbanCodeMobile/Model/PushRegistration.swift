import Foundation
import KanbanCodeRemoteKit
import UIKit
import UserNotifications

extension Notification.Name {
    /// Opens a card; `object` is the card id. Posted when a push is tapped.
    static let openCard = Notification.Name("openCard")
}

/// Asks for notification permission, registers for APNs and hands the device
/// token to every paired master (`PUT /v1/me/push`), which then pushes its
/// attention requests straight to this phone. Tapping one opens its card; a
/// silent push takes a resolved request's notification away.
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // UI tests pair through the launch environment and would stop at the
        // permission alert; KANBANCODE_PUSH=1 turns it back on for them.
        let env = ProcessInfo.processInfo.environment
        guard env["KANBANCODE_PAIR_LINK"] == nil || env["KANBANCODE_PUSH"] == "1" else { return true }
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistry.shared.token = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("Kanban Code: APNs registration failed: \(error.localizedDescription)")
    }

    /// The silent push of a resolved request.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        guard let id = PushPayload(userInfo).withdraw else { return .noData }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        return .newData
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let payload = PushPayload(response.notification.request.content.userInfo)
        await MainActor.run {
            if let card = payload.card {
                NotificationCenter.default.post(name: .openCard, object: card)
            } else if let attention = payload.attention {
                NotificationCenter.default.post(name: .openAttention, object: attention)
            }
        }
    }
}

/// What a Kanban Code push carries under its `kanbancode` key.
struct PushPayload {
    var attention: String?
    var card: String?
    var machine: String?
    var withdraw: String?

    init(_ userInfo: [AnyHashable: Any]) {
        let info = userInfo["kanbancode"] as? [String: Any] ?? [:]
        attention = info["attention"] as? String
        card = info["card"] as? String
        machine = info["machine"] as? String
        withdraw = info["withdraw"] as? String
    }
}

/// The APNs token of this install, sent to each paired master once per
/// token and master.
@MainActor
final class PushRegistry {
    static let shared = PushRegistry()

    var token: String? {
        didSet { if token != oldValue { sync() } }
    }
    private(set) var store: ServerStore?
    private var registered: Set<String> = []

    func attach(_ store: ServerStore) {
        self.store = store
        sync()
    }

    /// Registers the token with every master that does not have it yet.
    func sync() {
        guard let token, let store else { return }
        let registration = RemotePushRegistration(token: token, environment: Self.environment, bundleId: Self.bundleId)
        for server in store.servers {
            let key = "\(server.baseURL.absoluteString)|\(token)"
            guard !registered.contains(key), let client = ServerStore.client(for: server) else { continue }
            registered.insert(key)
            Task {
                do {
                    guard (try? await client.health())?.supports(RemoteAPI.Feature.push) == true else { return }
                    try await client.registerPush(registration)
                } catch {
                    _ = await MainActor.run { self.registered.remove(key) }
                    NSLog("Kanban Code: push registration with \(server.name) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Sends the token to every master again: a master paired again holds a
    /// new device record that has no token yet.
    func resync() {
        registered = []
        sync()
    }

    static var bundleId: String { Bundle.main.bundleIdentifier ?? "io.kanbancode.mobile" }

    /// Xcode installs carry a development profile and talk to the APNs
    /// sandbox; TestFlight and App Store builds carry no profile and use
    /// production.
    static let environment: RemotePushRegistration.Environment = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return .production }
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "<key>aps-environment</key>") else { return .production }
        return text[range.upperBound...].prefix(80).contains("development") ? .sandbox : .production
    }()
}
