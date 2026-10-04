import Foundation
import KanbanCodeCore
import KanbanCodeRemoteKit
import Synchronization

// Development server for the remote control clients (iOS app, `kanban remote`):
// the real RemoteControlServer over a fake board that reacts to tasks and
// prompts, with real shells (or rush) behind the terminals.
//
//   swift run kanban-code-remote-demo --pair iPhone
//   swift run kanban-code-remote-demo --port 7790 --pair openclaw --scope agent --rush <rush id>
//
// Two masters, as a Mac and an always-on box:
//
//   swift run kanban-code-remote-demo --port 7790 --machine machine_mac:Studio --pair iPhone
//   swift run kanban-code-remote-demo --port 7791 --machine machine_box:rchaves-platform --cards box \
//       --foreign machine_mac:Studio --pair iPhone

struct DemoOptions {
    var port = 7790
    var devicesPath = FileManager.default.currentDirectoryPath + "/.claude/tmp/remote-demo/devices.json"
    var pairName: String?
    var scope: RemoteScope = .full
    var rushId: String?
    var tmuxSocket: String?
    var loopbackOnly = false
    /// This master's identity, `id:name`. Without it the board names no machine, as an older server.
    var machine: RemoteMachine?
    /// `default` or `box`: which demo cards this master owns.
    var cards = "default"
    /// A master whose synced copy of `card_wait` this board also lists, `id:name`.
    var foreign: RemoteMachine?
    /// Exits once this file exists (and removes it): UI tests take a master offline this way.
    var exitWhen: String?

    static func machine(_ spec: String) -> RemoteMachine {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        return RemoteMachine(id: parts[0], name: parts.count > 1 ? parts[1] : parts[0])
    }

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
            case "--rush": o.rushId = value()
            case "--tmux-socket": o.tmuxSocket = value()
            case "--loopback-only": o.loopbackOnly = true
            case "--machine": o.machine = machine(value())
            case "--cards": o.cards = value()
            case "--foreign": o.foreign = machine(value())
            case "--exit-when": o.exitWhen = value()
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
                                       [--rush <rush session id>] [--tmux-socket <name>] [--loopback-only]
                                       [--machine <id:name>] [--cards default|box] [--foreign <id:name>]
                                       [--exit-when <file>]

