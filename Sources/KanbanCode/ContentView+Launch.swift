import SwiftUI
import KanbanCodeCore

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
            var prompt = PromptBuilder.buildPrompt(card: card.link, project: project, settings: settings)
            if prompt.isEmpty {
                prompt = card.link.promptBody ?? card.link.name ?? ""
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
                assistant: card.link.effectiveAssistant
            )
        }
    }

    func executeLaunch(cardId: String, prompt: String, projectPath: String, worktreeName: String?, runRemotely: Bool = true, skipPermissions: Bool = true, commandOverride: String? = nil, images: [ImageAttachment] = [], assistant: CodingAssistant = .claude) {
        // IMMEDIATE state update via reducer — no more dual memory+disk writes
        store.dispatch(.launchCard(cardId: cardId, prompt: prompt, projectPath: projectPath, worktreeName: worktreeName, runRemotely: runRemotely, commandOverride: commandOverride))
        shouldFocusTerminal = true
        // Reducer computed the unique tmux name and stored it in the link
        let predictedTmuxName = store.state.links[cardId]?.tmuxLink?.sessionName ?? cardId
        KanbanCodeLog.info("launch", "Starting launch for card=\(cardId.prefix(12)) tmux=\(predictedTmuxName) project=\(projectPath)")

        Task {
            do {
                let settings = try? await settingsStore.read()

                let shellOverride: String?
                let extraEnv: [String: String]
                let isRemote: Bool
                let preamble: String?

                let globalRemote = settings?.remote
                if runRemotely, let remote = globalRemote, projectPath.hasPrefix(remote.localPath) {
                    try? RemoteShellManager.deploy()
                    shellOverride = RemoteShellManager.shellOverridePath()
                    var env = RemoteShellManager.setupEnvironment(remote: remote, projectPath: projectPath)
                    // Some CLIs use `bash -c` directly, so prepend our remote
                    // dir to PATH so they find Kanban's bash wrapper first.
                    if assistant.requiresRemotePathWrapper {
                        let remoteDir = RemoteShellManager.remoteDirPath()
                        env["PATH"] = "\(remoteDir):$PATH"
                    }
                    extraEnv = env
                    isRemote = true

                    let syncName = "kanban-code-sync"
                    let remoteDest = "\(remote.host):\(remote.remotePath)"
                    let ignores = remote.syncIgnores ?? MutagenAdapter.defaultIgnores
                    try? await mutagenAdapter.startSync(
                        localPath: remote.localPath,
                        remotePath: remoteDest,
                        name: syncName,
                        ignores: ignores
                    )

                    preamble = Self.remotePreamble(host: remote.host)
                } else {
                    shellOverride = nil
                    extraEnv = [:]
                    isRemote = false
                    preamble = nil
                }

                // Snapshot existing session files for detection
                let sessionFileExt = ".\(assistant.sessionFileExtension)"
                let configDir = (NSHomeDirectory() as NSString).appendingPathComponent(assistant.configDirName)
                let claudeProjectsDir = (configDir as NSString).appendingPathComponent("projects")
                let encodedProject = SessionFileMover.encodeProjectPath(projectPath)
                let sessionDir = (claudeProjectsDir as NSString).appendingPathComponent(encodedProject)
                let existingCodexFiles = assistant == .codex
                    ? Set(CodexSessionDiscovery.sessionFiles())
                    : []

                // When worktree is enabled, also snapshot worktree-related directories
                // (worktrees create sessions in dirs like <encodedProject>-.claude-worktrees-<name>)
                let dirsToSnapshot: [String]
                if assistant == .gemini {
                    // Gemini stores sessions in ~/.gemini/tmp/<slug>/chats/
                    let tmpDir = (configDir as NSString).appendingPathComponent("tmp")
                    let slugDirs = (try? FileManager.default.contentsOfDirectory(atPath: tmpDir)) ?? []
                    dirsToSnapshot = slugDirs.map { slug in
                        (tmpDir as NSString).appendingPathComponent(slug).appending("/chats")
                    }
                } else if assistant == .codex {
                    // Codex stores sessions recursively under ~/.codex/sessions.
                    dirsToSnapshot = []
                } else if worktreeName != nil {
                    let allDirs = (try? FileManager.default.contentsOfDirectory(atPath: claudeProjectsDir)) ?? []
                    dirsToSnapshot = [sessionDir] + allDirs
                        .filter { $0.hasPrefix(encodedProject) && $0 != encodedProject }
                        .map { (claudeProjectsDir as NSString).appendingPathComponent($0) }
                } else {
                    dirsToSnapshot = [sessionDir]
                }
                var existingFilesByDir: [String: Set<String>] = [:]
                for dir in dirsToSnapshot {
                    existingFilesByDir[dir] = Set(
                        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                            .filter { $0.hasSuffix(sessionFileExt) }
                    )
                }

                let tmuxName = try await launcher.launch(
                    sessionName: predictedTmuxName,
                    projectPath: projectPath,
                    prompt: prompt,
                    worktreeName: assistant.supportsWorktree ? worktreeName : nil,
                    shellOverride: shellOverride,
                    extraEnv: extraEnv,
                    commandOverride: commandOverride,
                    skipPermissions: skipPermissions,
                    preamble: preamble,
                    assistant: assistant
                )
                KanbanCodeLog.info("launch", "Tmux session created: \(tmuxName)")

                // Show terminal immediately — clear isLaunching so UI switches
                // from spinner to terminal view without waiting for session detection.
                store.dispatch(.launchTmuxReady(cardId: cardId))

                // Send images + prompt via send-keys after assistant is ready
                if !prompt.isEmpty || !images.isEmpty {
                    let imageSender = ImageSender(tmux: self.tmuxAdapter)
                    try await imageSender.waitForReady(sessionName: tmuxName, assistant: assistant)

                    if !images.isEmpty && assistant.supportsImageUpload {
                        try await imageSender.sendImages(
                            sessionName: tmuxName,
                            images: images,
                            setClipboard: { data in
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setData(data, forType: .png)
                            }
                        )
                    }

                    if !prompt.isEmpty {
                        if assistant.submitsPromptWithPaste {
                            try await self.tmuxAdapter.pastePrompt(to: tmuxName, text: prompt)
                        } else {
                            try await self.tmuxAdapter.sendPrompt(to: tmuxName, text: prompt)
                        }
                    }
                }

                // Detect new session by polling for new session file
                // Worktree launches, Gemini, and Codex need more attempts (slower startup)
                let maxAttempts = (worktreeName != nil || assistant == .gemini || assistant == .codex) ? 12 : 6
                var sessionLink: SessionLink?
                for attempt in 0..<maxAttempts {
                    try? await Task.sleep(for: .milliseconds(500))

                    if assistant == .codex {
                        let currentFiles = Set(CodexSessionDiscovery.sessionFiles())
                        let newFiles = currentFiles.subtracting(existingCodexFiles)
                        if let sessionPath = newestFile(from: Array(newFiles)),
                           let sessionId = await CodexSessionParser.extractSessionId(from: sessionPath) {
                            KanbanCodeLog.info("launch", "Detected Codex session file after \(attempt+1) attempts: \(sessionId.prefix(8))")
                            sessionLink = SessionLink(sessionId: sessionId, sessionPath: sessionPath)
                            break
                        }
                        continue
                    }

                    // Build list of dirs to scan (re-list for worktree — dir may appear mid-poll)
                    let dirsToScan: [String]
                    if assistant == .gemini {
                        let tmpDir = (configDir as NSString).appendingPathComponent("tmp")
                        let slugDirs = (try? FileManager.default.contentsOfDirectory(atPath: tmpDir)) ?? []
                        dirsToScan = slugDirs.map { slug in
                            (tmpDir as NSString).appendingPathComponent(slug).appending("/chats")
                        }
                    } else if worktreeName != nil {
                        let allDirs = (try? FileManager.default.contentsOfDirectory(atPath: claudeProjectsDir)) ?? []
                        dirsToScan = allDirs
                            .filter { $0.hasPrefix(encodedProject) }
                            .map { (claudeProjectsDir as NSString).appendingPathComponent($0) }
                    } else {
                        dirsToScan = [sessionDir]
                    }

                    for dir in dirsToScan {
                        let baseline = existingFilesByDir[dir] ?? [] // empty for newly-created dirs
                        let currentFiles = Set(
                            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                                .filter { $0.hasSuffix(sessionFileExt) }
                        )
                        if let newFile = currentFiles.subtracting(baseline).first {
                            let sessionId: String
                            if assistant == .gemini {
                                // Gemini: extract sessionId from inside the JSON file
                                let filePath = (dir as NSString).appendingPathComponent(newFile)
                                if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   let sid = obj["sessionId"] as? String {
                                    sessionId = sid
                                } else {
                                    sessionId = (newFile as NSString).deletingPathExtension
                                }
                            } else {
                                sessionId = (newFile as NSString).deletingPathExtension
                            }
                            let sessionPath = (dir as NSString).appendingPathComponent(newFile)
                            KanbanCodeLog.info("launch", "Detected session file after \(attempt+1) attempts in \((dir as NSString).lastPathComponent): \(sessionId.prefix(8))")
                            sessionLink = SessionLink(sessionId: sessionId, sessionPath: sessionPath)
                            break
                        }
                    }
                    if sessionLink != nil { break }
                }

                // If worktree launch, try to extract branch from the session file immediately
                var worktreeLink: WorktreeLink?
                if worktreeName != nil, let sl = sessionLink, let sp = sl.sessionPath {
                    worktreeLink = Self.extractWorktreeLink(sessionPath: sp, projectPath: projectPath)
                }

                store.dispatch(.launchCompleted(cardId: cardId, tmuxName: tmuxName, sessionLink: sessionLink, worktreeLink: worktreeLink, isRemote: isRemote))
            } catch {
                KanbanCodeLog.error("launch", "Launch failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
                store.dispatch(.launchFailed(cardId: cardId, error: error.localizedDescription))
            }
        }
    }

    private func newestFile(from paths: [String]) -> String? {
        paths.compactMap { path -> (String, Date)? in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return (path, mtime)
        }
        .max { $0.1 < $1.1 }?
        .0
    }

    /// Extract worktreeLink from a newly-created session file by reading its first line for gitBranch and cwd.
    static func extractWorktreeLink(sessionPath: String, projectPath: String) -> WorktreeLink? {
        // Read metadata from the first line of the .jsonl — it has the actual cwd and gitBranch
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
              let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")),
              let firstLine = String(data: data[data.startIndex..<firstNewline], encoding: .utf8),
              let lineData = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }

        // Use the cwd from the session metadata — it has the exact worktree path
        // (avoids lossy decoding of the directory name which mangles dashes in worktree names)
        let worktreePath: String
        if let cwd = obj["cwd"] as? String,
           cwd.contains("/.claude/worktrees/") || cwd.contains("/.claude-worktrees/") {
            worktreePath = cwd
        } else {
            // Fallback: derive from directory name structure
            // suffix is like ".claude-worktrees-<name>" or "claude-worktrees-<name>"
            let sessionDir = (sessionPath as NSString).deletingLastPathComponent
            let dirName = (sessionDir as NSString).lastPathComponent
            let encodedProject = SessionFileMover.encodeProjectPath(projectPath)
            guard dirName.hasPrefix(encodedProject) else { return nil }
            let rest = String(dirName.dropFirst(encodedProject.count))
            // Match known pattern: [-.]claude-worktrees-<worktreeName>
            // Only convert the structural separators, keep worktree name dashes intact
            guard let wtRange = rest.range(of: "claude-worktrees-") else { return nil }
            let worktreeName = String(rest[wtRange.upperBound...])
            worktreePath = projectPath + "/.claude/worktrees/" + worktreeName
        }

        var branchName: String?
        if let branch = obj["gitBranch"] as? String {
            branchName = branch.replacingOccurrences(of: "refs/heads/", with: "")
        }

        // Fallback: extract worktree name from path
        if branchName == nil {
            let components = worktreePath.components(separatedBy: "/.claude/worktrees/")
            if components.count == 2 {
                branchName = components[1]
            }
        }

        guard let branchName, !branchName.isEmpty else { return nil }
        KanbanCodeLog.info("launch", "Extracted worktreeLink: branch=\(branchName) path=\(worktreePath)")
        return WorktreeLink(path: worktreePath, branch: branchName)
    }

    /// Build a shell preamble that flushes mutagen and shows remote uname before launching claude.
    static func remotePreamble(host: String) -> String {
        // Use ; instead of && so a flush failure doesn't block claude from starting
        "printf '\\e[2mSyncing files...\\e[0m' && mutagen sync flush --label-selector kanban=true 2>/dev/null; printf '\\e[2mRemote: %s\\e[0m\\n' \"$(ssh -o ConnectTimeout=5 \(host) uname -snr 2>/dev/null || echo 'unavailable')\""
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

    func executeMigration(cardId: String, targetAssistant: CodingAssistant) async {
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
                projectPath: card.link.projectPath
            )
            // Update the card's link to point to the new session and kill tmux
            store.dispatch(.migrateSession(
                cardId: cardId,
                newAssistant: targetAssistant,
                newSessionId: result.newSessionId,
                newSessionPath: result.newSessionPath
            ))
            KanbanCodeLog.info("migrate", "Migrated card=\(cardId.prefix(12)) from \(sourceAssistant) to \(targetAssistant), backup=\(result.backupPath)")

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
            assistant: card.link.effectiveAssistant
        )
    }

    func forkCard(cardId: String, keepWorktree: Bool = false) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }),
              let sessionPath = card.link.sessionLink?.sessionPath else { return }
        Task {
            do {
                // Determine the project path and session directory for the fork.
                // When forking from a worktree (and not keeping it), use the parent project.
                var forkProjectPath = card.link.projectPath
                var targetDir: String? = nil
                if !keepWorktree {
                    // Extract parent project if projectPath is a worktree path
                    if let pp = forkProjectPath,
                       let range = pp.range(of: "/.claude/worktrees/") {
                        forkProjectPath = String(pp[..<range.lowerBound])
                    }
                    // Always place the forked session in the correct project dir
                    // so `claude --resume` can find it from the project root.
                    if card.link.effectiveAssistant == .claude, let fp = forkProjectPath {
                        let encoded = SessionFileMover.encodeProjectPath(fp)
                        let home = NSHomeDirectory()
                        targetDir = "\(home)/.claude/projects/\(encoded)"
                    }
                }

                let cardStore = assistantRegistry.store(for: card.link.effectiveAssistant) ?? store.sessionStore
                let newSessionId = try await cardStore.forkSession(
                    sessionPath: sessionPath, targetDirectory: targetDir
                )
                let dir = targetDir ?? (sessionPath as NSString).deletingLastPathComponent
                let newPath = Self.forkedSessionPath(
                    assistant: card.link.effectiveAssistant,
                    sessionId: newSessionId,
                    directory: dir
                )
                var newLink = Link(
                    name: (card.link.name ?? card.link.displayTitle) + " (fork)",
                    projectPath: forkProjectPath,
                    column: .waiting,
                    lastActivity: card.link.lastActivity,
                    source: .discovered,
                    sessionLink: SessionLink(sessionId: newSessionId, sessionPath: newPath),
                    worktreeLink: keepWorktree ? card.link.worktreeLink : nil
                )
                // Set watermark so reconciler ignores parent's baked-in gitBranch
                if !keepWorktree && card.link.worktreeLink != nil {
                    if let path = card.link.sessionLink?.sessionPath {
                        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                        newLink.manualOverrides.branchWatermark = size
                    } else {
                        newLink.manualOverrides.branchWatermark = 0
                    }
                }
                store.dispatch(.createManualTask(newLink))
                store.dispatch(.selectCard(cardId: newLink.id))
                shouldFocusTerminal = true
            } catch {
                KanbanCodeLog.error("fork", "Fork failed: \(error)")
            }
        }
    }

    static func forkedSessionPath(
        assistant: CodingAssistant,
        sessionId: String,
        directory: String
    ) -> String {
        switch assistant {
        case .claude:
            return (directory as NSString).appendingPathComponent("\(sessionId).jsonl")
        case .gemini:
            return (directory as NSString).appendingPathComponent("session-forked-\(sessionId).json")
        case .codex:
            return CodexSessionStore.sessionFilePath(
                sessionId: sessionId,
                in: directory,
                prefix: "rollout-forked"
            )
        }
    }

    func executeResume(cardId: String, runRemotely: Bool, skipPermissions: Bool = true, commandOverride: String?, assistant: CodingAssistant = .claude) {
        guard let card = store.state.cards.first(where: { $0.id == cardId }) else { return }
        let sessionId = card.link.sessionLink?.sessionId ?? card.link.id
        // For worktree cards, cd into the worktree — that's where Claude stored the session data.
        let projectPath: String
        if let worktreePath = card.link.worktreeLink?.path, !worktreePath.isEmpty {
            projectPath = worktreePath
        } else {
            projectPath = card.link.projectPath ?? NSHomeDirectory()
        }

        // If the session file lives under a different project key (e.g. a cleaned-up worktree),
        // move it to the current projectPath so `claude --resume` can find it.
        // Only applicable to Claude Code sessions (Gemini uses its own path scheme).
        if assistant == .claude,
           let sessionLink = card.link.sessionLink,
           let sessionPath = sessionLink.sessionPath {
            let expectedDir = NSHomeDirectory() + "/.claude/projects/" + SessionFileMover.encodeProjectPath(projectPath)
            let expectedPath = expectedDir + "/" + sessionId + ".jsonl"
            if sessionPath != expectedPath,
               FileManager.default.fileExists(atPath: sessionPath) {
                KanbanCodeLog.info("resume", "Moving session file from worktree project key to \(expectedDir)")
                if let newPath = try? SessionFileMover.moveSession(
                    sessionId: sessionId, fromPath: sessionPath, toProjectPath: projectPath
                ) {
                    var updatedLink = card.link
                    updatedLink.sessionLink = SessionLink(sessionId: sessionId, sessionPath: newPath)
                    store.dispatch(.createManualTask(updatedLink))
                }
            }
        }

        store.dispatch(.resumeCard(cardId: cardId))
        shouldFocusTerminal = true
        KanbanCodeLog.info("resume", "Starting resume for card=\(cardId.prefix(12)) session=\(sessionId.prefix(8))")

        Task {
            do {
                let settings = try? await settingsStore.read()

                let shellOverride: String?
                let extraEnv: [String: String]
                let isRemote: Bool
                let preamble: String?

                let globalRemote = settings?.remote
                if runRemotely, let remote = globalRemote, projectPath.hasPrefix(remote.localPath) {
                    try? RemoteShellManager.deploy()
                    shellOverride = RemoteShellManager.shellOverridePath()
                    var env = RemoteShellManager.setupEnvironment(remote: remote, projectPath: projectPath)
                    // Some CLIs use `bash -c` directly, so prepend our remote
                    // dir to PATH so they find Kanban's bash wrapper first.
                    if assistant.requiresRemotePathWrapper {
                        let remoteDir = RemoteShellManager.remoteDirPath()
                        env["PATH"] = "\(remoteDir):$PATH"
                    }
                    extraEnv = env
                    isRemote = true

                    let syncName = "kanban-code-sync"
                    let remoteDest = "\(remote.host):\(remote.remotePath)"
                    let ignores = remote.syncIgnores ?? MutagenAdapter.defaultIgnores
                    try? await mutagenAdapter.startSync(
                        localPath: remote.localPath,
                        remotePath: remoteDest,
                        name: syncName,
                        ignores: ignores
                    )

                    preamble = Self.remotePreamble(host: remote.host)
                } else {
                    shellOverride = nil
                    extraEnv = [:]
                    isRemote = false
                    preamble = nil
                }

                let actualTmuxName = try await launcher.resume(
                    sessionId: sessionId,
                    projectPath: projectPath,
                    shellOverride: shellOverride,
                    extraEnv: extraEnv,
                    commandOverride: commandOverride,
                    skipPermissions: skipPermissions,
                    preamble: preamble,
                    assistant: assistant
                )
                KanbanCodeLog.info("resume", "Resume launched for card=\(cardId.prefix(12)) actualTmux=\(actualTmuxName)")

                store.dispatch(.resumeCompleted(cardId: cardId, tmuxName: actualTmuxName, isRemote: isRemote))
            } catch {
                KanbanCodeLog.info("resume", "Resume failed for card=\(cardId.prefix(12)): \(error.localizedDescription)")
                store.dispatch(.resumeFailed(cardId: cardId, error: error.localizedDescription))
            }
        }
    }
}
