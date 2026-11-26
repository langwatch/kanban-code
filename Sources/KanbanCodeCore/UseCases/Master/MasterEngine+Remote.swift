import Foundation

// MARK: - Cards the remote API creates and resumes

extension MasterEngine {
    /// Creates the card and, unless `launch` is false, launches it with the
    /// project's defaults: runtime, run remotely, skip permissions, command
    /// template and API service. Returns the card id.
    @discardableResult
    public func createRemoteTask(_ request: RemoteLaunchRequest) -> String {
        let trimmed = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String((request.title ?? trimmed.components(separatedBy: .newlines).first ?? trimmed).prefix(100))
        let link = Link(
            name: name,
            projectPath: request.projectPath,
            column: request.launch ? .inProgress : .backlog,
            source: .manual,
            origin: request.origin,
            promptBody: trimmed,
            promptImagePaths: request.imagePaths.isEmpty ? nil : request.imagePaths,
            modelOverride: request.model,
            assistant: request.assistant
        )
        store.dispatch(.createManualTask(link))
        KanbanCodeLog.info("remote", "Created task card=\(link.id.prefix(12)) project=\(request.projectPath) launch=\(request.launch)")
        guard request.launch else { return link.id }
        launchRemoteCard(link: link, worktree: request.worktree, machine: request.machine, human: request.human)
        return link.id
    }

    /// `machine` is "mac", the name of a machine, or nil for the defaults
    /// of the project.
    func launchRemoteCard(link: Link, worktree: String?, machine: String? = nil, human: Bool = false) {
        let projectPath = link.projectPath ?? NSHomeDirectory()
        let assistant = link.effectiveAssistant
        if let machine, !isLocalMachine(machine), let peer = peerMachine(named: machine) {
            guard PromptPreview.isPreview(link) else {
                launchOnPeer(cardId: link.id, prompt: link.promptBody ?? link.name ?? "", worktree: worktree, peer: peer)
                return
            }
            Task {
                let prompt = await PromptPreview.fullPrompt(for: link) ?? link.name ?? ""
                launchOnPeer(cardId: link.id, prompt: prompt, worktree: worktree, peer: peer)
            }
            return
        }
        // The platform knows this master only as "mac".
        let target = machine.map { isLocalMachine($0) ? "mac" : $0 }
        let choice = platform.remoteMachineChoice(target, projectPath)
        let skipPermissions = platform.skipPermissions()
        Task {
            let settings = try? await settingsStore.read()
            let project = settings?.projects.first(where: { $0.path == projectPath })
            var link = link
            link.promptBody = await PromptPreview.fullPrompt(for: link)
            var prompt = PromptBuilder.buildPrompt(card: link, project: project, settings: settings)
            if prompt.isEmpty { prompt = link.promptBody ?? link.name ?? "" }
            let isGitRepo = FileManager.default.fileExists(atPath: (projectPath as NSString).appendingPathComponent(".git"))
            let worktreeName = (isGitRepo && assistant.supportsWorktree) ? worktree : nil
            launch(
                cardId: link.id,
                prompt: prompt,
                projectPath: projectPath,
                worktreeName: worktreeName,
                runRemotely: choice.runRemotely,
                skipPermissions: skipPermissions,
                images: (link.promptImagePaths ?? []).compactMap { ImageAttachment.fromPath($0) },
                assistant: assistant,
                serviceIdOverride: settings?.defaultAPIServiceIds[assistant.rawValue],
                modelOverride: link.modelOverride,
                machineChoice: choice.machine,
                keepSelection: true,
                humanPrompt: human
            )
        }
    }

    /// Starts the card's session again: a resume of its conversation, or the
    /// first launch of a card that never ran.
    public func resumeRemoteCard(_ cardId: String, afterDispatch: (() -> Void)? = nil) {
        guard let link = store.state.links[cardId] else { return }
        guard link.sessionLink != nil else {
            if link.column == .backlog { store.dispatch(.moveCard(cardId: cardId, to: .inProgress)) }
            launchRemoteCard(link: link, worktree: link.worktreeLink?.branch, machine: link.remote?.machineName)
            afterDispatch?()
            return
        }
        resume(
            cardId: cardId,
            runRemotely: link.isRemote,
            skipPermissions: platform.skipPermissions(),
            commandOverride: nil,
            assistant: link.effectiveAssistant,
            serviceIdOverride: link.apiServiceId,
            modelOverride: link.modelOverride,
            machineChoice: link.remote.map { .existing($0.machineName) },
            keepSelection: true,
            afterDispatch: afterDispatch
        )
    }

    /// Continues a card's conversation on a boxd or ssh machine this master
    /// drives, or back here: `target` is "mac" (this master) or the machine
    /// name. The session where it runs now ends first.
    public func moveCardToMachine(_ cardId: String, to target: String, afterDispatch: (() -> Void)? = nil) {
        guard let link = store.state.links[cardId], link.sessionLink != nil else {
            KanbanCodeLog.warn("remote", "Move of card=\(cardId.prefix(12)) refused: no conversation to move")
            return
        }
        let here = Self.isLocalTarget(target)
        KanbanCodeLog.info("remote", "Moving card=\(cardId.prefix(12)) to \(here ? "this master" : target)")
        resume(
            cardId: cardId,
            runRemotely: !here,
            skipPermissions: platform.skipPermissions(),
            commandOverride: nil,
            assistant: link.effectiveAssistant,
            serviceIdOverride: link.apiServiceId,
            modelOverride: link.modelOverride,
            machineChoice: here ? nil : .existing(target),
            keepSelection: true,
            afterDispatch: afterDispatch
        )
    }

    /// "mac" and "local" name the master itself.
    nonisolated static func isLocalTarget(_ target: String) -> Bool {
        let lower = target.lowercased()
        return lower == "mac" || lower == "local" || lower == "here"
    }
}
