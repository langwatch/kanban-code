import Foundation

/// A process as `ps` lists it.
public struct VaultProcess: Sendable, Equatable {
    public var pid: Int
    public var ppid: Int
    public var name: String

    public init(pid: Int, ppid: Int, name: String) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
    }
}

/// Finds which card session a local process runs in, from the process
/// table and the pids the card sessions own: tmux pane shells and the
/// assistants rush hosts. A process whose ancestry reaches none of them
/// is outside every card, whatever it claims.
public enum VaultCallerResolver {
    /// The chain from `pid` up to init (or a cycle), the caller first.
    public static func ancestry(of pid: Int, in table: [Int: VaultProcess], limit: Int = 128) -> [VaultProcess] {
        var out: [VaultProcess] = []
        var seen = Set<Int>()
        var current = pid
        while let p = table[current], !seen.contains(current), out.count < limit {
            out.append(p)
            seen.insert(current)
            if p.ppid <= 1 || p.ppid == current { break }
            current = p.ppid
        }
        return out
    }

    /// The card of the nearest ancestor that a card session owns.
    public static func card(for pid: Int, table: [Int: VaultProcess], sessionPids: [Int: String]) -> String? {
        for p in ancestry(of: pid, in: table) {
            if let card = sessionPids[p.pid] { return card }
        }
        return nil
    }

    /// Pid -> card for the rush hosts of cards. The card comes from
    /// Kanban's links (the card whose terminal is `rush-<id>`, or
    /// `agtop-<id>` from before the rename), whoever
    /// started the host; the host's own `--meta kanban_card`, which any
    /// process can set, is never read.
    public static func rushCards(hosts: [RushSessionInfo], sessions: [String: String]) -> [Int: String] {
        var out: [Int: String] = [:]
        for host in hosts where host.alive {
            guard let card = RushSessionName.names(rushId: host.id).lazy.compactMap({ sessions[$0] }).first
            else { continue }
            if let pid = host.claudePid { out[pid] = card }
            if let pid = host.hostPid { out[pid] = card }
        }
        return out
    }

