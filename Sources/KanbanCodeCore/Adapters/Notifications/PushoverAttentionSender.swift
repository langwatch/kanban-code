import Foundation
import KanbanCodeRemoteKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends attention requests to the phone through Pushover, as one alert at
/// high priority, which iOS shows as time sensitive. Pushover cannot delete
/// or replace a delivered message, so it takes no silent copy first (that
/// would list every request twice) and a resolved request stays there.
public struct PushoverAttentionSender: PhonePushSender {
    public let token: String
    public let userKey: String
    private let apiURL = URL(string: "https://api.pushover.net/1/messages.json")!

    public var sendsSilentCopy: Bool { false }

    public init(token: String, userKey: String) {
        self.token = token
        self.userKey = userKey
    }

    public static func priority(for level: PhonePushLevel) -> Int {
        switch level {
        case .passive: -2
        case .timeSensitive: 1
        }
    }

    /// Form fields of the Pushover message for a request.
    public static func fields(for request: AttentionRequest, cardName: String?, level: PhonePushLevel) -> [(String, String)] {
        let copy = AttentionCopy.notification(for: request, cardName: cardName)
        let title = String(copy.title.prefix(250))
        var message = copy.body
        // A vault approval is answered in the app, after its details.
        if !request.options.isEmpty && request.kind != .vaultApproval {
            message += "\n\n" + request.options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { message = request.title }
        if message.count > 1000 { message = String(message.prefix(1000)) + "..." }
        var fields: [(String, String)] = [
            ("title", title),
            ("message", message),
            ("priority", String(priority(for: level))),
            ("url", "kanbancode://attention/\(request.id)"),
            ("url_title", "Answer in Kanban Code"),
            ("timestamp", String(Int(request.createdAt.timeIntervalSince1970))),
        ]
        if level == .passive { fields.append(("sound", "none")) }
        return fields
    }

    public func send(_ request: AttentionRequest, cardName: String?, level: PhonePushLevel) async throws {
        var body = URLComponents()
        body.queryItems = ([("token", token), ("user", userKey)] + Self.fields(for: request, cardName: cardName, level: level))
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        var urlRequest = URLRequest(url: apiURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encoded = (body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        urlRequest.httpBody = Data(encoded.utf8)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            KanbanCodeLog.warn("attention", "Pushover refused \(request.id): HTTP \(status) \(detail.prefix(300))")
            throw NotificationError.pushoverFailed
        }
        KanbanCodeLog.info("attention", "Pushover \(level.rawValue) sent for \(request.id): HTTP \(status) request=\(Self.requestId(data) ?? "?")")
    }

    /// The `request` id Pushover answers with, to look a message up later.
    static func requestId(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["request"] as? String
    }

    public func withdraw(_ request: AttentionRequest) async {}
}
