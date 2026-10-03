import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanbanCodeRemoteKit

/// Where a mirror of a machine's audit log stands.
public struct VaultAuditMirrorTail: Codable, Sendable, Equatable {
    public var count: Int
    public var lastHash: String?

    public init(count: Int, lastHash: String?) {
        self.count = count
        self.lastHash = lastHash
    }
}

/// Body of `POST /v1/vault/audit/mirror`: lines of the sender's audit log,
/// exactly as written.
public struct VaultAuditMirrorPush: Codable, Sendable, Equatable {
    public var machine: String
    public var lines: [String]

    public init(machine: String, lines: [String]) {
        self.machine = machine
        self.lines = lines
    }
}

/// Body of `GET /v1/vault/audit/hashes`: the hash of every line of this
/// machine's audit log, oldest first.
public struct VaultAuditHashes: Codable, Sendable, Equatable {
    public var machine: String
    public var hashes: [String]
}

/// What `kv audit check` reports.
public struct VaultAuditReport: Codable, Sendable, Equatable {
    public struct Log: Codable, Sendable, Equatable {
        /// "this machine", "mirror of <machine>", "device approvals".
        public var name: String
        public var lines: Int
        public var unchained: Int
        /// Line numbers where the chain breaks.
        public var breaks: [Int]
    }

    public struct Missing: Codable, Sendable, Equatable {
        public var machine: String
        /// Lines the mirror here holds that the machine's own log no longer has.
        public var count: Int
        /// The first few, as written.
        public var samples: [String]
        /// Lines of the machine's log not mirrored here yet.
        public var notMirroredYet: Int
    }

    public var machine: String
    public var logs: [Log]
    public var missing: [Missing]
    /// Approvals the log says were given on this device, with no record of
    /// them on the device itself.
    public var unrecordedApprovals: [String]
    /// What could not be checked, e.g. a peer that did not answer.
    public var notes: [String]

    public var ok: Bool {
        logs.allSatisfy { $0.breaks.isEmpty } && missing.allSatisfy { $0.count == 0 } && unrecordedApprovals.isEmpty
    }
}

