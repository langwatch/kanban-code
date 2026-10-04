import Foundation
import Testing

@testable import KanbanCodeCore

@Suite("Attention delivery: cardless requests, one phone message, plain copy")
struct AttentionDeliveryTests {
    final class Recorder: MacAttentionNotifier, PhonePushSender, @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        let silentCopy: Bool
        init(silentCopy: Bool = true) { self.silentCopy = silentCopy }
        var sendsSilentCopy: Bool { silentCopy }
        func record(_ e: String) { lock.withLock { events.append(e) } }
        func post(_ request: AttentionRequest, cardName: String?) async { record("mac+\(request.id)") }
        func remove(id: String) async { record("mac-\(id)") }
        func showInApp(_ request: AttentionRequest) async { record("app+\(request.id)") }
        func showOpenCount(_ count: Int) async { record("count=\(count)") }
        func send(_ request: AttentionRequest, cardName: String?, level: PhonePushLevel) async throws { record("phone:\(level.rawValue):\(request.id)") }
        func withdraw(_ request: AttentionRequest) async {}
    }

    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func advance(_ s: TimeInterval) { lock.withLock { value += s } }
    }

    let t0 = Date(timeIntervalSince1970: 3_000_000)

    func vaultRequest(card: String?) -> AttentionRequest {
        AttentionRequest(
            id: "vault_1", cardId: card, kind: .vaultApproval,
            title: "A process outside any card wants to change the tier of the Stripe API key",
            body: "Live Stripe keys move money, so every use should ask first.",
            options: AttentionRequest.vaultApprovalOptions, createdAt: t0, requiresBiometry: true,
            machineId: "mac-id")
    }

    @Test("a vault request with no card reaches the Mac at once and the phone after the delay, with Kanban in front", arguments: [nil, "card_1"] as [String?])
    func vaultReachesMacAndPhone(card: String?) async {
        let clock = Clock(t0)
        let mac = Recorder()
        let phone = Recorder(silentCopy: false)
        let center = AttentionCenter(
            mac: mac, phone: phone,
            localPresence: {
                MacPresence(isKanbanFrontmost: true, visibleCardId: "card_2", visibleTab: "terminal", idleSeconds: 1, reportedAt: clock.now)
            },
            localMachineId: { "mac-id" }, now: { clock.now })
        await center.deliver(vaultRequest(card: card))
        #expect(mac.events == ["count=1", "mac+vault_1"])
        #expect(phone.events.isEmpty)
        clock.advance(181)
        await center.evaluateAll()
        #expect(phone.events == ["phone:timeSensitive:vault_1"])
        clock.advance(60)
        await center.evaluateAll()
        #expect(phone.events.count == 1)
    }

    @Test("Pushover takes one message per request: no silent copy, only the alert")
    func pushoverHasNoSilentCopy() {
        #expect(PushoverAttentionSender(token: "t", userKey: "u").sendsSilentCopy == false)
        var settings = AttentionPolicySettings()
        settings.phoneSilentCopy = false
        let request = vaultRequest(card: nil)
        let present = MacPresence(idleSeconds: 1, reportedAt: t0)
        #expect(AttentionPolicy.steps(for: request, delivered: .init(), presence: present, now: t0, settings: settings) == [.postMac])
        let away = MacPresence(idleSeconds: 1, screenLocked: true, reportedAt: t0)
        #expect(AttentionPolicy.steps(for: request, delivered: .init(), presence: away, now: t0, settings: settings) == [.postMac, .phoneAlert])
    }

    @Test("the log says why a request was or was not delivered")
    func explains() {
        let request = vaultRequest(card: nil)
        let present = MacPresence(idleSeconds: 1, reportedAt: t0)
        let why = AttentionPolicy.explain(request, presence: present, now: t0, settings: .init(), macAvailable: true)
        #expect(why.contains("Mac in use") && why.contains("Mac on") && why.contains("phone on"))
        var looking = vaultRequest(card: "card_1")
        looking.kind = .question
        let watching = MacPresence(isKanbanFrontmost: true, visibleCardId: "card_1", visibleTab: "chat", idleSeconds: 1, reportedAt: t0)
        #expect(AttentionPolicy.explain(looking, presence: watching, now: t0, settings: .init(), macAvailable: true).contains("looking at card card_1"))
        #expect(AttentionPolicy.explain(request, presence: nil, now: t0, settings: .init(), macAvailable: false).contains("no Mac notifier"))
    }

    @Test("a card named after its whole first prompt makes a short title")
    func shortCardNames() {
        let long = "Use the AskUserQuestion tool to ask me exactly one question about lunch and wait"
        let short = AttentionCopy.shortName(long)
        #expect(short == "Use the AskUserQuestion tool to ask me...")
        #expect(short.count <= AttentionCopy.cardNameLimit + 3)
        #expect(AttentionCopy.shortName("Weekly newsletter") == "Weekly newsletter")
        let q = AttentionRequest(id: "q", cardId: "c", kind: .question, title: "Question", body: "Tea?")
        #expect(AttentionCopy.notification(for: q, cardName: long).title == "Use the AskUserQuestion tool to ask me... is asking you a question")
    }

    @Test("a permission notification is one plain line; the command stays in the detail sheet")
    func permissionCopy() {
        let use = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cd /root/x && ffmpeg -i a.mov a.mp4","description":"Convert the recording to mp4"}}]}}"#
        let call = AttentionDetector.pendingToolCall(inLines: [use])
        #expect(call?.summary == "Claude wants to run a command: Convert the recording to mp4")
        let body = MasterEngine.permissionBody(message: "Claude needs your permission to use Bash", tool: call)
        #expect(body == "Claude wants to run a command: Convert the recording to mp4\n\nBash: cd /root/x && ffmpeg -i a.mov a.mp4")
        let request = AttentionRequest(id: "perm_1", cardId: "c", kind: .permission, title: "Permission needed", body: body)
        let copy = AttentionCopy.notification(for: request, cardName: "Video card")
        #expect(copy == ("Video card needs your permission", "Claude wants to run a command: Convert the recording to mp4"))
        let push = Dictionary(PushoverAttentionSender.fields(for: request, cardName: "Video card", level: .timeSensitive), uniquingKeysWith: { a, _ in a })
        #expect(push["message"]?.contains("ffmpeg") == false)

        let rush = MasterEngine.permissionBody(message: "Bash cd /root/x && ffmpeg -i a.mov a.mp4", tool: nil)
        #expect(AttentionCopy.firstParagraph(rush) == "Claude wants to run a Bash command")
        #expect(rush.hasSuffix("Bash: cd /root/x && ffmpeg -i a.mov a.mp4"))
        #expect(MasterEngine.permissionBody(message: "Claude needs your permission to use Bash", tool: nil) == "Claude needs your permission to use Bash")
        #expect(MasterEngine.permissionBody(message: nil, tool: nil) == "Waiting for your permission")
        #expect(AttentionDetector.ToolCall(name: "Edit", detail: "/a/b/notes.md").summary == "Claude wants to edit notes.md")
    }

    @Test("an edit of many secrets names the change before the secrets")
    func manySecretEdit() {
        let details = VaultApprovalDetails(
            action: .edit, origin: .outside,
            secrets: [.init(name: "STRIPE_API_KEY", label: "Stripe API key", tier: "Always ask"), .init(name: "STRIPE_SECRET", label: "Stripe secret", tier: "Always ask")],
            changes: ["tier", "lease time"])
        #expect(AttentionCopy.vaultHeadline(details)
            == "A process outside any card wants to change the tier and lease time of the Stripe API key and the Stripe secret")
    }

    @Test("a vault approval on the card on screen opens its sheet in the app, never silently dropped")
    func vaultOnScreenOpensSheet() async {
        let looking = MacPresence(isKanbanFrontmost: true, visibleCardId: "card_1", visibleTab: "terminal", idleSeconds: 1, reportedAt: t0)
        let request = vaultRequest(card: "card_1")
        let s = AttentionPolicySettings()
        #expect(AttentionPolicy.steps(for: request, delivered: .init(), presence: looking, now: t0, settings: s) == [.showInApp])
        #expect(AttentionPolicy.steps(for: request, delivered: .init(macPosted: true), presence: looking, now: t0, settings: s) == [.removeMac, .showInApp])
        #expect(AttentionPolicy.steps(for: request, delivered: .init(shownInApp: true), presence: looking, now: t0, settings: s).isEmpty)
        #expect(AttentionPolicy.steps(for: request, delivered: .init(), presence: looking, now: t0, settings: s, macAvailable: false).isEmpty)
        var question = request
        question.kind = .question
        #expect(AttentionPolicy.steps(for: question, delivered: .init(), presence: looking, now: t0, settings: s).isEmpty)

        let clock = Clock(t0)
        let mac = Recorder()
        let center = AttentionCenter(
            mac: mac, phone: Recorder(silentCopy: false),
            localPresence: { MacPresence(isKanbanFrontmost: true, visibleCardId: "card_1", visibleTab: "terminal", idleSeconds: 1, reportedAt: clock.now) },
            localMachineId: { "mac-id" }, now: { clock.now })
        await center.deliver(request)
        await center.evaluateAll()
        #expect(mac.events == ["count=1", "app+vault_1"])
        #expect(await center.deliveryState("vault_1")?.shownInApp == true)
    }

    @Test("an open sheet in front gets no Mac notification, but one follows once Kanban leaves the front")
    func sheetInFrontSkipsMacNotification() {
        let sheetUp = MacPresence(isKanbanFrontmost: true, visibleCardId: nil, visibleTab: nil, idleSeconds: 1, reportedAt: t0)
        let elsewhere = MacPresence(isKanbanFrontmost: false, visibleCardId: nil, visibleTab: nil, idleSeconds: 1, reportedAt: t0)
        let request = vaultRequest(card: "card_1")
        var s = AttentionPolicySettings()
        s.phoneEnabled = false
        #expect(AttentionPolicy.steps(for: request, delivered: .init(shownInApp: true), presence: sheetUp, now: t0, settings: s).isEmpty)
        #expect(AttentionPolicy.steps(for: request, delivered: .init(shownInApp: true), presence: elsewhere, now: t0, settings: s) == [.postMac])
    }

    @Test("delivery state written before shownInApp existed still loads")
    func oldStateLoads() throws {
        let old = #"{"macPosted":true,"phoneSilentSent":false,"phoneAlertSent":true}"#
        let state = try JSONDecoder().decode(AttentionDeliveryState.self, from: Data(old.utf8))
        #expect(state == AttentionDeliveryState(macPosted: true, phoneAlertSent: true))
    }

    @Test("sheets wait in line, one at a time, skipping requests settled meanwhile")
    func sheetQueue() {
        var queue = AttentionSheetQueue.adding("b", to: [], shown: "a")
        queue = AttentionSheetQueue.adding("a", to: queue, shown: "a")
        queue = AttentionSheetQueue.adding("b", to: queue, shown: "a")
        queue = AttentionSheetQueue.adding("c", to: queue, shown: "a")
        #expect(queue == ["b", "c"])
        #expect(AttentionSheetQueue.popNext(&queue) { $0 != "b" } == "c")
        #expect(queue.isEmpty)
        #expect(AttentionSheetQueue.popNext(&queue) { _ in true } == nil)
    }

    @Test("a sheet left open on the card on screen reaches the phone after the delay, and the Mac once Kanban leaves the front")
    func openSheetEscalates() async {
        func looking(_ at: Date) -> MacPresence {
            MacPresence(isKanbanFrontmost: true, visibleCardId: "card_1", visibleTab: "terminal", idleSeconds: 1, reportedAt: at)
        }
        let request = vaultRequest(card: "card_1")
        var s = AttentionPolicySettings()
        s.phoneSilentCopy = false
        func steps(_ delivered: AttentionDeliveryState, after: TimeInterval, _ settings: AttentionPolicySettings, macAvailable: Bool = true) -> [AttentionDeliveryStep] {
            AttentionPolicy.steps(for: request, delivered: delivered, presence: looking(t0 + after), now: t0 + after, settings: settings, macAvailable: macAvailable)
        }
        #expect(steps(.init(shownInApp: true), after: 179, s).isEmpty)
        #expect(steps(.init(shownInApp: true), after: 180, s) == [.phoneAlert])
        #expect(steps(.init(phoneAlertSent: true, shownInApp: true), after: 400, s).isEmpty)
        // A master with no screen (the box) phones the card it cannot show.
        #expect(steps(.init(), after: 180, s, macAvailable: false) == [.phoneAlert])
        var phoneOff = s
        phoneOff.phoneEnabled = false
        #expect(steps(.init(shownInApp: true), after: 400, phoneOff).isEmpty)

        final class Presence: @unchecked Sendable {
            let lock = NSLock()
            var frontmost = true
        }
        let presence = Presence()
        let clock = Clock(t0)
        let mac = Recorder()
        let phone = Recorder(silentCopy: false)
        let center = AttentionCenter(
            mac: mac, phone: phone,
            localPresence: {
                let front = presence.lock.withLock { presence.frontmost }
                return MacPresence(isKanbanFrontmost: front, visibleCardId: "card_1", visibleTab: "terminal", idleSeconds: 1, reportedAt: clock.now)
            },
            localMachineId: { "mac-id" }, now: { clock.now })
        await center.deliver(request)
        clock.advance(60)
        await center.evaluateAll()
        #expect(mac.events == ["count=1", "app+vault_1"])
        #expect(phone.events.isEmpty)
        clock.advance(121)
        await center.evaluateAll()
        #expect(phone.events == ["phone:timeSensitive:vault_1"])
        presence.lock.withLock { presence.frontmost = false }
        await center.evaluateAll()
        #expect(mac.events == ["count=1", "app+vault_1", "mac+vault_1"])
        #expect(phone.events.count == 1)
    }

    @Test("the Dock count follows every open request, shown in the app or notified")
    func dockCountsOpenRequests() async {
        let clock = Clock(t0)
        let mac = Recorder()
        let center = AttentionCenter(
            mac: mac,
            localPresence: { MacPresence(isKanbanFrontmost: true, visibleCardId: "card_1", visibleTab: "terminal", idleSeconds: 1, reportedAt: clock.now) },
            localMachineId: { "mac-id" }, now: { clock.now })
        var requests: [AttentionRequest] = []
        for i in 1...3 {
            var r = vaultRequest(card: "card_1")
            r.id = "vault_\(i)"
            requests.append(r)
            await center.deliver(r)
        }
        await center.update(requests[0])
        var settled = requests[1]
        settled.resolvedAt = t0
        settled.resolution = "Deny"
        settled.resolvedBy = "timeout"
        await center.withdraw(settled)
        await center.withdraw(settled)
        #expect(mac.events.filter { $0.hasPrefix("count=") } == ["count=1", "count=2", "count=3", "count=2"])
        #expect(mac.events.filter { $0.hasPrefix("app+") } == ["app+vault_1", "app+vault_2", "app+vault_3"])
    }

    @Test("a request raised again after a restart opens its sheet again")
    func restartShowsSheetAgain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attention-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("state.json").path
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let looking: @Sendable () async -> MacPresence? = {
            MacPresence(isKanbanFrontmost: true, visibleCardId: "card_1", visibleTab: "terminal", idleSeconds: 1, reportedAt: Date())
        }
        let first = Recorder()
        let before = AttentionCenter(mac: first, localPresence: looking, localMachineId: { "mac-id" }, stateFile: file)
        await before.deliver(vaultRequest(card: "card_1"))
        #expect(first.events.contains("app+vault_1"))
        let second = Recorder()
        let after = AttentionCenter(mac: second, localPresence: looking, localMachineId: { "mac-id" }, stateFile: file)
        await after.deliver(vaultRequest(card: "card_1"))
        #expect(second.events.contains("app+vault_1"))
    }

    @Test("a sheet whose request was settled, withdrawn or pruned gives way to the next open one; none is lost")
    func sheetNeverStaysOnASettledRequest() {
        var open: Set<String> = ["a", "b", "c", "d"]
        var waiting: [String] = []
        var shown: String? = AttentionSheetQueue.current(shown: nil, waiting: &waiting, isOpen: open.contains)
        #expect(shown == nil)
        shown = "a"
        for id in ["b", "c", "d"] { waiting = AttentionSheetQueue.adding(id, to: waiting, shown: shown) }
        #expect(AttentionSheetQueue.waitingCount(waiting, isOpen: open.contains) == 3)
        #expect(AttentionSheetQueue.current(shown: shown, waiting: &waiting, isOpen: open.contains) == "a")
        // Answered on the phone, then pruned from the state: the sheet moves on.
        open.remove("a")
        shown = AttentionSheetQueue.current(shown: shown, waiting: &waiting, isOpen: open.contains)
        #expect(shown == "b")
        // One that waited timed out meanwhile: skipped, the rest still show.
        open.remove("c")
        #expect(AttentionSheetQueue.waitingCount(waiting, isOpen: open.contains) == 1)
        open.remove("b")
        shown = AttentionSheetQueue.current(shown: shown, waiting: &waiting, isOpen: open.contains)
        #expect(shown == "d")
        open.remove("d")
        shown = AttentionSheetQueue.current(shown: shown, waiting: &waiting, isOpen: open.contains)
        #expect(shown == nil)
        #expect(waiting.isEmpty)
    }

    @Test("an approval waits twelve hours before it is denied")
    func approvalTimeoutIsTwelveHours() {
        #expect(VaultPolicy.approvalTimeout == 12 * 3600)
    }

    @Test("test runs log to their own file")
    func testRunsLogApart() {
        #expect(KanbanCodeLog.isTestRun)
    }
}
