import Foundation

// MARK: - Session tokens of rush hosts

extension MasterEngine {
    /// Runs until cancelled: every `interval`, reads the session token of
    /// the running assistant of each rush host this master runs for a card,
    /// and starts again, once it rests, a host whose token is missing or
    /// not the card's, or a host of a card with no token on file at all
    /// (`RushTokenKeeper`).
    public func runRushTokenMonitor(interval: Duration = .seconds(15)) async {
        while !Task.isCancelled {
            await checkRushTokens()
            try? await Task.sleep(for: interval)
        }
    }

    /// How many hosts one pass starts again at most.
    nonisolated static let rushTokenRefreshesPerPass = 3

    /// One pass of `runRushTokenMonitor`.
    func checkRushTokens(readToken: (Int) async -> ProcessEnvironment.Reading = {
        await ProcessEnvironment.read(VaultCardTokens.environmentName, pid: $0)
    }) async {
        guard let cardTokenOwner, cardSessionEnvironment != nil, tmux.rush.isAvailable,
              let hosts = try? await tmux.rush.list() else { return }
        var cardBySession: [String: String] = [:]
        for (id, link) in store.state.links
        where store.state.isOwnedLocally(link) && link.isLaunching != true && !link.isRemote {
            for name in link.tmuxLink?.allSessionNames ?? [] where RushSessionName.isRush(name) {
                cardBySession[name] = id
            }
        }
        let ours = hosts.compactMap { host -> (host: RushSessionInfo, cardId: String)? in
            cardBySession[RushSessionName.name(for: host)].map { (host, $0) }
        }
        for (host, cardId) in ours {
            guard host.alive, let pid = host.claudePid else {
                // A resting host of a card with no token on file wakes
                // without a valid one: no need to wait for a turn to see it.
                if let cardHasToken, await !cardHasToken(cardId) {
                    rushTokens.observe(hostId: host.id, cardId: cardId, tokenCard: nil)
                }
                continue
            }
            let tokenCard: String?
            switch await readToken(pid) {
            case .unreadable: continue
            case .absent: tokenCard = nil
            case .value(let token): tokenCard = await cardTokenOwner(token)
            }
            rushTokens.observe(hostId: host.id, cardId: cardId, tokenCard: tokenCard)
        }
        let cardByHost = Dictionary(ours.map { ($0.host.id, $0.cardId) }, uniquingKeysWith: { first, _ in first })
        // A host whose folder is gone cannot start again here; the rest go a
        // few per pass, so a master that finds many does not start them all
        // at once.
        let startable = ours.map(\.host).filter { FileManager.default.fileExists(atPath: $0.cwd) }
        for (host, refresh) in rushTokens.due(startable, limit: Self.rushTokenRefreshesPerPass) {
            guard let cardId = cardByHost[host.id], !resumingCards.contains(cardId) else { continue }
            await refreshRushToken(cardId: cardId, host: host, refresh: refresh)
        }
    }

    /// Starts a resting rush host again with a fresh session token, which
    /// rush also saves as the environment it wakes the host with.
    func refreshRushToken(cardId: String, host: RushSessionInfo, refresh: RushTokenKeeper.Refresh) async {
        guard let link = store.state.links[cardId] else { return }
        KanbanCodeLog.info("rush", "Restarting resting \(RushSessionName.name(for: host)) of card=\(cardId.prefix(12)) for a session token")
        do {
            if refresh == .stopThenStart { try await tmux.rush.stop(id: host.id) }
            let settings = try? await settingsStore.read()
            let serviceId = link.apiServiceId ?? settings?.defaultAPIServiceIds[CodingAssistant.claude.rawValue]
            let service = serviceId.flatMap { id in settings?.apiServices.first { $0.id == id && $0.assistant == .claude } }
            let env = await sessionEnvironment(
                cardId: cardId, base: [:], service: service,
                parentCardId: link.parentCardId, assistant: .claude, isRemote: false)
            _ = try await startOnRush(
                cardId: cardId,
                cwd: host.cwd,
                sessionId: host.sessionId,
                resume: true,
                prompt: nil,
                images: [],
                extraEnv: env,
                skipPermissions: platform.skipPermissions(),
                model: nil,
                commandTemplate: settings?.commandTemplate(for: .claude, remote: false),
                service: service
            )
        } catch {
            KanbanCodeLog.warn("rush", "Could not restart \(host.id) for a session token: \(error.localizedDescription)")
        }
    }
}
