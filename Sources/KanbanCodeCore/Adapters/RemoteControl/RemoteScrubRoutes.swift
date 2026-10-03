import Foundation
import KanbanCodeRemoteKit

/// The scrubber routes of the Remote Control server (docs/vault.md, "Scrubber"):
///
///   GET  /v1/scrub/status     schedule, whether a run is in progress, the last run and dry run
///   POST /v1/scrub/run        {"dryRun": true|false}: starts a run, 202; 409 while one runs
///   PUT  /v1/scrub/schedule   {"enabled", "hour", "minute"}
///   GET  /v1/scrub/index      the fingerprint index, for a peer master (never a value)
///   POST /v1/scrub/restore    {"paths": [...]} or {"all": true}: writes back what the runs of the
///                             last week replaced. Local callers and full scope devices only.
///
/// For local callers (no token, as `kv scrub` calls them) and for devices
/// of the full and peer scopes. Answers carry names, paths and counts only.
enum RemoteScrubRoutes {
    static func handle(method: String, rest: [String], body: Data, device: RemoteDevice?, scrubber: SecretScrubber) async -> RemoteHTTPResponse? {
        guard rest.first == "scrub" else { return nil }
        if let device, device.scope != .full, device.scope != .peer {
            return .error(403, "the \(device.scope.rawValue) scope cannot use the scrubber")
        }
        switch (method, rest.dropFirst().first, rest.count) {
        case ("GET", "status", 2):
            return .json(await scrubber.status())

        case ("GET", "index", 2):
            // Fingerprints only, and only for a paired master or a device of the human.
            guard device != nil, let data = await scrubber.exportIndex() else {
                return .error(403, "the index is for peer masters")
            }
            return .rawJSON(data)

        case ("POST", "run", 2):
            struct Run: Decodable { var dryRun: Bool? }
            let dryRun = (try? JSONDecoder().decode(Run.self, from: body))?.dryRun ?? false
            guard await scrubber.start(dryRun: dryRun) else { return .error(409, "a run is in progress") }
            return .json(await scrubber.status(), status: 202)

        case ("POST", "restore", 2):
            struct Restore: Decodable { var paths: [String]?; var all: Bool? }
            struct Restored: Encodable { var files: Int; var errors: [String] }
            if let device, device.scope != .full { return .error(403, "the \(device.scope.rawValue) scope cannot restore files") }
            guard let wanted = try? JSONDecoder().decode(Restore.self, from: body),
                  wanted.all == true || !(wanted.paths ?? []).isEmpty else {
                return .error(400, "body must be {\"paths\": [...]} or {\"all\": true}")
            }
            let result = await scrubber.restore(paths: wanted.all == true ? nil : wanted.paths)
            return .json(Restored(files: result.files, errors: result.errors))

        case ("PUT", "schedule", 2):
            guard let schedule = try? JSONDecoder().decode(ScrubSchedule.self, from: body) else {
                return .error(400, "body must be {\"enabled\", \"hour\", \"minute\"}")
            }
            // A schedule that came over the network is not sent on again.
            await scrubber.setSchedule(schedule, share: device == nil)
            return .json(await scrubber.status())

        default:
            return .error(404, "no scrub route \(method) /v1/\(rest.joined(separator: "/"))")
        }
    }
}
