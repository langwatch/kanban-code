import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@_exported import enum KanbanCodeRemoteKit.CardOrigin
@_exported import struct KanbanCodeRemoteKit.RemoteLazeAgent

/// Which Laze agent listens in which assistant session on this machine.
///
/// The Laze CLI keeps its profiles in `~/.laze/config.json` (or
/// `LAZE_CLI_CONFIG`): `profiles` holds each agent's key, and `sessions`
/// maps a session key (`claude-code:<session id>`, `codex:<session id>`)
/// to the profile that `laze agent link` or `laze agent bind` bound there.
/// Laze itself says which session each agent listens in now
/// (`GET /api/agents/me`, its `session`), and how every agent of the
/// workspace looks (`GET /api/agents/faces`). The card of a session shows
/// the agent Laze binds to that session; when Laze cannot be reached, the
/// config's bindings stand in.
public enum LazeAgentDirectory {
    /// An agent profile of the Laze CLI that still holds a working key.
    public struct Profile: Sendable, Equatable {
        public var name: String
        public var url: String
        public var token: String
        public var agentId: String
        public var agentName: String
        public var workspaceId: String?
    }

    public struct Config: Sendable, Equatable {
        public var profiles: [Profile]
        /// Session id (without the harness prefix) → profile name.
        public var sessions: [String: String]
    }

    /// What `GET /api/agents/me` says about one agent.
    public struct Me: Sendable, Equatable {
        public var id: String
        public var name: String
        public var avatar: String
        /// The session Laze binds the agent to now; nil when none.
        public var sessionId: String?
    }

    /// One entry of `GET /api/agents/faces`.
    public struct Face: Sendable, Equatable {
        public var name: String
        public var seed: String?
        public var imageUrl: String?
        public var emoji: String?
    }

