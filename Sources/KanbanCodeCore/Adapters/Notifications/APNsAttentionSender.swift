#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import KanbanCodeRemoteKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization

/// The APNs auth key a master signs its pushes with: the .p8 key of the
/// Apple team, its key id and the team id. One key serves every app of the
/// team, sandbox and production.
public struct APNsKey: Codable, Sendable, Equatable {
    public var keyId: String
    public var teamId: String
    /// The .p8 file's text (PKCS#8 PEM).
    public var key: String
    /// The app's bundle id, the `apns-topic` of every push.
    public var topic: String

    public static let defaultTopic = "io.kanbancode.mobile"

    public init(keyId: String, teamId: String, key: String, topic: String = APNsKey.defaultTopic) {
        self.keyId = keyId
        self.teamId = teamId
        self.key = key
        self.topic = topic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyId = try c.decode(String.self, forKey: .keyId)
        teamId = try c.decode(String.self, forKey: .teamId)
        key = try c.decode(String.self, forKey: .key)
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? Self.defaultTopic
    }

    public var isComplete: Bool {
        !keyId.isEmpty && !teamId.isEmpty && key.contains("PRIVATE KEY")
    }
}

/// Signs the ES256 provider token APNs takes as `authorization: bearer`.
/// APNs refuses a token older than an hour and throttles one renewed more
/// than every 20 minutes, so a token is reused for 40 minutes.
public final class APNsProviderToken: Sendable {
    private let key: APNsKey
    private let cached = Mutex<(token: String, issuedAt: Date)?>(nil)
    static let lifetime: TimeInterval = 40 * 60

    public init(key: APNsKey) {
        self.key = key
    }

    public func token(now: Date = Date()) throws -> String {
        try cached.withLock { cached in
            if let c = cached, now.timeIntervalSince(c.issuedAt) < Self.lifetime { return c.token }
            let token = try Self.sign(key: key, issuedAt: now)
            cached = (token, now)
            return token
        }
    }

    public func reset() {
        cached.withLock { $0 = nil }
    }

