#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

/// The alert parts of an APNs payload, for the tests.
struct APNsPayloadReader {
    let aps: [String: Any]
    let info: [String: Any]

    init(_ push: APNsPush) throws {
        let json = try #require(try JSONSerialization.jsonObject(with: push.payload) as? [String: Any])
        aps = json["aps"] as? [String: Any] ?? [:]
        info = json[APNsPush.Key.root] as? [String: Any] ?? [:]
    }

    var alert: [String: Any] { aps["alert"] as? [String: Any] ?? [:] }
    var title: String { alert["title"] as? String ?? "" }
    var body: String { alert["body"] as? String ?? "" }
}

@Suite("APNs push")
struct APNsPushTests {
    let token = String(repeating: "ab", count: 32)

    @Test("an attention alert carries the request, its card and machine; the passive copy shares its collapse id")
    func alertPayload() throws {
        let r = AttentionRequest(id: "att_1", cardId: "card_9", kind: .question, title: "DB", body: "Which?",
                                 options: ["A", "B"], machineId: "machine_mac")
        let passive = APNsPush.alert(for: r, cardName: "Card", level: .passive)
        let p = try APNsPayloadReader(passive)
        #expect(p.title == "Card is asking you a question")
        #expect(p.body.hasPrefix("DB: Which?"))
        #expect(p.body.contains("1. A\n2. B"))
        #expect(p.aps["interruption-level"] as? String == "passive")
        #expect(p.aps["sound"] == nil)
        #expect(p.aps["thread-id"] as? String == "card_9")
        #expect(p.info["attention"] as? String == "att_1")
        #expect(p.info["card"] as? String == "card_9")
        #expect(p.info["machine"] as? String == "machine_mac")
        #expect(passive.priority == 5)
        #expect(passive.type == .alert)

        let alert = APNsPush.alert(for: r, cardName: nil, level: .timeSensitive)
        let a = try APNsPayloadReader(alert)
        #expect(a.aps["interruption-level"] as? String == "time-sensitive")
        #expect(a.aps["sound"] as? String == "default")
        #expect(alert.priority == 10)
        #expect(alert.collapseId == passive.collapseId)
        #expect(alert.collapseId == "att_1")
    }

    @Test("a long body is cut so the payload stays under 4 KB")
    func longBody() throws {
        let r = AttentionRequest(id: "att_2", cardId: nil, kind: .question, title: "T", body: String(repeating: "x", count: 5000))
        let push = APNsPush.alert(for: r, cardName: nil, level: .timeSensitive)
        #expect(push.payload.count < 4096)
        #expect(try APNsPayloadReader(push).aps["thread-id"] as? String == "attention")
    }

    @Test("withdrawing a request is a silent background push naming it")
    func withdraw() throws {
        let r = AttentionRequest(id: "att_3", cardId: "c", kind: .permission, title: "T", body: "B")
        let push = APNsPush.withdraw(r)
        let w = try APNsPayloadReader(push)
        #expect(w.aps["content-available"] as? Int == 1)
        #expect(w.aps["alert"] == nil)
        #expect(w.info["withdraw"] as? String == "att_3")
        #expect(push.type == .background)
        #expect(push.priority == 5)
    }

