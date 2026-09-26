import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit
import Synchronization

// Development server for the remote control clients (iOS app, `kanban remote`):
// the real RemoteControlServer over a fake board that reacts to tasks and
// prompts, with real shells (or agtop) behind the terminals.
//
//   swift run kanban-code-remote-demo --pair iPhone
//   swift run kanban-code-remote-demo --port 7790 --pair openclaw --scope agent --agtop <agtop id>

struct DemoOptions {
    var port = 7790
    var devicesPath = FileManager.default.currentDirectoryPath + "/.claude/tmp/remote-demo/devices.json"
    var pairName: String?
    var scope: RemoteScope = .full
    var agtopId: String?
    var loopbackOnly = false

    static func parse(_ args: [String]) -> DemoOptions {
        var o = DemoOptions()
        var i = 0
        func value() -> String {
            i += 1
            guard i < args.count else { usage("missing value for \(args[i - 1])") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--port": o.port = Int(value()) ?? o.port
            case "--devices": o.devicesPath = value()
            case "--pair": o.pairName = value()
            case "--scope": o.scope = RemoteScope(rawValue: value()) ?? .full
            case "--agtop": o.agtopId = value()
            case "--loopback-only": o.loopbackOnly = true
            case "-h", "--help": usage(nil)
            default: usage("unknown argument \(args[i])")
            }
            i += 1
        }
        return o
    }

    static func usage(_ error: String?) -> Never {
        if let error { FileHandle.standardError.write(Data("error: \(error)\n\n".utf8)) }
        print("""
        usage: kanban-code-remote-demo [--port 7790] [--devices <path>] [--pair <name> [--scope full|agent]]
                                       [--agtop <agtop session id>] [--loopback-only]

          --pair      adds a device and prints its token and kanbancode://pair link
          --devices   devices file (default .claude/tmp/remote-demo/devices.json)
          --agtop     makes the "agtop" demo card open `agtop open <id> --solo`
        """)
        exit(error == nil ? 0 : 2)
    }
}

final class DemoHost: RemoteControlHost {
    struct CardState {
        var card: RemoteCard
        var messages: [RemoteMessage]
        var agtopId: String?
    }

    struct State {
        var cards: [CardState] = []
        var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
        var counter = 0
    }

    let state = Mutex(State())
    let projects = [
        RemoteProject(path: "/Users/demo/Projects/acme-web", name: "acme-web"),
        RemoteProject(path: "/Users/demo/Projects/acme-api", name: "acme-api"),
    ]

    init(agtopId: String?) {
        let now = Date()
        func card(_ id: String, _ title: String, _ column: RemoteColumn, project: Int, runtime: RemoteRuntime,
                  live: Bool, busy: Bool = false, prs: [RemotePR] = [], queued: Int = 0, minutesAgo: Double) -> RemoteCard {
            let p = projects[project]
            return RemoteCard(
                id: id, title: title, column: column, projectPath: p.path, projectName: p.name,
                branch: "demo/\(id)", worktreePath: runtime == .none ? nil : "\(p.path)/.claude/worktrees/\(id)",
                assistant: id == "card_codex" ? "codex" : "claude", runtime: runtime, isLive: live, isBusy: busy,
                sessionId: runtime == .none ? nil : UUID().uuidString.lowercased(),
                terminals: live ? [
                    RemoteTerminal(sessionName: "\(p.name)-\(id)", label: "claude", isPrimary: true),
                    RemoteTerminal(sessionName: "\(p.name)-\(id)-sh1", label: "shell", isPrimary: false),
                ] : [],
                prs: prs, queuedPromptCount: queued,
                queuedPrompts: (0..<queued).map { RemoteQueuedPrompt(id: "prompt_seed\($0)", text: "Also run the e2e suite once it passes") },
                lastActivity: now.addingTimeInterval(-minutesAgo * 60), updatedAt: now
            )
        }
        let cards: [CardState] = [
            .init(card: card("card_busy", "Fix the flaky checkout test", .inProgress, project: 0, runtime: .tmux, live: true, busy: true, queued: 1, minutesAgo: 1),
                  messages: Self.conversation("Fix the flaky checkout test")),
            .init(card: card("card_agtop", "Refactor the billing webhooks", .inProgress, project: 1, runtime: .agtop, live: true, minutesAgo: 4),
                  messages: Self.conversation("Refactor the billing webhooks"), agtopId: agtopId),
            .init(card: card("card_wait", "Add dark mode to settings", .waiting, project: 0, runtime: .tmux, live: true, minutesAgo: 12),
                  messages: Self.conversation("Add dark mode to settings")),
            .init(card: card("card_codex", "Speed up the search index", .inReview, project: 1, runtime: .tmux, live: false,
                             prs: [RemotePR(number: 412, url: "https://github.com/acme/acme-api/pull/412", title: "perf: faster search index", status: "open")],
                             minutesAgo: 90),
                  messages: Self.conversation("Speed up the search index")),
            .init(card: card("card_backlog", "Write the migration guide", .backlog, project: 0, runtime: .none, live: false, minutesAgo: 600),
                  messages: []),
            .init(card: card("card_done", "Bump dependencies", .done, project: 1, runtime: .tmux, live: false,
                             prs: [RemotePR(number: 398, title: "chore: bump deps", status: "merged")], minutesAgo: 2000),
                  messages: Self.conversation("Bump dependencies")),
        ]
        state.withLock { $0.cards = cards }
    }