    /// The Laze CLI's config file.
    public static func configPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["LAZE_CLI_CONFIG"], !path.isEmpty { return path }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".laze/config.json")
    }

    /// The agent profiles and session bindings of a Laze CLI config.
    /// Profiles whose key Laze refused are left out.
    public static func parseConfig(_ data: Data) -> Config {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Config(profiles: [], sessions: [:])
        }
        var profiles: [Profile] = []
        for (name, value) in (root["profiles"] as? [String: Any]) ?? [:] {
            guard let profile = value as? [String: Any],
                  profile["kind"] as? String == "agent",
                  profile["refused"] == nil,
                  let token = profile["token"] as? String, !token.isEmpty,
                  let agentId = profile["agentId"] as? String, !agentId.isEmpty else { continue }
            profiles.append(Profile(
                name: name,
                url: (profile["url"] as? String) ?? "https://laze.so",
                token: token,
                agentId: agentId,
                agentName: (profile["name"] as? String) ?? name,
                workspaceId: profile["workspaceId"] as? String))
        }
        profiles.sort { $0.name < $1.name }
        var sessions: [String: String] = [:]
        for (key, value) in (root["sessions"] as? [String: Any]) ?? [:] {
            guard let profile = value as? String else { continue }
            sessions[sessionId(ofKey: key)] = profile
        }
        return Config(profiles: profiles, sessions: sessions)
    }

    /// `claude-code:8ef516fe-...` → `8ef516fe-...`.
    static func sessionId(ofKey key: String) -> String {
        guard let colon = key.firstIndex(of: ":") else { return key }
        return String(key[key.index(after: colon)...])
    }

    public static func parseMe(_ data: Data) -> Me? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["kind"] as? String == "agent",
              let id = root["id"] as? String else { return nil }
        let agent = root["agent"] as? [String: Any]
        let session = agent?["session"] as? [String: Any]
        return Me(
            id: id,
            name: (root["name"] as? String) ?? (agent?["name"] as? String) ?? id,
            avatar: (agent?["avatar"] as? String) ?? "",
            sessionId: session?["sessionId"] as? String)
    }

    /// Agent id → face, from `GET /api/agents/faces`.
    public static func parseFaces(_ data: Data) -> [String: Face] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var out: [String: Face] = [:]
        for entry in list {
            guard let id = entry["agentId"] as? String, entry["gone"] as? Bool != true else { continue }
            out[id] = Face(
                name: (entry["name"] as? String) ?? id,
                seed: entry["seed"] as? String,
                imageUrl: (entry["imageUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                emoji: (entry["emoji"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return out
    }

    /// The face a stored avatar (`sloth:<seed>`, `animals:<seed>`,
    /// `emoji:<emoji>`, `file:<id>`) draws when the faces list is missing.
    static func look(avatar: String, agentId: String) -> (seed: String, emoji: String?) {
        if avatar.hasPrefix("emoji:") {
            let emoji = String(avatar.dropFirst("emoji:".count))
            return (agentId, emoji.isEmpty ? nil : emoji)
        }
        for roster in ["sloth:", "animals:"] where avatar.hasPrefix(roster) {
            let seed = String(avatar.dropFirst(roster.count))
            if !seed.isEmpty { return (seed, nil) }
        }
        return (agentId, nil)
    }

    /// Session id → the agent that listens there.
    ///
    /// `me` holds Laze's answer for each profile that got one: the session
    /// it names is the agent's, and the config's older bindings for that
    /// profile are dropped. A profile Laze did not answer for keeps the
    /// config's bindings.
    public static func resolve(config: Config, me: [String: Me], faces: [String: Face]) -> [String: RemoteLazeAgent] {
        let byName = Dictionary(config.profiles.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        func agent(_ profile: Profile) -> RemoteLazeAgent {
            let answer = me[profile.name]
            if let face = faces[profile.agentId] {
                return RemoteLazeAgent(
                    id: profile.agentId, name: face.name, faceSeed: face.seed,
                    imageUrl: face.imageUrl, emoji: face.emoji)
            }
            let look = look(avatar: answer?.avatar ?? "", agentId: profile.agentId)
            return RemoteLazeAgent(
                id: profile.agentId, name: answer?.name ?? profile.agentName,
                faceSeed: look.seed, emoji: look.emoji)
        }
        var out: [String: RemoteLazeAgent] = [:]
        for (sessionId, name) in config.sessions where me[name] == nil {
            if let profile = byName[name] { out[sessionId] = agent(profile) }
        }
        for profile in config.profiles {
            guard let sessionId = me[profile.name]?.sessionId else { continue }
            out[sessionId] = agent(profile)
        }
        return out
    }

    public typealias Fetch = @Sendable (URLRequest) async -> Data?

    /// Asks Laze about every agent profile of the config at `path`.
    /// Returns nil when there is no Laze config here.
    public static func load(path: String = configPath(), fetch: @escaping Fetch = defaultFetch) async -> [String: RemoteLazeAgent]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let config = parseConfig(data)
        guard !config.profiles.isEmpty else { return [:] }
        let answers = await withTaskGroup(of: (String, Me?).self) { group in
            for profile in config.profiles {
                group.addTask { (profile.name, await fetchMe(profile, fetch: fetch)) }
            }
            var out: [String: Me] = [:]
            for await (name, answer) in group { if let answer { out[name] = answer } }
            return out
        }
        // One faces list per workspace, asked with any of its agents' keys.
        var askers: [String: Profile] = [:]
        for profile in config.profiles {
            let base = profile.url.hasSuffix("/") ? String(profile.url.dropLast()) : profile.url
            let workspace = "\(base)|\(profile.workspaceId ?? profile.name)"
            if askers[workspace] == nil { askers[workspace] = profile }
        }
        let faces = await withTaskGroup(of: [String: Face].self) { group in
            for profile in askers.values {
                group.addTask {
                    guard let request = request(profile, path: "/api/agents/faces"),
                          let data = await fetch(request) else { return [:] }
                    return parseFaces(data)
                }
            }
            var out: [String: Face] = [:]
            for await part in group { out.merge(part) { a, _ in a } }
            return out
        }
        return resolve(config: config, me: answers, faces: faces)
    }

    private static func fetchMe(_ profile: Profile, fetch: @escaping Fetch) async -> Me? {
        guard let request = request(profile, path: "/api/agents/me"), let data = await fetch(request) else { return nil }
        return parseMe(data)
    }

    static func request(_ profile: Profile, path: String) -> URLRequest? {
        let base = profile.url.hasSuffix("/") ? String(profile.url.dropLast()) : profile.url
        guard let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(profile.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static let defaultFetch: Fetch = { request in
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }
}
