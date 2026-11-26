import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit
import Testing

@testable import KanbanCodeCore

@Suite("Attention remote API")
struct AttentionAPITests {
    static let question = AttentionRequest(
        id: "att_toolu_1", cardId: "card_live", kind: .question, title: "DB", body: "Which database?",
        options: ["Postgres", "SQLite"], createdAt: Date(timeIntervalSince1970: 1_800_000_000))

    @Test("GET /v1/attention lists the open requests")
    func list() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        f.host.raise(Self.question)
        let (status, data) = try await f.request("GET", "/v1/attention", token: f.fullToken)
        #expect(status == 200)
        let list = try JSONDecoder.remote.decode(AttentionListResponse.self, from: data)
        #expect(list.requests == [Self.question])
    }

    @Test("resolving answers through the host, named after the device")
    func resolve() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        f.host.raise(Self.question)
        let body = try JSONEncoder.remote.encode(AttentionResolveRequest(resolution: "SQLite"))
        let (status, _) = try await f.request("POST", "/v1/attention/att_toolu_1/resolve", token: f.fullToken, body: body)
        #expect(status == 204)
        let resolutions = f.host.state.withLock { $0.resolutions }
        #expect(resolutions.map(\.resolution) == ["SQLite"])
        #expect(resolutions.map(\.by) == ["iPhone"])
    }

    @Test("an agent token cannot answer a request")
    func agentRefused() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        f.host.raise(Self.question)
        let body = try JSONEncoder.remote.encode(AttentionResolveRequest(resolution: "SQLite"))
        let (status, _) = try await f.request("POST", "/v1/attention/att_toolu_1/resolve", token: f.agentToken, body: body)
        #expect(status == 403)
        #expect(f.host.state.withLock { $0.resolutions }.isEmpty)
    }

    @Test("an unknown request is 404 and an empty answer is 400")
    func badRequests() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let ok = try JSONEncoder.remote.encode(AttentionResolveRequest(resolution: "x"))
        let (missing, _) = try await f.request("POST", "/v1/attention/nope/resolve", token: f.fullToken, body: ok)
        #expect(missing == 404)
        let empty = try JSONEncoder.remote.encode(AttentionResolveRequest(resolution: "  "))
        let (bad, _) = try await f.request("POST", "/v1/attention/nope/resolve", token: f.fullToken, body: empty)
        #expect(bad == 400)
    }

    @Test("presence reaches the host")
    func presence() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let body = try JSONEncoder.remote.encode(MacPresence(isKanbanFrontmost: true, idleSeconds: 3))
        let (status, _) = try await f.request("POST", "/v1/attention/presence", token: f.fullToken, body: body)
        #expect(status == 204)
        #expect(f.host.state.withLock { $0.presences }.first?.isKanbanFrontmost == true)
    }

    @Test("the events stream carries the open list on connect and on change")
    func events() async throws {
        let f = try await RemoteServerFixture()
        defer { f.shutdown() }
        let ws = f.webSocket("/v1/events", token: f.fullToken)
        defer { ws.cancel(with: .goingAway, reason: nil) }
        let first = try decodeEvent(try await withTimeout(5) { try await ws.receive() })
        #expect(first.type == .board)
        #expect(first.attention == [])
        f.host.raise(Self.question)
        var next: RemoteEvent?
        for _ in 0..<6 {
            let e = try decodeEvent(try await withTimeout(5) { try await ws.receive() })
            if e.attention != nil { next = e; break }
        }
        #expect(next?.type == .cards)
        #expect(next?.attention?.map(\.id) == ["att_toolu_1"])
    }
}

@Suite("Attention in the master engine")
struct AttentionEngineTests {
    @Test("tmux keys pick the option by number; plans and permissions approve with 1, refuse with Escape")
    func tmuxKeys() {
        let q = AttentionRequest(id: "a", cardId: nil, kind: .question, title: "", body: "", options: ["A", "B"])
        #expect(MasterEngine.tmuxKeys(for: q, resolution: "B", optionIndex: 1) == ["2"])
        #expect(MasterEngine.tmuxKeys(for: q, resolution: "free text", optionIndex: nil).isEmpty)
        let plan = AttentionRequest(id: "p", cardId: nil, kind: .planApproval, title: "", body: "", options: AttentionDetector.planOptions)
        #expect(MasterEngine.tmuxKeys(for: plan, resolution: AttentionDetector.planOptions[0], optionIndex: 0) == ["1"])
        #expect(MasterEngine.tmuxKeys(for: plan, resolution: AttentionDetector.planOptions[1], optionIndex: 1) == ["Escape"])
        let perm = AttentionRequest(id: "x", cardId: nil, kind: .permission, title: "", body: "", options: AttentionDetector.permissionOptions)
        #expect(MasterEngine.tmuxKeys(for: perm, resolution: "Deny", optionIndex: 1) == ["Escape"])
    }