    static func conversation(_ task: String) -> [RemoteMessage] {
        var out: [RemoteMessage] = []
        var t = Date().addingTimeInterval(-3600)
        func add(_ role: RemoteMessage.Role, _ text: String) {
            t = t.addingTimeInterval(40)
            out.append(RemoteMessage(id: "m\(out.count)", role: role, text: text, at: t))
        }
        add(.user, task)
        add(.assistant, "I'll start by looking at the code involved.")
        add(.tool, "Grep \"\(task.split(separator: " ").last ?? "")\" in src/")
        add(.tool, "Read src/app/main.ts")
        for i in 0..<30 {
            add(.assistant, "Step \(i + 1): checked part \(i + 1) of the change. **Markdown** works, `code` too.\n\n- one\n- two")
            if i % 3 == 0 { add(.tool, "Bash pnpm test --filter part-\(i + 1)") }
        }
        add(.assistant, "Done. The change is in place and the tests pass.")
        return out
    }

    private func notify() {
        let conts = state.withLock { Array($0.continuations.values) }
        conts.forEach { $0.yield() }
    }

    private func update(_ id: String, _ change: (inout CardState) -> Void) {
        state.withLock { s in
            if let i = s.cards.firstIndex(where: { $0.card.id == id }) {
                change(&s.cards[i])
                s.cards[i].card.updatedAt = Date()
            }
        }
        notify()
    }

    private func cardState(_ id: String) throws -> CardState {
        guard let c = state.withLock({ $0.cards.first { $0.card.id == id } }) else {
            throw RemoteHostError.notFound("no card \(id)")
        }
        return c
    }

    /// The assistant "works" for a few seconds, then answers.
    private func simulateTurn(_ id: String, reply: String) {
        update(id) { c in
            c.card.isBusy = true
            c.card.column = .inProgress
            c.card.lastActivity = Date()
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            self.update(id) { c in
                c.messages.append(RemoteMessage(id: "m\(c.messages.count)", role: .tool, text: "Read src/demo.ts", at: Date()))
            }
            try? await Task.sleep(for: .seconds(2))
            self.update(id) { c in
                c.messages.append(RemoteMessage(id: "m\(c.messages.count)", role: .assistant, text: reply, at: Date()))
                c.card.isBusy = false
                c.card.column = .waiting
                c.card.lastActivity = Date()
            }
        }
    }

    func board() async -> RemoteBoard {
        state.withLock { s in RemoteBoard(cards: s.cards.map(\.card), projects: projects, generatedAt: Date()) }
    }

    func transcript(cardId: String, limit: Int, before: String?) async throws -> RemoteTranscript {
        let all = try cardState(cardId).messages
        let end = min(before.flatMap(Int.init) ?? all.count, all.count)
        let start = max(0, end - limit)
        return RemoteTranscript(cardId: cardId, messages: Array(all[start..<end]), olderCursor: start > 0 ? String(start) : nil)
    }