    @Test("the provider token is an ES256 JWT the key's public half verifies, reused for 40 minutes")
    func providerToken() throws {
        let key = P256.Signing.PrivateKey()
        let apns = APNsKey(keyId: "ABC123DEFG", teamId: "TEAM123456", key: key.pemRepresentation)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let jwt = try APNsProviderToken.sign(key: apns, issuedAt: t0)
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        func decode(_ s: String) -> Data {
            var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b)!
        }
        let header = try #require(try JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: Any])
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "ABC123DEFG")
        let claims = try #require(try JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any])
        #expect(claims["iss"] as? String == "TEAM123456")
        #expect(claims["iat"] as? Int == 1_800_000_000)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))

        let provider = APNsProviderToken(key: apns)
        let first = try provider.token(now: t0)
        #expect(try provider.token(now: t0.addingTimeInterval(39 * 60)) == first)
        #expect(try provider.token(now: t0.addingTimeInterval(41 * 60)) != first)
    }

    @Test("APNs answers: 200 delivered, dead tokens gone, throttling and server errors retried")
    func outcomes() {
        #expect(APNsAttentionSender.outcome(status: 200, reason: nil) == .delivered)
        #expect(APNsAttentionSender.outcome(status: 410, reason: "Unregistered") == .gone)
        #expect(APNsAttentionSender.outcome(status: 400, reason: "BadDeviceToken") == .gone)
        #expect(APNsAttentionSender.outcome(status: 400, reason: "BadTopic") == .refused)
        #expect(APNsAttentionSender.outcome(status: 429, reason: "TooManyRequests") == .retry)
        #expect(APNsAttentionSender.outcome(status: 503, reason: nil) == .retry)
        #expect(APNsAttentionSender.outcome(status: 403, reason: "ExpiredProviderToken") == .retry)
        #expect(APNsAttentionSender.outcome(status: 403, reason: "InvalidProviderToken") == .refused)
    }

    @Test("a device's token is saved on its record, moves when another device registers it, and only phones take pushes")
    func deviceStore() throws {
        let dir = NSTemporaryDirectory() + "apns-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = RemoteDeviceStore(path: dir + "/devices.json")
        let (phone, _) = try store.add(name: "iPhone", scope: .full)
        let (again, _) = try store.add(name: "iPhone again", scope: .full)
        let (agent, _) = try store.add(name: "agent", scope: .agent)
        let registration = RemotePushRegistration(token: token, environment: .production, bundleId: "io.kanbancode.mobile")
        #expect(try store.setPush(deviceId: phone.id, registration))
        #expect(try store.setPush(deviceId: agent.id, registration))
        #expect(store.pushTargets().isEmpty)
        #expect(try store.setPush(deviceId: phone.id, registration))
        #expect(store.pushTargets().map(\.deviceId) == [phone.id])
        #expect(store.pushTargets().first?.registration.updatedAt != nil)
        // Another process reads what was written.
        #expect(RemoteDeviceStore(path: store.path).pushTargets().map(\.deviceName) == ["iPhone"])

        #expect(try store.setPush(deviceId: again.id, registration))
        #expect(store.pushTargets().map(\.deviceId) == [again.id])
        try store.clearPush(deviceId: again.id, token: "other")
        #expect(store.pushTargets().count == 1)
        try store.clearPush(deviceId: again.id, token: token)
        #expect(store.pushTargets().isEmpty)
        #expect(try store.setPush(deviceId: "gone", registration) == false)
    }

    @Test("PUT and DELETE /v1/me/push register the phone's token; other scopes are refused")
    func route() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let body = try JSONEncoder.remote.encode(RemotePushRegistration(token: token, environment: .sandbox, bundleId: "io.kanbancode.mobile"))
        let (saved, _) = try await f.request("PUT", "/v1/me/push", token: f.fullToken, body: body)
        #expect(saved == 204)
        #expect(f.devices.pushTargets().map(\.deviceId) == [f.fullDevice.id])
        #expect(f.devices.pushTargets().first?.registration.environment == .sandbox)

        let (agent, _) = try await f.request("PUT", "/v1/me/push", token: f.agentToken, body: body)
        #expect(agent == 403)
        let bad = Data(#"{"token":"zz","environment":"production","bundleId":"io.kanbancode.mobile"}"#.utf8)
        let (refused, _) = try await f.request("PUT", "/v1/me/push", token: f.fullToken, body: bad)
        #expect(refused == 400)
        let (wrongMethod, _) = try await f.request("POST", "/v1/me/push", token: f.fullToken, body: body)
        #expect(wrongMethod == 405)

        let (removed, _) = try await f.request("DELETE", "/v1/me/push", token: f.fullToken)
        #expect(removed == 204)
        #expect(f.devices.pushTargets().isEmpty)

        let (_, healthData) = try await f.request("GET", "/v1/health")
        #expect(try JSONDecoder.remote.decode(RemoteHealth.self, from: healthData).supports(RemoteAPI.Feature.push))
    }

    @Test("the sender posts to every registered phone with the APNs headers and forgets a dead token")
    func sends() async throws {
        let dir = NSTemporaryDirectory() + "apns-send-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = RemoteDeviceStore(path: dir + "/devices.json")
        let (live, _) = try store.add(name: "live", scope: .full)
        let (dead, _) = try store.add(name: "dead", scope: .full)
        let deadToken = String(repeating: "cd", count: 32)
        try store.setPush(deviceId: live.id, RemotePushRegistration(token: token, environment: .production, bundleId: "io.kanbancode.mobile"))
        try store.setPush(deviceId: dead.id, RemotePushRegistration(token: deadToken, environment: .sandbox, bundleId: "io.kanbancode.mobile"))

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeAPNs.self]
        FakeAPNs.reset(dead: deadToken)
        let key = APNsKey(keyId: "KEYID12345", teamId: "TEAM123456", key: P256.Signing.PrivateKey().pemRepresentation)
        let sender = APNsAttentionSender(key: key, devices: store, session: URLSession(configuration: config),
                                         hostOverride: URL(string: "https://apns.test")!)
        let r = AttentionRequest(id: "att_9", cardId: "card_1", kind: .question, title: "Q", body: "B")
        try await sender.send(r, cardName: "Card", level: .timeSensitive)

        let seen = FakeAPNs.seen()
        #expect(seen.map(\.path).sorted() == ["/3/device/\(token)", "/3/device/\(deadToken)"].sorted())
        let first = try #require(seen.first { $0.path.hasSuffix(token) })
        #expect(first.headers["apns-topic"] == "io.kanbancode.mobile")
        #expect(first.headers["apns-push-type"] == "alert")
        #expect(first.headers["apns-priority"] == "10")
        #expect(first.headers["apns-collapse-id"] == "att_9")
        #expect(first.headers["authorization"]?.hasPrefix("bearer ey") == true)
        #expect(store.pushTargets().map(\.deviceId) == [live.id])
    }
}

/// Answers APNs requests: 410 for the dead token, 200 for the rest.
final class FakeAPNs: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { var path: String; var headers: [String: String] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [Seen] = []
    nonisolated(unsafe) private static var deadToken = ""

    static func reset(dead: String) {
        lock.withLock { requests = []; deadToken = dead }
    }

    static func seen() -> [Seen] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v }
        let dead = Self.lock.withLock {
            Self.requests.append(Seen(path: path, headers: headers))
            return path.hasSuffix(Self.deadToken)
        }
        let status = dead ? 410 : 200
        let body = dead ? Data(#"{"reason":"Unregistered"}"#.utf8) : Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