    @Test("rush answers: a question takes the text, a plan or permission allows by its first option and denies otherwise")
    func rushAnswer() {
        let q = AttentionRequest(id: "att_toolu_1", cardId: nil, kind: .question, title: "", body: "", options: ["Tea", "Coffee"])
        let answer = MasterEngine.rushAnswer(for: q, resolution: "Coffee", optionIndex: 1)
        #expect(answer.text == "Coffee" && !answer.deny && answer.toolUseId == "toolu_1")
        let plan = AttentionRequest(id: "att_toolu_2", cardId: nil, kind: .planApproval, title: "", body: "", options: AttentionDetector.planOptions)
        let approve = MasterEngine.rushAnswer(for: plan, resolution: AttentionDetector.planOptions[0], optionIndex: 0)
        #expect(!approve.deny && approve.text.isEmpty)
        let keep = MasterEngine.rushAnswer(for: plan, resolution: AttentionDetector.planOptions[1], optionIndex: 1)
        #expect(keep.deny && keep.text.isEmpty)
        let feedback = MasterEngine.rushAnswer(for: plan, resolution: "split step 2", optionIndex: nil)
        #expect(feedback.deny && feedback.text == "split step 2")
        let perm = AttentionRequest(id: "perm_abc_1", cardId: nil, kind: .permission, title: "", body: "", options: AttentionDetector.permissionOptions)
        let deny = MasterEngine.rushAnswer(for: perm, resolution: "Deny", optionIndex: 1)
        #expect(deny.deny && deny.toolUseId == nil)
    }

    @Test("a rush session blocked on a tool call is a permission; questions and plans are not")
    func rushPermissionNeed() throws {
        #expect(MasterEngine.rushPermissionNeed("Bash rm -rf build") == "Bash rm -rf build")
        #expect(MasterEngine.rushPermissionNeed("asks: Tea or coffee?") == nil)
        #expect(MasterEngine.rushPermissionNeed("ExitPlanMode ") == nil)
        #expect(MasterEngine.isQuestionOrPlan("Claude needs your permission to use AskUserQuestion"))
        #expect(!MasterEngine.isQuestionOrPlan("Claude needs your permission to use Bash"))
        let json = #"{"id":"084cff00","sessionId":"s","cwd":"/p","state":"blocked","alive":true,"queue":[],"needs":"Bash ls"}"#
        let info = try JSONDecoder().decode(RushSessionInfo.self, from: Data(json.utf8))
        #expect(info.blockedOn == "Bash ls")
        let idle = try JSONDecoder().decode(RushSessionInfo.self, from: Data(json.replacingOccurrences(of: "blocked", with: "idle").utf8))
        #expect(idle.blockedOn == nil)
    }

    @Test("Notification hook lines carry their type and text")
    func hookPayload() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let payload = #"{"session_id":"s1","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use \"Bash\""}"#
        let b64 = Data(payload.utf8).base64EncodedString()
        let line = #"{"sessionId":"s1","event":"Notification","timestamp":"2026-10-02T10:00:00Z","transcriptPath":"/t","payloadB64":"\#(b64)"}"#
        try (line + "\n").write(toFile: dir + "/hook-events.jsonl", atomically: true, encoding: .utf8)
        let events = try await HookEventStore(basePath: dir).readNewEvents()
        #expect(events.first?.notificationType == "permission_prompt")
        #expect(events.first?.message == #"Claude needs your permission to use "Bash""#)
        #expect(BackgroundOrchestrator.needsDecision(notificationType: events.first?.notificationType))
        #expect(!BackgroundOrchestrator.needsDecision(notificationType: "idle_prompt"))
    }

    @Test("the pending tool call names a permission request")
    func pendingTool() {
        let use = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rm -rf build"}}]}}"#
        #expect(AttentionDetector.pendingToolCall(inLines: [use])?.text == "Bash: rm -rf build")
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}"#
        #expect(AttentionDetector.pendingToolCall(inLines: [use, result]) == nil)
    }

    @Test("settings: old Pushover keys still decode and push; APNs adds the iPhone app next to it")
    func settings() throws {
        let devices = RemoteDeviceStore(path: "/nonexistent")
        let legacy = #"{"pushoverMode":"whenLidClosed","pushoverToken":"t","pushoverUserKey":"u","renderMarkdownImage":true}"#
        let decoded = try JSONDecoder().decode(NotificationSettings.self, from: Data(legacy.utf8))
        #expect(decoded.phonePush)
        #expect(decoded.macNotifications)
        #expect(decoded.pushoverMode == .enabled)
        #expect(decoded.pushoverReady)
        #expect(decoded.phoneReady == false)
        #expect(decoded.phoneSender(devices: devices) is PushoverAttentionSender)
        #expect(decoded.attentionPolicy.phoneEnabled)
        #expect(decoded.attentionPolicy.phoneAlertDelay == 180)
        #expect(decoded.attentionPolicy.idleThreshold == 120)

        var keyed = decoded
        keyed.apns = APNsKey(keyId: "K", teamId: "T", key: "-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----")
        #expect(keyed.attentionPolicy.phoneEnabled)
        let both = try #require(keyed.phoneSender(devices: devices) as? PhonePushFanout)
        #expect(both.senders.count == 2)
        let reread = try JSONDecoder().decode(NotificationSettings.self, from: JSONEncoder().encode(keyed))
        #expect(reread == keyed)
        #expect(reread.pushoverToken == "t")

        var apnsOnly = keyed
        apnsOnly.pushoverMode = .disabled
        #expect(apnsOnly.phoneSender(devices: devices) is APNsAttentionSender)
        var off = apnsOnly
        off.phonePush = false
        #expect(off.attentionPolicy.phoneEnabled == false)
        #expect(off.phoneSender(devices: devices) == nil)

        let legacyBool = try JSONDecoder().decode(NotificationSettings.self, from: Data(#"{"pushoverEnabled":true,"pushoverToken":"t","pushoverUserKey":"u"}"#.utf8))
        #expect(legacyBool.pushoverReady)
        let disabled = try JSONDecoder().decode(NotificationSettings.self, from: Data(#"{"pushoverMode":"disabled","pushoverToken":"t","pushoverUserKey":"u"}"#.utf8))
        #expect(disabled.pushoverReady == false)
        #expect(disabled.phonePush)
    }
}