    func createTask(_ request: RemoteTaskRequest) async throws -> RemoteCard {
        let key = request.project.lowercased()
        guard let project = projects.first(where: { $0.path == request.project || $0.name.lowercased() == key }) else {
            throw RemoteHostError.badRequest("unknown project \(request.project); known: \(projects.map(\.name).joined(separator: ", "))")
        }
        let n = state.withLock { s -> Int in
            s.counter += 1
            return s.counter
        }
        let id = "card_task\(n)"
        let launch = request.launch ?? true
        let worktree = request.worktree.map { $0.isEmpty ? "wt-\(n)" : $0 }
        let card = RemoteCard(
            id: id, title: request.name ?? String(request.prompt.prefix(60)), column: launch ? .inProgress : .backlog,
            projectPath: project.path, projectName: project.name, branch: worktree.map { "demo/\($0)" },
            worktreePath: worktree.map { "\(project.path)/.claude/worktrees/\($0)" }, assistant: request.assistant ?? "claude",
            runtime: launch ? .tmux : .none, isLive: launch, isBusy: launch, sessionId: launch ? UUID().uuidString.lowercased() : nil,
            terminals: launch ? [RemoteTerminal(sessionName: "\(project.name)-\(id)", label: "claude", isPrimary: true)] : [],
            lastActivity: Date(), updatedAt: Date()
        )
        state.withLock { s in
            s.cards.append(CardState(card: card, messages: [RemoteMessage(id: "m0", role: .user, text: request.prompt, at: Date())]))
        }
        notify()
        if launch { simulateTurn(id, reply: "Started on it: \(request.prompt)") }
        return card
    }

    func sendPrompt(cardId: String, _ request: RemotePromptRequest, images: [RemotePromptImages.Decoded]) async throws {
        let c = try cardState(cardId)
        guard c.card.isLive else { throw RemoteHostError.conflict("card \(cardId) has no live session; resume it first") }
        let text = Self.promptText(request.text, imageCount: images.count)
        if c.card.isBusy && request.mode != .now {
            let prompt = RemoteQueuedPrompt(id: "prompt_\(UUID().uuidString.prefix(8))", text: request.text, imageCount: images.count)
            update(cardId) { c in
                c.card.queuedPrompts.append(prompt)
                c.card.queuedPromptCount = c.card.queuedPrompts.count
            }
            deliverWhenIdle(cardId)
            return
        }
        deliver(cardId, text: text, interrupting: c.card.isBusy)
    }

    /// What the transcript shows for a prompt, with its images as the Mac pastes them.
    static func promptText(_ text: String, imageCount: Int) -> String {
        let images = (0..<imageCount).map { "[Image #\($0 + 1)]" }.joined(separator: " ")
        return [images, text].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func deliver(_ cardId: String, text: String, interrupting: Bool) {
        update(cardId) { c in
            if interrupting {
                c.messages.append(RemoteMessage(id: "m\(c.messages.count)", role: .system, text: "Interrupted", at: Date()))
            }
            c.messages.append(RemoteMessage(id: "m\(c.messages.count)", role: .user, text: text, at: Date()))
        }
        simulateTurn(cardId, reply: "Got it: \(text)")
    }

    /// Sends the oldest queued prompt once the turn ends, as the Mac does.
    private func deliverWhenIdle(_ cardId: String) {
        Task {
            while (try? self.cardState(cardId))?.card.isBusy == true { try? await Task.sleep(for: .milliseconds(200)) }
            guard let next = self.popQueued(cardId, promptId: nil) else { return }
            self.deliver(cardId, text: Self.promptText(next.text, imageCount: next.imageCount), interrupting: false)
        }
    }

    private func popQueued(_ cardId: String, promptId: String?) -> RemoteQueuedPrompt? {
        var popped: RemoteQueuedPrompt?
        update(cardId) { c in
            guard let index = promptId.map({ id in c.card.queuedPrompts.firstIndex { $0.id == id } })
                    ?? (c.card.queuedPrompts.isEmpty ? nil : 0) else { return }
            popped = c.card.queuedPrompts.remove(at: index)
            c.card.queuedPromptCount = c.card.queuedPrompts.count
        }
        return popped
    }

    func sendQueuedPromptNow(cardId: String, promptId: String) async throws {
        let c = try cardState(cardId)
        guard c.card.isLive else { throw RemoteHostError.conflict("card \(cardId) has no live session; resume it first") }
        guard let prompt = popQueued(cardId, promptId: promptId) else {
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId); it may have been sent already")
        }
        deliver(cardId, text: Self.promptText(prompt.text, imageCount: prompt.imageCount), interrupting: c.card.isBusy)
        if !(try cardState(cardId)).card.queuedPrompts.isEmpty { deliverWhenIdle(cardId) }
    }