/// Pushes every line of this machine's audit log to the peer masters, as
/// written, and checks the logs against each other.
public actor VaultAuditSync {
    public let store: VaultStore
    public let machine: String
    public let peers: @Sendable () async -> [PeerConfig]
    /// The record this device keeps of the approvals answered on it, and
    /// the name the audit log gives that device ("mac").
    public let deviceApprovals: (log: VaultDeviceApprovals, name: String)?
    public var interval: TimeInterval = 60
    public var batch = 400
    private var wake: CheckedContinuation<Void, Never>?
    private var dirty = false

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)
    private let fetch: Fetch

    public init(store: VaultStore, machine: String, peers: @escaping @Sendable () async -> [PeerConfig],
                deviceApprovals: (log: VaultDeviceApprovals, name: String)? = nil,
                fetch: @escaping Fetch = { request in
                    let (data, response) = try await URLSession.shared.data(for: request)
                    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
                }) {
        self.store = store
        self.machine = machine
        self.peers = peers
        self.deviceApprovals = deviceApprovals
        self.fetch = fetch
    }

    public func run() async {
        while !Task.isCancelled {
            dirty = false
            await pushAll()
            if dirty { continue }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                wake = c
                let seconds = interval
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    self.fire()
                }
            }
        }
    }

    /// A line was written: push it now.
    public func poke() {
        dirty = true
        fire()
    }

    private func fire() {
        wake?.resume()
        wake = nil
    }

    private func request(_ peer: PeerConfig, _ method: String, _ path: String, body: Data? = nil) -> URLRequest? {
        guard let url = URL(string: peer.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/vault/" + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(peer.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    public func pushAll() async {
        for peer in await peers() where peer.enabled {
            await push(to: peer)
        }
    }

    /// Sends the lines the peer's mirror does not have yet: everything
    /// after the mirror's last line, or the whole log when that line is
    /// not in it.
    func push(to peer: PeerConfig) async {
        let name = machine.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? machine
        guard let get = request(peer, "GET", "audit/mirror?machine=\(name)") else { return }
        do {
            let (data, status) = try await fetch(get)
            guard status == 200 else { return }
            var tail = try JSONDecoder().decode(VaultAuditMirrorTail.self, from: data)
            let lines = await store.auditLines()
            var start = 0
            if let last = tail.lastHash, let at = lines.lastIndex(where: { AuditChain.hash($0) == last }) { start = at + 1 }
            while start < lines.count {
                let chunk = lines[start..<min(start + batch, lines.count)].map { String(decoding: $0, as: UTF8.self) }
                let body = try JSONEncoder().encode(VaultAuditMirrorPush(machine: machine, lines: chunk))
                guard let post = request(peer, "POST", "audit/mirror", body: body) else { return }
                let (answer, code) = try await fetch(post)
                guard code == 200 else { return }
                tail = try JSONDecoder().decode(VaultAuditMirrorTail.self, from: answer)
                start += chunk.count
            }
        } catch {
            KanbanCodeLog.debug("vault", "audit push to \(peer.name) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Check

    public func check() async -> VaultAuditReport {
        var report = VaultAuditReport(machine: machine, logs: [], missing: [], unrecordedApprovals: [], notes: [])
        let own = await store.auditLines()
        report.logs.append(Self.log("this machine (\(machine))", own))

        var peerByMachine: [String: PeerConfig] = [:]
        var peerHashes: [String: [String]] = [:]
        for peer in await peers() where peer.enabled {
            guard let get = request(peer, "GET", "audit/hashes") else { continue }
            do {
                let (data, status) = try await fetch(get)
                guard status == 200 else {
                    report.notes.append("\(peer.name) answered HTTP \(status) for its log; it was not compared")
                    continue
                }
                let hashes = try JSONDecoder().decode(VaultAuditHashes.self, from: data)
                peerByMachine[hashes.machine] = peer
                peerHashes[VaultStore.mirrorFileName(hashes.machine)] = hashes.hashes
            } catch {
                report.notes.append("\(peer.name) did not answer; its log was not compared")
            }
        }

        var mirrored: [(machine: String, lines: [Data])] = []
        for mirror in await store.mirroredMachines() {
            let lines = await store.mirrorLines(machine: mirror)
            mirrored.append((mirror, lines))
            report.logs.append(Self.log("mirror of \(mirror)", lines))
            guard let theirs = peerHashes[VaultStore.mirrorFileName(mirror)] else {
                report.notes.append("no answer from \(mirror); its mirror here was only checked against itself")
                continue
            }
            let current = Set(theirs)
            let mine = Set(lines.map(AuditChain.hash))
            let gone = lines.filter { !current.contains(AuditChain.hash($0)) }
            report.missing.append(.init(machine: mirror, count: gone.count,
                                        samples: gone.prefix(5).map { String(decoding: $0, as: UTF8.self) },
                                        notMirroredYet: theirs.filter { !mine.contains($0) }.count))
        }

        if let deviceApprovals {
            let recorded = deviceApprovals.log.requestIds()
            let chain = deviceApprovals.log.report()
            report.logs.append(.init(name: "device approvals", lines: chain.lines, unchained: chain.unchained, breaks: chain.breaks))
            let since = deviceApprovals.log.entries(limit: .max).last.flatMap { VaultDates.parse($0.at) }
            if let since {
                let suffix = "by \(deviceApprovals.name)"
                for lines in [own] + mirrored.map(\.lines) {
                    for line in lines {
                        guard let e = try? JSONDecoder.vault.decode(VaultAuditEntry.self, from: line), e.decider == .human,
                              e.outcome == .allowed, e.at > since, let id = e.requestId,
                              let detail = e.detail, detail.contains(suffix), !recorded.contains(id) else { continue }
                        report.unrecordedApprovals.append("\(VaultDates.format(e.at)) \(e.machine) \(e.secret) (\(id))")
                    }
                }
            }
        }
        return report
    }

    static func log(_ name: String, _ lines: [Data]) -> VaultAuditReport.Log {
        let r = AuditChain.verify(lines)
        return .init(name: name, lines: r.lines, unchained: r.unchained, breaks: r.breaks)
    }
}