    public static func parsePS(_ output: String) -> [Int: VaultProcess] {
        var table: [Int: VaultProcess] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            let name = parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .whitespaces) : ""
            table[pid] = VaultProcess(pid: pid, ppid: ppid, name: (name as NSString).lastPathComponent)
        }
        return table
    }

    /// `pane_pid<TAB>session_name` lines of `tmux list-panes -a`.
    public static func parsePanes(_ output: String) -> [(pid: Int, session: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let pid = Int(parts[0]) else { return nil }
            return (pid, String(parts[1]))
        }
    }

    /// The pid of the process on the other end of a loopback TCP
    /// connection whose client port is `port`, never `exclude` (the server).
    public static func peerPid(clientPort port: Int, serverPort: Int, exclude: Int32 = getpid()) async -> Int? {
        #if os(Linux)
        return linuxPeerPid(clientPort: port, serverPort: serverPort, exclude: Int(exclude))
        #else
        guard let lsof = ShellCommand.findExecutable("lsof") ?? Optional("/usr/sbin/lsof"),
              let result = try? await ShellCommand.run(lsof, arguments: ["-nP", "-iTCP@127.0.0.1:\(port)", "-iTCP@[::1]:\(port)", "-Fpn"])
        else { return nil }
        var pid: Int?
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") {
                pid = Int(line.dropFirst())
            } else if line.hasPrefix("n"), let candidate = pid, candidate != Int(exclude) {
                // The client end lists its own port first: 127.0.0.1:<port>->127.0.0.1:<server>.
                let name = line.dropFirst()
                if name.hasPrefix("127.0.0.1:\(port)->") || name.hasPrefix("[::1]:\(port)->") {
                    return candidate
                }
            }
        }
        return nil
        #endif
    }

    #if os(Linux)
    static func linuxPeerPid(clientPort: Int, serverPort: Int, exclude: Int) -> Int? {
        var inodes = Set<String>()
        for table in ["/proc/net/tcp", "/proc/net/tcp6"] {
            guard let text = VaultCallerResolver.readProcFile(table) else { continue }
            for line in text.split(whereSeparator: \.isNewline).dropFirst() {
                let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                guard cols.count > 9 else { continue }
                let local = cols[1].split(separator: ":"), remote = cols[2].split(separator: ":")
                guard let lp = local.last.flatMap({ Int($0, radix: 16) }),
                      let rp = remote.last.flatMap({ Int($0, radix: 16) }),
                      lp == clientPort, rp == serverPort else { continue }
                inodes.insert(String(cols[9]))
            }
        }
        guard !inodes.isEmpty, let pids = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
        for entry in pids {
            guard let pid = Int(entry), pid != exclude,
                  let fds = try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(pid)/fd") else { continue }
            for fd in fds {
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/fd/\(fd)"),
                      target.hasPrefix("socket:[") else { continue }
                let inode = String(target.dropFirst(8).dropLast())
                if inodes.contains(inode) { return pid }
            }
        }
        return nil
    }
    #endif

    /// Reads a file to its end with read(2). /proc files report a size of
    /// zero, and Foundation's file readers trust the size, so they come
    /// back empty there.
    public static func readProcFile(_ path: String) -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(buffer, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The working directory of a local process, as the system reports it.
    public static func workingDirectory(of pid: Int) async -> String? {
        #if os(Linux)
        return OpenClawLayout.procCwd(pid)
        #else
        guard let lsof = ShellCommand.findExecutable("lsof") ?? Optional("/usr/sbin/lsof"),
              let result = try? await ShellCommand.run(lsof, arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        else { return nil }
        return parseLsofCwd(result.stdout)
        #endif
    }

    /// The `n<path>` line of `lsof -d cwd -Fn`.
    public static func parseLsofCwd(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
    }

    public static func processTable() async -> [Int: VaultProcess] {
        let ps = ShellCommand.findExecutable("ps") ?? "/bin/ps"
        guard let result = try? await ShellCommand.run(ps, arguments: ["-A", "-o", "pid=", "-o", "ppid=", "-o", "comm="]) else {
            return [:]
        }
        return parsePS(result.stdout)
    }

    /// The command lines of `pids`, in that order, each cut to `limit`
    /// characters. A process that is gone is left out.
    public static func commandLines(of pids: [Int], limit: Int = 300) async -> [String] {
        guard !pids.isEmpty else { return [] }
        let ps = ShellCommand.findExecutable("ps") ?? "/bin/ps"
        guard let result = try? await ShellCommand.run(
            ps, arguments: ["-ww", "-o", "pid=", "-o", "args=", "-p", pids.map(String.init).joined(separator: ",")])
        else { return [] }
        return parseCommandLines(result.stdout, order: pids, limit: limit)
    }

    /// `pid args` lines of `ps -o pid= -o args=`, in the order of `order`.
    public static func parseCommandLines(_ output: String, order: [Int], limit: Int = 300) -> [String] {
        var byPid: [Int: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let args = parts[1].trimmingCharacters(in: .whitespaces)
            byPid[pid] = args.count > limit ? String(args.prefix(limit)) + "..." : args
        }
        return order.compactMap { byPid[$0] }
    }

    /// Pane pid -> session name of the local tmux server.
    public static func tmuxPanes() async -> [(pid: Int, session: String)] {
        guard let tmux = ShellCommand.findExecutable("tmux"),
              let result = try? await ShellCommand.run(tmux, arguments: ["list-panes", "-a", "-F", "#{pane_pid}\t#{session_name}"])
        else { return [] }
        return parsePanes(result.stdout)
    }
}

/// OpenClaw on this machine, from `~/.openclaw/openclaw.json`: the systemd
/// unit its gateway runs in and each agent's workspace.
public struct OpenClawLayout: Sendable, Equatable {
    public static let defaultUnit = "openclaw-gateway.service"

    public var unit: String
    /// Agent id -> workspace directory.
    public var workspaces: [String: String]
    /// Agent id -> display name.
    public var names: [String: String]

    public init(unit: String = OpenClawLayout.defaultUnit, workspaces: [String: String], names: [String: String] = [:]) {
        self.unit = unit
        self.workspaces = workspaces
        self.names = names
    }

    public static func load(home: String = NSHomeDirectory()) -> OpenClawLayout? {
        let path = (home as NSString).appendingPathComponent(".openclaw/openclaw.json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(data, home: home)
    }

    public static func parse(_ data: Data, home: String) -> OpenClawLayout? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agents = root["agents"] as? [String: Any] else { return nil }
        let defaults = agents["defaults"] as? [String: Any]
        var workspaces: [String: String] = [:]
        var names: [String: String] = [:]
        for (id, value) in agents["entries"] as? [String: Any] ?? [:] {
            guard let entry = value as? [String: Any] else { continue }
            let workspace = entry["workspace"] as? String
                ?? (id == "main" ? defaults?["workspace"] as? String : nil)
                ?? "\(home)/.openclaw/workspace-\(id)"
            workspaces[id] = (workspace as NSString).expandingTildeInPath
            names[id] = (entry["identity"] as? [String: Any])?["name"] as? String ?? entry["name"] as? String
        }
        return OpenClawLayout(workspaces: workspaces, names: names)
    }

    /// The agent whose workspace holds `cwd`, the deepest workspace first.
    public func agent(forCwd cwd: String) -> String? {
        let sorted = workspaces.sorted { $0.value.count > $1.value.count }
        return sorted.first { cwd == $0.value || cwd.hasPrefix($0.value + "/") }?.key
    }

    /// The principal of a caller whose process chain (the caller first)
    /// runs under the OpenClaw gateway's systemd unit: "openclaw:<agent>"
    /// for the agent process the gateway started (found by its working
    /// directory, which its children cannot change), "openclaw:gateway"
    /// for the gateway itself. Nil when no process of the chain is in the
    /// unit. The unit's cgroup is set by systemd, not by the process.
    public func principal(chain: [VaultProcess], cgroup: (Int) -> String?, cwd: (Int) -> String?) -> String? {
        guard let top = chain.lastIndex(where: { cgroup($0.pid)?.hasSuffix("/" + unit) == true }) else { return nil }
        var i = top - 1
        while i >= 0 {
            if let dir = cwd(chain[i].pid), let agent = agent(forCwd: dir) {
                return VaultCaller.openClawPrincipal(agent: agent)
            }
            i -= 1
        }
        return VaultCaller.openClawPrincipal(agent: "gateway")
    }

    public static func procCgroup(_ pid: Int) -> String? {
        guard let text = VaultCallerResolver.readProcFile("/proc/\(pid)/cgroup") else { return nil }
        // cgroup v2: "0::/user.slice/.../openclaw-gateway.service"
        return text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("0::") }.map { String($0.dropFirst(3)) }
    }

    public static func procCwd(_ pid: Int) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd")
    }
}