    func removeQueuedPrompt(cardId: String, promptId: String) async throws {
        _ = try cardState(cardId)
        guard popQueued(cardId, promptId: promptId) != nil else {
            throw RemoteHostError.notFound("card \(cardId) has no queued prompt \(promptId)")
        }
    }

    func scrollTerminal(sessionName: String, lines: Int) async {
        print("scroll \(sessionName) \(lines)")
    }

    func interrupt(cardId: String) async throws {
        let c = try cardState(cardId)
        guard c.card.isLive else { throw RemoteHostError.conflict("card \(cardId) has no live session") }
        update(cardId) { c in
            c.card.isBusy = false
            c.card.column = .waiting
            c.messages.append(RemoteMessage(id: "m\(c.messages.count)", role: .system, text: "Interrupted", at: Date()))
        }
    }

    func resume(cardId: String) async throws -> RemoteCard {
        _ = try cardState(cardId)
        update(cardId) { c in
            guard !c.card.isLive else { return }
            c.card.isLive = true
            c.card.column = .waiting
            if c.card.runtime == .none { c.card.runtime = .tmux }
            let name = "\(c.card.projectName ?? "demo")-\(c.card.id)"
            c.card.terminals = [RemoteTerminal(sessionName: name, label: "claude", isPrimary: true)]
        }
        return try cardState(cardId).card
    }

    func terminalCommand(cardId: String, sessionName: String) async throws -> [String] {
        let c = try cardState(cardId)
        guard c.card.isLive else { throw RemoteHostError.conflict("card \(cardId) has no live session") }
        if c.card.runtime == .agtop, let id = c.agtopId {
            return ["agtop", "open", id, "--solo"]
        }
        return ["/bin/zsh", "-l"]
    }

    func boardChanges() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, cont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cont.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.continuations.removeValue(forKey: id) }
        }
        state.withLock { $0.continuations[id] = cont }
        return stream
    }
}

let options = DemoOptions.parse(Array(CommandLine.arguments.dropFirst()))
let devices = RemoteDeviceStore(path: options.devicesPath)
let host = DemoHost(agtopId: options.agtopId)
let loopbackOnly = options.loopbackOnly
let bindAddresses: @Sendable () -> [String] = {
    loopbackOnly ? [RemoteNetworkAddresses.loopback] : RemoteNetworkAddresses.bindable()
}
let server = RemoteControlServer(
    host: host, devices: devices, port: options.port,
    bindAddresses: bindAddresses,
    options: .init(appVersion: "demo")
)

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

do {
    try await server.start()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

let tailscale = RemoteNetworkAddresses.tailscale()
let urls = server.listeningAddresses.map { addr in
    addr.contains(":") ? "http://[\(addr)]:\(server.port)" : "http://\(addr):\(server.port)"
}
print("kanban-code-remote-demo listening on:")
urls.forEach { print("  \($0)") }
print("devices file: \(devices.path)")

if let name = options.pairName {
    let (device, token) = try devices.add(name: name, scope: options.scope)
    let base = tailscale.first(where: { !$0.contains(":") }).map { "http://\($0):\(server.port)" } ?? "http://127.0.0.1:\(server.port)"
    let link = RemotePairLink.make(url: base, token: token, name: RemoteControlServer.defaultHostName)
    print("paired \(device.name) (\(device.scope.rawValue)), id \(device.id)")
    print("token: \(token)")
    print("pair link: \(link)")
    print("try: curl -H 'Authorization: Bearer \(token)' \(base)/v1/board")
}

// Serve until killed.
while true {
    try await Task.sleep(for: .seconds(3600))
}
