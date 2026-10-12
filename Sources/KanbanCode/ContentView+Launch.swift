import SwiftUI
import KanbanCodeCore
import KanbanCodeRemoteKit

// MARK: - Launch, Resume, Fork & Migration

extension ContentView {
    func startCard(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        let effectivePath: String
        if let worktreePath = card.link.worktreeLink?.path, !worktreePath.isEmpty {
            effectivePath = worktreePath
        } else {
            effectivePath = card.link.projectPath ?? NSHomeDirectory()
        }

        Task {
            let settings = try? await settingsStore.read()
            let project = settings?.projects.first(where: { $0.path == (card.link.projectPath ?? effectivePath) })
            var link = card.link
            link.promptBody = await PromptPreview.fullPrompt(for: link, transcriptPath: card.session?.jsonlPath)
            var prompt = PromptBuilder.buildPrompt(card: link, project: project, settings: settings)
            if prompt.isEmpty {
                prompt = link.promptBody ?? link.name ?? ""
            }

            let worktreeName: String?
            if let branch = card.link.worktreeLink?.branch {
                worktreeName = branch
            } else if let issueNum = card.link.issueLink?.number {
                worktreeName = "issue-\(issueNum)"
            } else {
                worktreeName = nil
            }

            let isGitRepo = FileManager.default.fileExists(
                atPath: (effectivePath as NSString).appendingPathComponent(".git")
            )

            let globalRemote = store.state.globalRemoteSettings
            let projectIsUnderRemote = globalRemote.map { effectivePath.hasPrefix($0.localPath) } ?? false
            launchConfig = LaunchConfig(
                cardId: cardId,
                projectPath: effectivePath,
                prompt: prompt,
                worktreeName: worktreeName,
                hasExistingWorktree: card.link.worktreeLink != nil,
                isGitRepo: isGitRepo,
                hasRemoteConfig: projectIsUnderRemote,
                remoteHost: globalRemote?.host,
                promptImagePaths: card.link.promptImagePaths ?? [],
                assistant: card.link.effectiveAssistant,
                apiServiceId: card.link.apiServiceId,
                modelOverride: card.link.modelOverride
            )
        }
    }

    func executeLaunch(cardId: String, prompt: String, projectPath: String, worktreeName: String?, runRemotely: Bool = true, skipPermissions: Bool = true, commandOverride: String? = nil, images: [ImageAttachment] = [], assistant: CodingAssistant = .claude, serviceIdOverride: String? = nil, modelOverride: String? = nil, machineChoice: BoxdMachineChoice? = nil, focusCard: Bool = true, completion: ((String?) -> Void)? = nil) {
        engine.launch(
            cardId: cardId,
            prompt: prompt,
            projectPath: projectPath,
            worktreeName: worktreeName,
            runRemotely: runRemotely,
            skipPermissions: skipPermissions,
            commandOverride: commandOverride,
            images: images,
            assistant: assistant,
            serviceIdOverride: serviceIdOverride,
            modelOverride: modelOverride,
            machineChoice: machineChoice,
            keepSelection: !focusCard,
            humanPrompt: true,
            completion: completion
        )
        if focusCard { shouldFocusTerminal = true }
    }

    func migrationTargets(for card: KanbanCodeCard) -> [CodingAssistant] {
        guard card.link.sessionLink != nil else { return [] }
        let current = card.link.effectiveAssistant
        return assistantRegistry.available.filter { $0 != current }
    }

    /// Checkpoint / restore: truncates the session after the given line number.
    func performCheckpoint(cardId: String, turnLineNumber: Int) async {
        guard let card = store.state.cards.first(where: { $0.id == cardId }),
              let sessionPath = card.link.sessionLink?.sessionPath else { return }
        let sessionStore = assistantRegistry.store(for: card.link.effectiveAssistant) ?? store.sessionStore
        let turn = ConversationTurn(index: 0, lineNumber: turnLineNumber, role: "", textPreview: "")
        do {
            try await sessionStore.truncateSession(sessionPath: sessionPath, afterTurn: turn)
        } catch {
            store.dispatch(.setError("Checkpoint failed: \(error.localizedDescription)"))
        }
    }

