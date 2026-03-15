import Foundation
import PostHog
import KanbanCodeCore

enum Analytics {
    private static let apiKey = "phc_REPLACE_WITH_YOUR_KEY"
    private static let host = "https://us.i.posthog.com"

    static func setup() {
        let config = PostHogConfig(apiKey: apiKey, host: host)
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false
        config.sendFeatureFlagsOnNewIdentity = false
        PostHogSDK.shared.setup(config)

        capture("app_opened")
    }

    static func capture(_ event: String, properties: [String: Any] = [:]) {
        var props = properties
        props["platform"] = "macos"
        props["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        PostHogSDK.shared.capture(event, properties: props)
    }

    /// Hook into BoardStore.onAction to track user-initiated actions.
    static func trackAction(_ action: Action) {
        switch action {
        // Card lifecycle
        case .createManualTask:
            capture("card_created")
        case .launchCard(_, _, _, let worktreeName, let runRemotely, _):
            capture("card_launched", properties: [
                "has_worktree": worktreeName != nil,
                "run_remotely": runRemotely,
            ])
        case .resumeCard:
            capture("card_resumed")
        case .moveCard(_, let to):
            capture("card_moved", properties: ["to_column": to.rawValue])
        case .deleteCard:
            capture("card_deleted")
        case .archiveCard:
            capture("card_archived")
        case .renameCard:
            capture("card_renamed")
        case .mergeCards:
            capture("cards_merged")

        // Terminal
        case .createTerminal:
            capture("terminal_created")
        case .addExtraTerminal:
            capture("extra_terminal_added")
        case .killTerminal:
            capture("terminal_killed")

        // Queued prompts
        case .addQueuedPrompt:
            capture("queued_prompt_added")
        case .sendQueuedPrompt:
            capture("queued_prompt_sent")
        case .removeQueuedPrompt:
            capture("queued_prompt_removed")

        // Linking
        case .addBranchToCard:
            capture("branch_linked")
        case .addIssueLinkToCard:
            capture("issue_linked")
        case .addPRToCard:
            capture("pr_linked")
        case .markPRMerged:
            capture("pr_marked_merged")

        // Selection
        case .selectCard(let cardId):
            if cardId != nil { capture("card_selected") }

        case .setSelectedProject(let path):
            capture("project_filtered", properties: ["has_filter": path != nil])

        // Skip internal/background actions
        default:
            break
        }
    }
}