/// Resolves callers against the live board: the cards' tmux sessions and
/// the rush hosts of this machine.
public struct LiveVaultCallerResolver: Sendable {
    /// Session name -> card id, for every local card terminal.
    public let cardSessions: @Sendable () async -> [String: String]
    public let rush: RushCliAdapter?
    /// The session tokens of this master's cards; nil where none are issued.
    public let tokens: VaultCardTokens?
    /// Asks the paired masters about a token this one did not issue.
    public let peerTokens: VaultPeerTokenVerifier?

    public init(rush: RushCliAdapter? = RushCliAdapter(), tokens: VaultCardTokens? = nil,
                peerTokens: VaultPeerTokenVerifier? = nil,
                cardSessions: @escaping @Sendable () async -> [String: String]) {
        self.cardSessions = cardSessions
        self.rush = rush
        self.tokens = tokens
        self.peerTokens = peerTokens
    }

    /// The card a peer master vouches for, for a token this master does
    /// not know: a card there whose command runs here.
    public func peerCard(forToken token: String?) async -> VaultPeerCard? {
        guard let peerTokens, let token, !token.isEmpty else { return nil }
        return await peerTokens.verify(token: token)
    }

    /// The card of a caller the process ancestry did not place: the one
    /// its session token belongs to, when that card still has a session.
    public func card(forToken token: String?) async -> String? {
        guard let tokens, let token, !token.isEmpty else { return nil }
        return await tokens.verify(token, liveCards: Set(await cardSessions().values))
    }

