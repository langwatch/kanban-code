import Foundation
import KanbanCodeCore

extension ContentView {
    /// Lets the remote control server create and resume cards through the
    /// same flow as the New Task dialog and the resume button.
    func registerRemoteControlHandlers() {
        let controller = RemoteControlController.shared
        controller.launchTask = { request in launchRemoteTask(request) }
        controller.resumeCard = { cardId in resumeRemoteCard(cardId) }
    }

    /// Creates the card and, unless `launch` is false, launches it with the
    /// project's defaults: runtime, run remotely, skip permissions, command
    /// template and API service. The Mac's selection stays where it is.
    func launchRemoteTask(_ request: RemoteLaunchRequest) -> String {
        let trimmed = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String((request.title ?? trimmed.components(separatedBy: .newlines).first ?? trimmed).prefix(100))
        let link = Link(
            name: name,
            projectPath: request.projectPath,
            column: request.launch ? .inProgress : .backlog,
            source: .manual,
            promptBody: trimmed,
            promptImagePaths: request.imagePaths.isEmpty ? nil : request.imagePaths,
            modelOverride: request.model,
            assistant: request.assistant
        )
        store.dispatch(.createManualTask(link))
        KanbanCodeLog.info("remote", "Created task card=\(link.id.prefix(12)) project=\(request.projectPath) launch=\(request.launch)")
        guard request.launch else { return link.id }
        launchRemoteCard(link: link, worktree: request.worktree)
        return link.id
    }

    private func launchRemoteCard(link: Link, worktree: String?) {
        let projectPath = link.projectPath ?? NSHomeDirectory()
        let assistant = link.effectiveAssistant
        Task {
            let settings = try? await settingsStore.read()
            let project = settings?.projects.first(where: { $0.path == projectPath })
            var prompt = PromptBuilder.buildPrompt(card: link, project: project, settings: settings)
            if prompt.isEmpty { prompt = link.promptBody ?? link.name ?? "" }
            let isGitRepo = FileManager.default.fileExists(atPath: (projectPath as NSString).appendingPathComponent(".git"))
            let worktreeName = (isGitRepo && assistant.supportsWorktree) ? worktree : nil
            let options = remoteLaunchOptions(cardId: nil)
            let runRemotely = options.canRunRemotely(projectPath: projectPath)
                && RemoteLaunchOptions.defaultRunRemotely(mode: options.mode, projectPath: projectPath)
            executeLaunch(
                cardId: link.id,
                prompt: prompt,
                projectPath: projectPath,
                worktreeName: worktreeName,
                runRemotely: runRemotely,
                skipPermissions: Self.remoteSkipPermissions,
                images: (link.promptImagePaths ?? []).compactMap { ImageAttachment.fromPath($0) },
                assistant: assistant,
                serviceIdOverride: settings?.defaultAPIServiceIds[assistant.rawValue],
                modelOverride: link.modelOverride,
                machineChoice: runRemotely && options.mode == .boxd ? .newMachine : nil,
                focusCard: false
            )
        }
    }

    /// Starts the card's session again: a resume of its conversation, or the
    /// first launch of a card that never ran.
    func resumeRemoteCard(_ cardId: String) {
        guard let link = store.state.links[cardId] else { return }
        guard link.sessionLink != nil else {
            if link.column == .backlog { store.dispatch(.moveCard(cardId: cardId, to: .inProgress)) }
            launchRemoteCard(link: link, worktree: link.worktreeLink?.branch)
            return
        }
        executeResume(
            cardId: cardId,
            runRemotely: link.isRemote,
            skipPermissions: Self.remoteSkipPermissions,
            commandOverride: nil,
            assistant: link.effectiveAssistant,
            serviceIdOverride: link.apiServiceId,
            modelOverride: link.modelOverride,
            machineChoice: link.remote.map { .existing($0.machineName) },
            focusCard: false
        )
    }

    /// The "Skip permissions" box of the launch dialogs.
    static var remoteSkipPermissions: Bool {
        UserDefaults.standard.object(forKey: "dangerouslySkipPermissions") as? Bool ?? true
    }
}