    public static func sign(key: APNsKey, issuedAt: Date) throws -> String {
        let privateKey = try P256.Signing.PrivateKey(pemRepresentation: key.key)
        let header = base64URL(Data(#"{"alg":"ES256","kid":"\#(key.keyId)"}"#.utf8))
        let claims = base64URL(Data(#"{"iss":"\#(key.teamId)","iat":\#(Int(issuedAt.timeIntervalSince1970))}"#.utf8))
        let input = "\(header).\(claims)"
        let signature = try privateKey.signature(for: Data(input.utf8))
        return "\(input).\(base64URL(signature.rawRepresentation))"
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One push to send: its JSON body and the APNs headers that go with it.
public struct APNsPush: Sendable, Equatable {
    public enum PushType: String, Sendable { case alert, background }
    public var payload: Data
    public var type: PushType
    /// 10 delivers at once, 5 when the phone sees fit (required for background).
    public var priority: Int
    /// A later push with the same id replaces the shown notification, and the
    /// notification's request identifier on the phone is this id.
    public var collapseId: String?

    /// What the iOS app reads under the `kanbancode` key of a push.
    public enum Key {
        public static let root = "kanbancode"
        public static let attention = "attention"
        public static let card = "card"
        public static let machine = "machine"
        public static let withdraw = "withdraw"
    }

    /// The alert of an attention request. The passive copy lands silently;
    /// the time sensitive alert carries the same collapse id, so it takes the
    /// copy's place instead of listing the request twice.
    public static func alert(for request: AttentionRequest, cardName: String?, level: PhonePushLevel) -> APNsPush {
        let copy = AttentionCopy.notification(for: request, cardName: cardName)
        var body = copy.body
        // A vault approval is answered in the app, after its details.
        if !request.options.isEmpty && request.kind != .vaultApproval {
            body += "\n\n" + request.options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body = request.title }
        // APNs takes 4 KB of payload; the alert never needs more than this.
        if body.count > 1000 { body = String(body.prefix(1000)) + "..." }
        var aps: [String: Any] = [
            "alert": ["title": String(copy.title.prefix(250)), "body": body],
            "thread-id": request.cardId ?? "attention",
            "interruption-level": level == .timeSensitive ? "time-sensitive" : "passive",
        ]
        if level == .timeSensitive { aps["sound"] = "default" }
        var info: [String: Any] = [Key.attention: request.id]
        if let card = request.cardId { info[Key.card] = card }
        if let machine = request.machineId { info[Key.machine] = machine }
        let payload = (try? JSONSerialization.data(withJSONObject: ["aps": aps, Key.root: info], options: [.sortedKeys])) ?? Data()
        return APNsPush(payload: payload, type: .alert, priority: level == .timeSensitive ? 10 : 5,
                        collapseId: String(request.id.prefix(64)))
    }

    /// A silent push that has the app take a resolved request's notification away.
    public static func withdraw(_ request: AttentionRequest) -> APNsPush {
        let body: [String: Any] = ["aps": ["content-available": 1], Key.root: [Key.withdraw: request.id]]
        let payload = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return APNsPush(payload: payload, type: .background, priority: 5, collapseId: nil)
    }
}

/// Sends attention requests straight to the iOS app through APNs, to every
/// device that registered a token with this master (`PUT /v1/me/push`).
public struct APNsAttentionSender: PhonePushSender {
    public let key: APNsKey
    public let devices: RemoteDeviceStore
    private let provider: APNsProviderToken
    private let session: URLSession
    /// Replaces Apple's gateways, for tests.
    private let hostOverride: URL?

    public init(key: APNsKey, devices: RemoteDeviceStore, session: URLSession = .shared, hostOverride: URL? = nil) {
        self.key = key
        self.devices = devices
        self.provider = APNsProviderToken(key: key)
        self.session = session
        self.hostOverride = hostOverride
    }

    public static func host(for environment: RemotePushRegistration.Environment) -> URL {
        switch environment {
        case .production: URL(string: "https://api.push.apple.com")!
        case .sandbox: URL(string: "https://api.sandbox.push.apple.com")!
        }
    }

    public func send(_ request: AttentionRequest, cardName: String?, level: PhonePushLevel) async throws {
        let targets = devices.pushTargets()
        guard !targets.isEmpty else {
            KanbanCodeLog.warn("attention", "APNs \(level.rawValue) for \(request.id) not sent: no iPhone registered for push")
            return
        }
        let push = APNsPush.alert(for: request, cardName: cardName, level: level)
        var delivered = 0
        for target in targets where await deliver(push, to: target, what: "\(level.rawValue) \(request.id)") {
            delivered += 1
        }
        if delivered == 0 { throw NotificationError.apnsFailed }
    }

    public func withdraw(_ request: AttentionRequest) async {
        let push = APNsPush.withdraw(request)
        for target in devices.pushTargets() {
            _ = await deliver(push, to: target, what: "withdraw \(request.id)")
        }
    }

    /// Sends one push to one device. A token APNs calls dead is forgotten.
    @discardableResult
    func deliver(_ push: APNsPush, to target: RemoteDeviceStore.PushTarget, what: String) async -> Bool {
        let registration = target.registration
        guard registration.bundleId == key.topic else {
            KanbanCodeLog.warn("attention", "APNs \(what): \(target.deviceName) registered \(registration.bundleId), this key sends to \(key.topic)")
            return false
        }
        for attempt in 0..<2 {
            do {
                let base = hostOverride ?? Self.host(for: registration.environment)
                var urlRequest = URLRequest(url: base.appendingPathComponent("3/device/\(registration.token)"))
                urlRequest.httpMethod = "POST"
                urlRequest.httpBody = push.payload
                urlRequest.setValue("bearer \(try provider.token())", forHTTPHeaderField: "authorization")
                urlRequest.setValue(key.topic, forHTTPHeaderField: "apns-topic")
                urlRequest.setValue(push.type.rawValue, forHTTPHeaderField: "apns-push-type")
                urlRequest.setValue(String(push.priority), forHTTPHeaderField: "apns-priority")
                if let collapse = push.collapseId { urlRequest.setValue(collapse, forHTTPHeaderField: "apns-collapse-id") }
                urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
                let (data, response) = try await session.data(for: urlRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let reason = Self.reason(data)
                switch Self.outcome(status: status, reason: reason) {
                case .delivered:
                    KanbanCodeLog.info("attention", "APNs \(what) sent to \(target.deviceName) (\(registration.environment.rawValue))")
                    return true
                case .gone:
                    KanbanCodeLog.warn("attention", "APNs \(what): \(target.deviceName)'s token is dead (\(status) \(reason ?? "")), forgetting it")
                    try? devices.clearPush(deviceId: target.deviceId, token: registration.token)
                    return false
                case .retry where attempt == 0:
                    if reason == "ExpiredProviderToken" { provider.reset() }
                    try? await Task.sleep(for: .seconds(1))
                    continue
                case .retry, .refused:
                    KanbanCodeLog.warn("attention", "APNs \(what) refused for \(target.deviceName): HTTP \(status) \(reason ?? "")")
                    return false
                }
            } catch {
                KanbanCodeLog.warn("attention", "APNs \(what) to \(target.deviceName) failed: \(error)")
                if attempt == 0 { continue }
            }
        }
        return false
    }

    public enum Outcome: Equatable { case delivered, gone, retry, refused }

    /// 200 is delivered. 410 Unregistered and 400 BadDeviceToken mean the
    /// token is dead. 429, 500, 503 and a provider token that just expired
    /// are worth one more try.
    public static func outcome(status: Int, reason: String?) -> Outcome {
        if status == 200 { return .delivered }
        if status == 410 || (status == 400 && reason == "BadDeviceToken") { return .gone }
        if status == 429 || status >= 500 || (status == 403 && reason == "ExpiredProviderToken") { return .retry }
        return .refused
    }

    static func reason(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
    }
}