    /// Pid -> card for every process a card session owns.
    public func sessionPids() async -> [Int: String] {
        let sessions = await cardSessions()
        var panes: [Int: String] = [:]
        for pane in await VaultCallerResolver.tmuxPanes() {
            if let card = sessions[pane.session] { panes[pane.pid] = card }
        }
        var out = panes
        if let rush, rush.isAvailable, let hosts = try? await rush.list() {
            out.merge(VaultCallerResolver.rushCards(hosts: hosts, sessions: sessions)) { pane, _ in pane }
        }
        return out
    }

    public func resolve(clientPort: Int, serverPort: Int, claimedCardId: String?, sessionId: String?,
                        cardToken: String? = nil) async -> VaultCaller {
        guard let pid = await VaultCallerResolver.peerPid(clientPort: clientPort, serverPort: serverPort) else {
            KanbanCodeLog.warn("vault", "no local process found for the connection from port \(clientPort) to \(serverPort)")
            if let card = await card(forToken: cardToken) {
                return VaultCaller(cardId: card, claimedCardId: claimedCardId, sessionId: sessionId, byToken: true)
            }
            let peer = await peerCard(forToken: cardToken)
            return VaultCaller(cardId: peer?.cardId, claimedCardId: claimedCardId, sessionId: sessionId,
                               byToken: peer == nil ? nil : true, verifiedByPeer: peer?.machine, peerTitle: peer?.title)
        }
        let table = await VaultCallerResolver.processTable()
        let chain = VaultCallerResolver.ancestry(of: pid, in: table)
        if chain.isEmpty {
            KanbanCodeLog.warn("vault", "caller pid \(pid) is not in the process table (\(table.count) processes)")
        }
        var card = VaultCallerResolver.card(for: pid, table: table, sessionPids: await sessionPids())
        #if os(Linux)
        if card == nil, let openClaw = OpenClawLayout.load() {
            card = openClaw.principal(chain: chain, cgroup: OpenClawLayout.procCgroup, cwd: OpenClawLayout.procCwd)
            if let card { KanbanCodeLog.info("vault", "caller pid \(pid) is \(card)") }
        }
        #endif
        var byToken: Bool?
        if card == nil, let found = await self.card(forToken: cardToken) {
            card = found
            byToken = true
            KanbanCodeLog.info("vault", "caller pid \(pid) is outside every session tree; its session token is card \(found.prefix(12))'s")
        }
        var peer: VaultPeerCard?
        if card == nil, let found = await peerCard(forToken: cardToken) {
            card = found.cardId
            byToken = true
            peer = found
            KanbanCodeLog.info("vault", "caller pid \(pid) carries the session token of card \(found.cardId.prefix(12)) on \(found.machine)")
        }
        // A caller outside every card has no card to name it: its command
        // lines say what it is.
        let commandLines = card == nil
            ? await VaultCallerResolver.commandLines(of: chain.prefix(5).map(\.pid))
            : []
        return VaultCaller(
            cardId: card, claimedCardId: claimedCardId, sessionId: sessionId, pid: pid,
            ancestry: chain.map(\.name), cwd: await VaultCallerResolver.workingDirectory(of: pid), byToken: byToken,
            verifiedByPeer: peer?.machine, peerTitle: peer?.title, commandLines: commandLines.isEmpty ? nil : commandLines
        )
    }
}
