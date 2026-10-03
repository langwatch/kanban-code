import Foundation
import KanbanCodeRemoteKit

/// The vault routes of the Remote Control server (docs/vault.md):
///
///   POST   /v1/vault/release           secrets for a command: granted, pending or denied
///   POST   /v1/vault/resolve           the same body: which secret each name or variable gets, no values
///   GET    /v1/vault/pending/{id}      the outcome of a pending request
///   POST   /v1/vault/request           a card lease, with a reason
///   POST   /v1/vault/aws               short-lived AWS credentials for a profile
///   GET    /v1/vault/secrets           names, tiers and rules, never values (?project=X for one project)
///   POST   /v1/vault/secrets           add a secret (replacing one asks the human)
///   PATCH  /v1/vault/secrets           one change to several secrets, in one approval
///   PATCH  /v1/vault/secrets/{name}    tier, rules, tags (asks the human)
///   DELETE /v1/vault/secrets/{name}    (asks the human)
///   POST   /v1/vault/delete            several secrets deleted in one approval (dryRun: what it would do)
///   POST   /v1/vault/rename            new names for several secrets, in one approval (dryRun: what it would do)
///   GET    /v1/vault/project           the vault projects of ?dir=, the most specific first
///   GET    /v1/vault/log               the audit log, newest first
///   GET    /v1/vault/leases            active leases
///   GET    /v1/vault/status
///   POST   /v1/vault/card-token        the card of a session token's hash (peer masters)
///   GET    /v1/vault/replica           the encrypted file (peer masters)
///   POST   /v1/vault/replica           merge a peer's encrypted file (peer masters)
///   GET    /v1/vault/owner             the keys of the owner-only secrets, and how many are sealed
///   POST   /v1/vault/owner/enrol       one more device key (asks the human on an enrolled device)
///   GET    /v1/vault/audit/check       chain and mirror check of the audit logs
///   GET    /v1/vault/audit/hashes      the hash of every line of this machine's log (peer masters)
///   GET    /v1/vault/audit/mirror      where the mirror of ?machine= stands here (peer masters)
///   POST   /v1/vault/audit/mirror      add a peer's audit lines to its mirror here (peer masters, add only)
///
/// Loopback callers need no token: the master finds the calling process
/// and the card session it runs in, or takes the card of the session token
/// in `X-Kanban-Card-Token` when the process left its session's tree. Callers over the network are never
/// inside a card session, so everything they ask goes to the human.
enum RemoteVaultRoutes {
    static func handle(
        method: String,
        rest: [String],
        query: [String: String],
        body: Data,
        device: RemoteDevice?,
        peer: RemotePeerAddress?,
        serverPort: Int,
        vault: VaultService,
        cardToken: String? = nil
    ) async -> RemoteHTTPResponse? {
        guard rest.first == "vault" else { return nil }
        let path = Array(rest.dropFirst())
        let loopback = peer?.isLoopback ?? false

        func caller(claimedCard: String?, sessionId: String?) async -> VaultCaller {
            guard loopback, let peer else {
                return VaultCaller(claimedCardId: claimedCard, sessionId: sessionId, remoteDevice: device?.name ?? "unknown")
            }
            return await vault.resolver.resolve(clientPort: peer.port, serverPort: serverPort, claimedCardId: claimedCard,
                                                sessionId: sessionId, cardToken: cardToken)
        }

        func respond(_ r: VaultResponse) -> RemoteHTTPResponse {
            switch r.status {
            case .granted: return .json(r)
            case .pending: return .json(r, status: 202)
            case .denied: return .json(r, status: 403)
            }
        }

        func decode<T: Decodable>(_ type: T.Type) -> T? {
            try? JSONDecoder.vault.decode(type, from: body)
        }

        switch (method, path.first, path.count) {
        case ("POST", "release", 1):
            guard let req = decode(VaultReleaseRequest.self) else {
                return .error(400, "body must be {\"mode\", \"names\": [...], \"command\", \"reason\", \"cwd\", \"cardId\"}")
            }
            let who = await caller(claimedCard: req.cardId, sessionId: req.sessionId)
            return respond(await vault.broker.release(req, caller: who))

        case ("POST", "resolve", 1):
            guard let req = decode(VaultReleaseRequest.self) else {
                return .error(400, "body must be {\"names\": [...], \"keys\": [...], \"group\", \"dir\", \"environment\"}")
            }
            return respond(await vault.broker.resolve(req))

        case ("POST", "rename", 1):
            guard let req = decode(VaultRenameRequest.self) else {
                return .error(400, "body must be {\"renames\": [{\"from\", \"to\"}], \"reason\", \"dryRun\"}")
            }
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            let r = await vault.broker.rename(req, caller: who, trusted: false)
            await vault.replica?.poke()
            return respond(r)

        case ("POST", "delete", 1):
            guard let req = decode(VaultDeleteRequest.self) else {
                return .error(400, "body must be {\"names\": [...], \"reason\", \"dryRun\"}")
            }
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            let r = await vault.broker.deleteMany(req, caller: who, trusted: false)
            await vault.replica?.poke()
            return respond(r)

        case ("GET", "project", 1):
            return .json(["projects": await vault.broker.projectsOf(query["dir"])])

        case ("GET", "pending", 2):
            return respond(await vault.broker.poll(id: path[1]))

        case ("POST", "request", 1):
            guard let req = decode(VaultLeaseRequest.self), !req.reason.isEmpty else {
                return .error(400, "body must be {\"names\": [...], \"reason\": \"...\"}")
            }
            let who = await caller(claimedCard: req.cardId, sessionId: req.sessionId)
            return respond(await vault.broker.requestLease(req, caller: who))

        case ("POST", "aws", 1):
            guard var req = decode(VaultReleaseRequest.self), let profile = req.names.first else {
                return .error(400, "body must be {\"names\": [\"<profile>\"], \"command\"}")
            }
            req.mode = "aws"
            req.names = [profile.hasPrefix("aws:") ? profile : "aws:\(profile)"]
            let who = await caller(claimedCard: req.cardId, sessionId: req.sessionId)
            return respond(await vault.broker.release(req, caller: who))

        case ("GET", "secrets", 1):
            do {
                return .json(try await vault.store.list(project: query["project"].flatMap { $0.isEmpty ? nil : $0 }))
            } catch {
                return .error(423, "\(error)")
            }

        case ("POST", "secrets", 1):
            guard let req = decode(VaultAddRequest.self) else {
                return .error(400, "body must be {\"name\", \"value\", \"tier\", \"rules\", \"tags\", \"project\", \"environment\"}")
            }
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            let r = await vault.broker.add(req, caller: who, trusted: false)
            await vault.replica?.poke()
            return respond(r)

        case ("PATCH", "secrets", 1):
            guard let req = decode(VaultBatchEditRequest.self) else {
                return .error(400, "body must be {\"names\": [...], \"valuePrefixes\": [...], \"edit\": {\"tier\", \"leasePolicy\", \"reason\"}}")
            }
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            return respond(await vault.broker.editMany(req, caller: who, trusted: false))

        case ("PATCH", "secrets", 2):
            guard let req = decode(VaultEditRequest.self) else {
                return .error(400, "body must be {\"tier\", \"rules\", \"tags\", \"leasePolicy\"}")
            }
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            return respond(await vault.broker.edit(path[1], req, caller: who, trusted: false))

        case ("DELETE", "secrets", 2):
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            return respond(await vault.broker.delete(path[1], caller: who, trusted: false, reason: query["reason"]))

        case ("GET", "log", 1):
            let limit = min(max(Int(query["limit"] ?? "") ?? 100, 1), 2000)
            return .json(await vault.store.log(limit: limit, cardId: query["card"], secret: query["secret"]))

        case ("GET", "leases", 1):
            return .json(await vault.store.activeLeases(cardId: query["card"]))

        case ("GET", "status", 1):
            let count = (try? await vault.store.list().count) ?? 0
            let identity = await vault.store.currentIdentity()
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            return .json(VaultStatus(unlocked: identity != nil, recipient: identity?.recipient.text, secrets: count,
                                     machine: vault.broker.machine, caller: who.insideCard ? who.cardId : nil))

        case ("POST", "card-token", 1):
            guard let device, device.scope.actsForOwner else {
                return .error(403, "card tokens are verified for peer masters only")
            }
            guard let query = try? JSONDecoder().decode(VaultCardTokenQuery.self, from: body), !query.hash.isEmpty else {
                return .error(400, "body must be {\"hash\": \"<sha256 of the token>\"}")
            }
            let live = Set(await vault.resolver.cardSessions().values)
            guard let card = await vault.cardTokens.verify(hash: query.hash, liveCards: live) else {
                return .error(404, "no card session here has that token")
            }
            return .json(VaultPeerCard(cardId: card, title: await vault.broker.cardTitle(card), machine: vault.broker.machine))

        case ("GET", "owner", 1):
            do {
                let owner = try await vault.store.owner()
                let counts = try await vault.store.ownerCounts()
                return .json(VaultOwnerStatus(
                    active: owner?.isActive ?? false,
                    keys: (owner?.recipients ?? []).map { .init(name: $0.name, kind: $0.kind.rawValue, fingerprint: $0.fingerprint, addedAt: $0.addedAt) },
                    sealed: counts.sealed, plain: counts.plain))
            } catch {
                return .error(423, "\(error)")
            }

        case ("POST", "owner", 2) where path[1] == "enrol":
            guard loopback || device?.scope == .full else {
                return .error(403, "a device enrols with a full-scope token")
            }
            guard let req = decode(VaultEnrolRequest.self), req.kind != .recovery,
                  (try? Age.P256Recipient(text: req.publicKey)) != nil else {
                return .error(400, "body must be {\"name\", \"kind\": \"mac\"|\"phone\", \"publicKey\": \"age1se1...\"}")
            }
            let who = await caller(claimedCard: query["card"], sessionId: nil)
            let r = await vault.broker.enrol(VaultOwnerRecipient(name: req.name, kind: req.kind, publicKey: req.publicKey), caller: who)
            await vault.replica?.poke()
            return respond(r)

        case ("GET", "audit", 2) where path[1] == "check":
            return .json(await vault.audit.check())

        case (_, "audit", 2) where path[1] == "hashes" || path[1] == "mirror":
            // A device of the human or a paired master, by scope name.
            guard let device, ["full", "peer"].contains(device.scope.rawValue) else {
                return .error(403, "the audit mirror is for peer masters only")
            }
            if path[1] == "hashes" {
                return .json(VaultAuditHashes(machine: vault.broker.machine, hashes: await vault.store.auditLines().map(AuditChain.hash)))
            }
            if method == "GET" {
                guard let machine = query["machine"], !machine.isEmpty else { return .error(400, "name the machine: ?machine=") }
                return .json(await vault.store.mirrorTail(machine: machine))
            }
            guard method == "POST", let push = try? JSONDecoder().decode(VaultAuditMirrorPush.self, from: body), !push.machine.isEmpty else {
                return .error(400, "body must be {\"machine\", \"lines\": [...]}")
            }
            guard push.machine != vault.broker.machine else { return .error(400, "a machine does not mirror itself") }
            return .json(await vault.store.appendMirror(machine: push.machine, lines: push.lines))

        case (_, "replica", 1):
            guard let device, device.scope.actsForOwner else {
                return .error(403, "the replica is for peer masters only")
            }
            if method == "GET" {
                return .json(VaultReplicaBody(blob: await vault.store.encryptedBlob()?.base64EncodedString()))
            }
            guard method == "POST", let req = try? JSONDecoder().decode(VaultReplicaBody.self, from: body),
                  let blob = req.blob.flatMap({ Data(base64Encoded: $0) }) else {
                return .error(400, "body must be {\"blob\": \"<base64>\"}")
            }
            do {
                let result = try await vault.store.mergeReplica(blob)
                return .json(["changed": result.changedHere, "youAreBehind": result.otherIsBehind])
            } catch {
                return .error(422, "\(error)")
            }

        default:
            return .error(404, "no vault route \(method) /v1/\(rest.joined(separator: "/"))")
        }
    }
}