          --pair      adds a device and prints its token and kanbancode://pair link
          --devices   devices file (default .claude/tmp/remote-demo/devices.json)
          --rush      makes the "rush" demo card open `rush open <id>`
          --tmux-socket  tmux cards attach to a session on this tmux server (tmux -L <name>,
                      no config file), created on first open, and scroll frames drive its copy-mode
          --machine   this master's identity; the board and its cards name it
          --cards     box: a second master's cards (ids box_*), for running two demos side by side
          --foreign   also list a synced copy of card_wait owned by that machine, as a peer's board does
          --exit-when exit as soon as this file exists, and remove it (a test takes the master offline)
        """)
        exit(error == nil ? 0 : 2)
    }
}

final class DemoHost: RemoteControlHost {
    struct CardState {
        var card: RemoteCard
        var messages: [RemoteMessage]
        var rushId: String?
    }

    struct State {
        var cards: [CardState] = []
        var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
        var counter = 0
        var sideChats: [String: SideChat] = [:]
        /// Each card's last catch-up and the message count it covered.
        var keptCatchUps: [String: (run: String, covered: Int)] = [:]
    }

    /// A side chat answer written ahead and shown a bit more on every read,
    /// as a streamed one is.
    struct SideChat {
        var run: RemoteSideChatRun
        var answer: String
        var startedAt = Date()
    }

    let state = Mutex(State())
    let projects = [
        RemoteProject(path: "/Users/demo/Projects/acme-web", name: "acme-web"),
        RemoteProject(path: "/Users/demo/Projects/acme-api", name: "acme-api"),
    ]

    let tmuxSocket: String?
    let machine: RemoteMachine?
    /// Prefix of the ids of this master's cards.
    let idPrefix: String

    init(rushId: String?, tmuxSocket: String? = nil, machine: RemoteMachine? = nil, cards flavor: String = "default",
         foreign: RemoteMachine? = nil) {
        self.tmuxSocket = tmuxSocket
        self.machine = machine
        idPrefix = flavor == "box" ? "box_" : "card_"
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
                lastActivity: now.addingTimeInterval(-minutesAgo * 60), updatedAt: now,
                machineId: machine?.id, machineName: machine?.name
            )
        }
        if flavor == "box" {
            var cards: [CardState] = [
                .init(card: card("box_backfill", "Nightly data backfill", .inProgress, project: 1, runtime: .tmux, live: true, busy: true, minutesAgo: 2),
                      messages: Self.conversation("Nightly data backfill")),
                .init(card: card("box_deploy", "Deploy the blog", .waiting, project: 0, runtime: .tmux, live: true, minutesAgo: 8),
                      messages: Self.conversation("Deploy the blog")),
                .init(card: card("box_certs", "Rotate the TLS certificates", .backlog, project: 1, runtime: .none, live: false, minutesAgo: 300),
                      messages: []),
            ]
            if let foreign {
                // A peer's card as sync brings it: the peer runs it, so no live state here.
                var copy = card("card_wait", "Add dark mode to settings", .waiting, project: 0, runtime: .tmux, live: false, minutesAgo: 30)
                copy.machineId = foreign.id
                copy.machineName = foreign.name
                cards.append(.init(card: copy, messages: []))
            }
            state.withLock { $0.cards = cards }
            return
        }
        let cards: [CardState] = [
            .init(card: card("card_busy", "Fix the flaky checkout test", .inProgress, project: 0, runtime: .tmux, live: true, busy: true,
                             prs: (0..<7).map { RemotePR(number: 8320 + $0, status: $0 == 0 ? "open" : "merged") }, queued: 1, minutesAgo: 1),
                  messages: Self.conversation("Fix the flaky checkout test")),
            .init(card: card("card_rush", "Refactor the billing webhooks", .inProgress, project: 1, runtime: .rush, live: true, minutesAgo: 4),
                  messages: Self.conversation("Refactor the billing webhooks"), rushId: rushId),
            .init(card: card("card_wait", "Add dark mode to settings", .waiting, project: 0, runtime: .tmux, live: true, minutesAgo: 12),
                  messages: Self.conversation("Add dark mode to settings")),
            .init(card: card("card_codex", "Speed up the search index", .inReview, project: 1, runtime: .tmux, live: false,
                             prs: [RemotePR(number: 412, url: "https://github.com/acme/acme-api/pull/412", title: "perf: faster search index", status: "open")],
                             minutesAgo: 90),
                  messages: Self.conversation("Speed up the search index")),
            .init(card: card("card_long", "Write the release notes", .waiting, project: 1, runtime: .tmux, live: true, minutesAgo: 20),
                  messages: Self.longEnding("Write the release notes")),
            .init(card: card("card_catchup", "Move the reports to the new API", .waiting, project: 1, runtime: .tmux, live: true, minutesAgo: 25),
                  messages: Self.awayConversation("Move the reports to the new API")),
            .init(card: card("card_compact", "Trim the session after the audit", .done, project: 0, runtime: .tmux, live: true, minutesAgo: 180),
                  messages: Self.compactedConversation("Trim the session after the audit")),
            .init(card: card("card_table", "Spring cleaning", .waiting, project: 0, runtime: .tmux, live: true, minutesAgo: 40),
                  messages: Self.tableConversation("Spring cleaning")),
            .init(card: card("card_backlog", "Write the migration guide", .backlog, project: 0, runtime: .none, live: false, minutesAgo: 600),
                  messages: []),
            .init(card: card("card_huge", "Read the crash dump", .backlog, project: 1, runtime: .tmux, live: false, minutesAgo: 900),
                  messages: Self.hugeMessages("Read the crash dump")),
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
            out.append(RemoteMessage(id: "\(out.count)", role: role, text: text, at: t))
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

    /// A long session the human left alone after his first message: steps,
    /// messages from another agent, and a long final report. Longer than two
    /// pages, so its start is not loaded when the chat opens.
    static func awayConversation(_ task: String) -> [RemoteMessage] {
        var out: [RemoteMessage] = []
        var t = Date().addingTimeInterval(-7200)
        func add(_ role: RemoteMessage.Role, _ text: String) {
            t = t.addingTimeInterval(50)
            out.append(RemoteMessage(id: "\(out.count)", role: role, text: text, at: t))
        }
        add(.user, "\(task). Keep the old endpoints working until the dashboard has moved.")
        add(.assistant, "I'll map the report endpoints first.")
        for i in 0..<40 {
            add(.tool, "Read src/reports/report-\(i + 1).ts")
            add(.assistant, "Report \(i + 1) of 40 moved to the new API and its test passes.")
            if i == 12 {
                add(.user, "[Message from @deploy-bot]: staging is on the new API since 14:00")
            }
            if i == 27 {
                add(.assistant, "The export report needs a new database index. I did not add it: it locks the table for minutes.")
            }
        }
        let body = (1...12).map { "Part \($0): what moved, what stayed on the old endpoint and how it was checked. Long enough to wrap over several lines on a phone." }
        add(.assistant, "## Final report\n\nAll 40 reports are on the new API.\n\n" + body.joined(separator: "\n\n"))
        add(.user, "[Message from @deploy-bot]: the nightly export failed once and passed on retry")
        add(.assistant, "Noted. Waiting for a decision on the export index.")
        return out
    }

    /// A conversation whose last two messages are very long, for opening a
    /// chat at its true end.
    static func longEnding(_ task: String) -> [RemoteMessage] {
        var out = conversation(task)
        let t = Date().addingTimeInterval(-1200)
        func long(_ title: String, paragraphs: Int, last: String) -> String {
            let body = (1...paragraphs).map { i in
                "\(title) part \(i): the notes cover the change, why it was made, what to check after upgrading and which settings moved. Every paragraph is long enough to wrap over several lines on a phone."
            }
            return (body + [last]).joined(separator: "\n\n")
        }
        out.append(RemoteMessage(id: "\(out.count)", role: .assistant, text: long("Draft", paragraphs: 40, last: "That was the first draft."), at: t))
        out.append(RemoteMessage(id: "\(out.count)", role: .assistant, text: long("Final", paragraphs: 60, last: "End of the release notes."), at: t.addingTimeInterval(30)))
        return out
    }

    /// A session whose answers hold markdown tables: three columns with
    /// long text in the first and last, a table too wide for a phone, and
    /// lines with pipes that are not a table.
    static func tableConversation(_ task: String) -> [RemoteMessage] {
        let t = Date().addingTimeInterval(-2400)
        let wide = """
            Per folder, widest first:

            | Folder | Size on disk | Files | Last touched | Owner | Safe to delete | Why |
            |---|---:|---:|:---:|---|:---:|---|
            | `~/Projects/acme-web/.claude/worktrees` | 48 GB | 1,204,331 | 12 days ago | you | yes | Every worktree older than a week has its branch merged |
            | `~/Library/Caches/go-build` | 8 GB | 90,112 | today | go | yes | Rebuilt on the next build |
            | `~/Movies/Screen recordings` | 22 GB | 41 | 3 months ago | you | ask | Not backed up anywhere |

            To list them yourself run `du -sh * | sort -h` and then `ls | wc -l`.
            """
        let three = """
            Here is what can go:

            | What | Frees | Notes |
            |---|---:|---|
            | Go build cache in `~/Library/Caches/go-build`, rebuilt on demand | 8 GB | Safe. The next `go build` takes about **4 minutes** longer |
            | Worktrees not touched for 14 days, `a \\| b` branches included | 48 GB | Each one is checked with `git status` first, see [the list](https://example.com/list) |
            | Old `links.json` backups | 3.5 GB | Keeps the newest 5 |

            - Totals by kind:

              | Kind | Size |
              |:---:|---:|
              | Caches | 8 GB |
              | Worktrees | 48 GB |

            Say the word and I delete them.
            """
        return [
            RemoteMessage(id: "0", role: .user, text: task, at: t),
            RemoteMessage(id: "1", role: .assistant, text: wide, at: t.addingTimeInterval(40)),
            RemoteMessage(id: "2", role: .assistant, text: three, at: t.addingTimeInterval(80)),
        ]
    }

    /// A session that was compacted as its last act: the `/compact` note,
    /// then the note that opens to the long summary the harness wrote.
    static func compactedConversation(_ task: String) -> [RemoteMessage] {
        var out = conversation(task)
        let t = Date().addingTimeInterval(-10_800)
        let parts = (1...45).map { i in
            "\(i). Part \(i) of the earlier work: what was asked, which files changed, what failed and how it was fixed. Long enough to wrap over several lines on a phone."
        }
        let summary = "This session is being continued from a previous conversation that ran out of context. "
            + "The summary below covers the earlier portion of the conversation.\n\nSummary:\n"
            + parts.joined(separator: "\n\n")
            + "\n\nContinue the conversation from where it left off without asking the user any further questions."
        out.append(RemoteMessage(id: "\(out.count)", role: .system, text: "/compact", at: t))
        out.append(RemoteMessage(id: "\(out.count)", role: .system, text: HarnessNote.compactedTitle,
                                 at: t.addingTimeInterval(30), detail: summary))
        return out
    }

    /// Cards whose prompts take a few seconds to be accepted, as a master
    /// that forwards to a slow peer does.
    static let slowSendCards: Set<String> = ["card_compact"]

    /// A pasted log of thousands of lines and a code block with one line of
    /// minified JSON a few hundred KB long: what made the phone's text
    /// layout stall for seconds.
    static func hugeMessages(_ task: String) -> [RemoteMessage] {
        let t = Date().addingTimeInterval(-50_000)
        let log = (1...6000).map { "2026-10-02T12:00:\(String(format: "%02d", $0 % 60))Z worker[\($0)] retry \($0) of the upload, status 503" }
            .joined(separator: "\n")
        let json = "{" + (1...12000).map { "\"key\($0)\":\"value \($0)\"" }.joined(separator: ",") + "}"
        return [
            RemoteMessage(id: "0", role: .user, text: "\(task)\n\n\(log)", at: t),
            RemoteMessage(id: "1", role: .assistant, text: "The dump:\n\n```json\n\(json)\n```\n\nHuge chat end.", at: t.addingTimeInterval(30)),
        ]
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
                c.messages.append(RemoteMessage(id: "\(c.messages.count)", role: .tool, text: "Read src/demo.ts", at: Date()))
            }
            try? await Task.sleep(for: .seconds(2))
            self.update(id) { c in
                c.messages.append(RemoteMessage(id: "\(c.messages.count)", role: .assistant, text: reply, at: Date()))
                c.card.isBusy = false
                c.card.column = .waiting
                c.card.lastActivity = Date()
            }
        }
    }

    func board() async -> RemoteBoard {
        state.withLock { s in RemoteBoard(cards: s.cards.map(\.card), projects: projects, generatedAt: Date(), machine: machine) }
    }

    func transcript(cardId: String, limit: Int, before: String?) async throws -> RemoteTranscript {
        let all = try cardState(cardId).messages
        let end = min(before.flatMap(Int.init) ?? all.count, all.count)
        let start = max(0, end - limit)
        return RemoteTranscript(cardId: cardId, messages: Array(all[start..<end]), olderCursor: start > 0 ? String(start) : nil)
    }

    // MARK: Slash commands

    func slashCommands(cardId: String) async throws -> [RemoteSlashCommand] {
        _ = try cardState(cardId)
        return SlashCommandCatalog.merged(assistant: .claude, sideChat: true, disk: [
            RemoteSlashCommand(name: "deploy", description: "Ship the current branch to staging", source: RemoteSlashCommand.Source.project),
            RemoteSlashCommand(name: "review", description: "Review recent changes before merge", source: RemoteSlashCommand.Source.user),
            RemoteSlashCommand(name: "catalog:search", description: "Search the product catalog", source: RemoteSlashCommand.Source.plugin),
        ])
    }

    // MARK: Side chat

    func startSideChat(cardId: String, _ request: RemoteSideChatRequest) async throws -> RemoteSideChatRun {
        let messages = try cardState(cardId).messages
        // Nothing new since the card's last catch-up: that one comes back, finished.
        if request.kind == .catchup, request.fresh != true,
           let kept = state.withLock({ $0.keptCatchUps[cardId] }), kept.covered == messages.count,
           let chat = state.withLock({ $0.sideChats[kept.run] }) {
            var run = chat.run
            run.text = chat.answer
            run.state = .done
            run.finishedAt = chat.startedAt
            run.reopened = true
            return run
        }
        let id = "side_\(UUID().uuidString.prefix(8).lowercased())"
        var run = RemoteSideChatRun(id: id, cardId: cardId, kind: request.kind)
        var answer: String
        switch request.kind {
        case .btw:
            let asked = (request.history?.count ?? 0) + 1
            answer = "Side answer \(asked) to \"\(request.question ?? "")\": the session holds \(messages.count) messages. "
                + "**Nothing** here was written into the conversation."
        case .catchup:
            let human = messages.lastIndex { $0.role == .user && !$0.text.hasPrefix("[Message from") }
            let since = human.map { messages[$0] }
            let scope = messages[(human ?? 0)...].filter { $0.role == .user || $0.role == .assistant }
            let refs = scope.enumerated().map { index, message in
                RemoteSideChatRef(ref: "m\(index + 1)", offset: Int(message.id) ?? 0,
                                  role: message.id == since?.id ? "you" : message.role == .assistant ? "assistant" : "message from @deploy-bot",
                                  at: message.at, preview: String(message.text.prefix(100)))
            }
            run.since = since.map { RemoteSideChatSince(text: $0.text, at: $0.at, offset: Int($0.id)) }
            run.refs = refs
            func ref(_ match: (RemoteMessage) -> Bool) -> String? {
                scope.firstIndex(where: match).map { "m\($0 + 1)" }
            }
            func line(_ section: String, _ text: String, _ ref: String?) -> String? {
                guard let ref else { return nil }
                return "{\"section\": \"\(section)\", \"text\": \"\(text)\", \"refs\": [\"\(ref)\"]}"
            }
            let last = refs.last?.ref
            answer = [
                line("asked", "You asked to move the reports to the new API.", refs.first?.ref),
                line("status", "Done: all 40 reports moved.", ref { $0.text.hasPrefix("## Final report") } ?? last),
                line("report", "Full report", ref { $0.text.hasPrefix("## Final report") }),
                line("facts", "Staging has been on the new API since 14:00.", ref { $0.text.contains("staging is on") }),
                line("waiting", "Decide on the export index: adding it locks the table for minutes.", ref { $0.text.contains("database index") } ?? last),
                line("other", "The nightly export failed once and passed on retry.", ref { $0.text.contains("nightly export") }),
            ].compactMap { $0 }.joined(separator: "\n")
        }
        state.withLock {
            $0.sideChats[id] = SideChat(run: run, answer: answer)
            if request.kind == .catchup { $0.keptCatchUps[cardId] = (id, messages.count) }
        }
        return run
    }

    func sideChatRun(cardId: String, runId: String) async throws -> RemoteSideChatRun {
        guard let chat = state.withLock({ $0.sideChats[runId] }), chat.run.cardId == cardId else {
            throw RemoteHostError.notFound("no side chat run \(runId)")
        }
        var run = chat.run
        let shown = Int(Date().timeIntervalSince(chat.startedAt) * 300)
        run.text = String(chat.answer.prefix(shown))
        run.state = shown >= chat.answer.count ? .done : .running
        return run
    }

    func cancelSideChat(cardId: String, runId: String) async throws {
        state.withLock { s in
            if !s.keptCatchUps.values.contains(where: { $0.run == runId }) { s.sideChats[runId] = nil }
        }
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
        let id = "\(idPrefix)task\(n)"
        let launch = request.launch ?? true
        let worktree = request.worktree.map { $0.isEmpty ? "wt-\(n)" : $0 }
        let card = RemoteCard(
            id: id, title: request.name ?? String(request.prompt.prefix(60)), column: launch ? .inProgress : .backlog,
            projectPath: project.path, projectName: project.name, branch: worktree.map { "demo/\($0)" },
            worktreePath: worktree.map { "\(project.path)/.claude/worktrees/\($0)" }, assistant: request.assistant ?? "claude",
            runtime: launch ? .tmux : .none, isLive: launch, isBusy: launch, sessionId: launch ? UUID().uuidString.lowercased() : nil,
            terminals: launch ? [RemoteTerminal(sessionName: "\(project.name)-\(id)", label: "claude", isPrimary: true)] : [],
            lastActivity: Date(), updatedAt: Date(), machineId: machine?.id, machineName: machine?.name
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
        if Self.slowSendCards.contains(cardId) { try? await Task.sleep(for: .seconds(4)) }
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
        if PromptImageLayout.marksEveryImage(text, imageCount: imageCount) { return text }
        let images = (0..<imageCount).map { "[Image #\($0 + 1)]" }.joined(separator: " ")
        return [images, text].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func deliver(_ cardId: String, text: String, interrupting: Bool) {
        update(cardId) { c in
            if interrupting {
                c.messages.append(RemoteMessage(id: "\(c.messages.count)", role: .system, text: "Interrupted", at: Date()))
            }
            c.messages.append(RemoteMessage(id: "\(c.messages.count)", role: .user, text: text, at: Date()))
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
        guard let socket = tmuxSocket, let tmux = ShellCommand.findExecutable("tmux") else { return }
        for command in RemoteTerminalScroll.tmuxCommands(session: sessionName, lines: lines) {
            _ = try? await ShellCommand.run(tmux, arguments: ["-L", socket] + command)
        }
    }

    func interrupt(cardId: String) async throws {
        let c = try cardState(cardId)
        guard c.card.isLive else { throw RemoteHostError.conflict("card \(cardId) has no live session") }
        update(cardId) { c in
            c.card.isBusy = false
            c.card.column = .waiting
            c.messages.append(RemoteMessage(id: "\(c.messages.count)", role: .system, text: "Interrupted", at: Date()))
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

    func updateCard(cardId: String, _ request: RemoteCardUpdate) async throws -> RemoteCard {
        _ = try cardState(cardId)
        update(cardId) { c in
            if let name = request.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { c.card.title = name }
            if let column = request.column {
                c.card.column = column
                c.card.archived = column == .allSessions
            }
            switch request.archived {
            case true?:
                c.card.archived = true
                c.card.column = .allSessions
                c.card.pinned = false
                c.card.isLive = false
                c.card.isBusy = false
                c.card.terminals = []
            case false? where c.card.archived:
                c.card.archived = false
                c.card.column = .backlog
            default: break
            }
            if let pinned = request.pinned {
                c.card.pinned = pinned
                if pinned, c.card.archived {
                    c.card.archived = false
                    c.card.column = .backlog
                }
            }
        }
        return try cardState(cardId).card
    }

    func deleteCard(cardId: String) async throws {
        guard try cardState(cardId).card.archived else {
            throw RemoteHostError.conflict("card \(cardId) is on the board; archive it before deleting it")
        }
        state.withLock { $0.cards.removeAll { $0.card.id == cardId } }
        notify()
    }

    func terminalCommand(cardId: String, sessionName: String) async throws -> [String] {
        let c = try cardState(cardId)
        guard c.card.isLive else { throw RemoteHostError.conflict("card \(cardId) has no live session") }
        if c.card.runtime == .rush, let id = c.rushId {
            return RushCliAdapter.openCommand(id: id)
        }
        if let socket = tmuxSocket {
            return ["tmux", "-L", socket, "-f", "/dev/null", "new-session", "-A", "-s", sessionName, "/bin/zsh", "-l"]
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
let host = DemoHost(rushId: options.rushId, tmuxSocket: options.tmuxSocket, machine: options.machine,
                    cards: options.cards, foreign: options.foreign)
let loopbackOnly = options.loopbackOnly
let bindAddresses: @Sendable () -> [String] = {
    loopbackOnly ? [RemoteNetworkAddresses.loopback] : RemoteNetworkAddresses.bindable()
}
let server = RemoteControlServer(
    host: host, devices: devices, port: options.port,
    bindAddresses: bindAddresses,
    options: .init(appVersion: "demo")
)

#if canImport(Darwin)
setvbuf(stdout, nil, _IOLBF, 0)
#endif
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
    let link = RemotePairLink.make(url: base, token: token, name: options.machine?.name ?? RemoteControlServer.defaultHostName)
    print("paired \(device.name) (\(device.scope.rawValue)), id \(device.id)")
    print("token: \(token)")
    print("pair link: \(link)")
    print("try: curl -H 'Authorization: Bearer \(token)' \(base)/v1/board")
}

// Serve until killed, or until the exit file shows up.
while true {
    if let exitWhen = options.exitWhen, FileManager.default.fileExists(atPath: exitWhen) {
        try? FileManager.default.removeItem(atPath: exitWhen)
        print("exit file found, exiting")
        exit(0)
    }
    try await Task.sleep(for: .milliseconds(options.exitWhen == nil ? 3_600_000 : 300))
}