    func executeMigration(cardId: String, targetAssistant: CodingAssistant, recentTurnLimit: Int? = nil) async {
        guard let card = store.state.cards.first(where: { $0.id == cardId }),
              let sessionLink = card.link.sessionLink,
              let sessionPath = sessionLink.sessionPath else { return }
        let sourceAssistant = card.link.effectiveAssistant
        let runRemotely = card.link.isRemote
        guard let sourceStore = assistantRegistry.store(for: sourceAssistant),
              let targetStore = assistantRegistry.store(for: targetAssistant) else { return }

        // Mark card as "launching" to prevent the reconciler from touching it
        // while migration is in progress (avoids race where the new session file
        // is discovered before migrateSession updates the sessionId).
        store.dispatch(.beginMigration(cardId: cardId))
        do {
            let result = try await SessionMigrator.migrate(
                sourceSessionPath: sessionPath,
                sourceStore: sourceStore,
                targetStore: targetStore,
                projectPath: card.link.projectPath,
                recentTurnLimit: recentTurnLimit
            )
            // Update the card's link to point to the new session and kill tmux
            store.dispatch(.migrateSession(
                cardId: cardId,
                newAssistant: targetAssistant,
                newSessionId: result.newSessionId,
                newSessionPath: result.newSessionPath
            ))
            let trimSummary = result.migratedTurnCount == result.sourceTurnCount
                ? "full history"
                : "trimmed \(result.sourceTurnCount)→\(result.migratedTurnCount) turns"
            KanbanCodeLog.info("migrate", "Migrated card=\(cardId.prefix(12)) from \(sourceAssistant) to \(targetAssistant), \(trimSummary), backup=\(result.backupPath)")

            // Resume the session with the new assistant right away
            executeResume(
                cardId: cardId,
                runRemotely: runRemotely,
                skipPermissions: true,
                commandOverride: nil,
                assistant: targetAssistant
            )
        } catch {
            store.dispatch(.migrationFailed(cardId: cardId, error: error.localizedDescription))
            KanbanCodeLog.info("migrate", "Migration failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
        }
    }

    func executeTrimSession(cardId: String, recentTurnLimit: Int) async {
        guard let card = store.state.cards.first(where: { $0.id == cardId }),
              let sessionLink = card.link.sessionLink,
              let sessionPath = sessionLink.sessionPath else { return }
        let assistant = card.link.effectiveAssistant
        let runRemotely = card.link.isRemote
        guard let sessionStore = assistantRegistry.store(for: assistant) else { return }

        store.dispatch(.beginMigration(cardId: cardId))
        do {
            let result = try await SessionMigrator.migrate(
                sourceSessionPath: sessionPath,
                sourceStore: sessionStore,
                targetStore: sessionStore,
                projectPath: card.link.projectPath,
                recentTurnLimit: recentTurnLimit
            )
            store.dispatch(.migrateSession(
                cardId: cardId,
                newAssistant: assistant,
                newSessionId: result.newSessionId,
                newSessionPath: result.newSessionPath
            ))
            KanbanCodeLog.info("migrate", "Trimmed card=\(cardId.prefix(12)) assistant=\(assistant) \(result.sourceTurnCount)→\(result.migratedTurnCount) turns, backup=\(result.backupPath)")

            executeResume(
                cardId: cardId,
                runRemotely: runRemotely,
                skipPermissions: true,
                commandOverride: nil,
                assistant: assistant
            )
        } catch {
            store.dispatch(.migrationFailed(cardId: cardId, error: error.localizedDescription))
            KanbanCodeLog.info("migrate", "Trim failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
        }
    }

    func createExtraTerminal(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }

        if let tmux = card.link.tmuxLink {
            // Has existing tmux — add an extra shell session
            let existing = tmux.extraSessions ?? []
            let liveTmux = store.state.tmuxSessions // live tmux sessions from last reconciliation
            let baseName = tmux.sessionName
            var n = 1
            while existing.contains("\(baseName)-sh\(n)") || liveTmux.contains("\(baseName)-sh\(n)") { n += 1 }
            let newName = "\(baseName)-sh\(n)"
            // The terminal opens before the effect has created the session on
            // the machine, so it has to know it is a remote one from the
            // first frame; a local attach would find no such session.
            if let remote = card.link.remote, remote.mode == .boxd, card.link.isRemote {
                AppServices.expectRemoteSession(newName)
                KanbanCodeLog.info("terminal", "Extra shell \(newName) opens on \(remote.machineName)")
            }
            store.dispatch(.addExtraTerminal(cardId: cardId, sessionName: newName))
        } else {
            // No tmux at all — create a primary terminal session (plain shell, no Claude)
            store.dispatch(.createTerminal(cardId: cardId))
        }
    }

    func resumeCard(cardId: String) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        let sessionId = card.link.sessionLink?.sessionId ?? card.link.id
        // For worktree cards, cd into the worktree — that's where Claude stored the session data.
        let projectPath: String
        if let worktreePath = card.link.worktreeLink?.path, !worktreePath.isEmpty {
            projectPath = worktreePath
        } else {
            projectPath = card.link.projectPath ?? NSHomeDirectory()
        }

        let globalRemote = store.state.globalRemoteSettings
        let projectIsUnderRemote = globalRemote.map { projectPath.hasPrefix($0.localPath) } ?? false

        launchConfig = LaunchConfig(
            cardId: cardId,
            projectPath: projectPath,
            prompt: "",
            hasExistingWorktree: card.link.worktreeLink != nil,
            hasRemoteConfig: projectIsUnderRemote,
            remoteHost: globalRemote?.host,
            isResume: true,
            sessionId: sessionId,
            assistant: card.link.effectiveAssistant,
            apiServiceId: card.link.apiServiceId,
            modelOverride: card.link.modelOverride
        )
    }

    func forkCard(cardId: String, keepWorktree: Bool = false) {
        Task {
            do {
                let newId = try await engine.forkCard(cardId: cardId, keepWorktree: keepWorktree)
                store.dispatch(.selectCard(cardId: newId))
                shouldFocusTerminal = true
            } catch {
                KanbanCodeLog.error("fork", "Fork failed: \(error)")
            }
        }
    }

    func executeResume(cardId: String, runRemotely: Bool, skipPermissions: Bool = true, commandOverride: String?, assistant: CodingAssistant = .claude, serviceIdOverride: String? = nil, modelOverride: String? = nil, machineChoice: BoxdMachineChoice? = nil, focusCard: Bool = true) {
        engine.resume(
            cardId: cardId,
            runRemotely: runRemotely,
            skipPermissions: skipPermissions,
            commandOverride: commandOverride,
            assistant: assistant,
            serviceIdOverride: serviceIdOverride,
            modelOverride: modelOverride,
            machineChoice: machineChoice,
            keepSelection: !focusCard,
            afterDispatch: focusCard ? { [self] in shouldFocusTerminal = true } : nil
        )
    }
}
