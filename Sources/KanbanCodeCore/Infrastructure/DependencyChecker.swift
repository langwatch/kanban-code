import Foundation

/// Checks availability of all external dependencies.
public enum DependencyChecker {

    public struct Status: Sendable {
        public let claudeAvailable: Bool
        public let geminiAvailable: Bool
        public let hooksInstalled: Bool
        public let pandocAvailable: Bool
        public let wkhtmltoimageAvailable: Bool
        public let pushoverConfigured: Bool
        public let ghAvailable: Bool
        public let ghAuthenticated: Bool
        public let tmuxAvailable: Bool
        public let mutagenAvailable: Bool

        /// Per-assistant hook installation status.
        public let assistantHooks: [CodingAssistant: Bool]

        public init(
            claudeAvailable: Bool, geminiAvailable: Bool = false,
            hooksInstalled: Bool,
            assistantHooks: [CodingAssistant: Bool] = [:],
            pandocAvailable: Bool,
            wkhtmltoimageAvailable: Bool, pushoverConfigured: Bool,
            ghAvailable: Bool, ghAuthenticated: Bool = false,
            tmuxAvailable: Bool, mutagenAvailable: Bool
        ) {
            self.claudeAvailable = claudeAvailable
            self.geminiAvailable = geminiAvailable
            self.hooksInstalled = hooksInstalled
            self.pandocAvailable = pandocAvailable
            self.wkhtmltoimageAvailable = wkhtmltoimageAvailable
            self.pushoverConfigured = pushoverConfigured
            self.ghAvailable = ghAvailable
            self.ghAuthenticated = ghAuthenticated
            self.tmuxAvailable = tmuxAvailable
            self.mutagenAvailable = mutagenAvailable
            self.assistantHooks = assistantHooks.isEmpty
                ? [.claude: hooksInstalled]
                : assistantHooks
        }
    }

    /// Check all dependencies concurrently.
    public static func checkAll(settingsStore: SettingsStore) async -> Status {
        async let claude = ShellCommand.isAvailable("claude")
        async let gemini = ShellCommand.isAvailable("gemini")
        async let pandoc = ShellCommand.isAvailable("pandoc")
        async let wkhtmltoimage = ShellCommand.isAvailable("wkhtmltoimage")
        async let gh = ShellCommand.isAvailable("gh")
        async let ghAuth = checkGhAuth()
        async let tmux = ShellCommand.isAvailable("tmux")
        async let mutagen = ShellCommand.isAvailable("mutagen")

        // Check hooks for all assistants
        var hooks: [CodingAssistant: Bool] = [:]
        for assistant in CodingAssistant.allCases {
            hooks[assistant] = HookManager.isInstalled(for: assistant)
        }

        let pushover: Bool
        if let settings = try? await settingsStore.read() {
            let token = settings.notifications.pushoverToken ?? ""
            let user = settings.notifications.pushoverUserKey ?? ""
            pushover = settings.notifications.pushoverEnabled && !token.isEmpty && !user.isEmpty
        } else {
            pushover = false
        }

        return await Status(
            claudeAvailable: claude,
            geminiAvailable: gemini,
            hooksInstalled: hooks[.claude] ?? false,
            assistantHooks: hooks,
            pandocAvailable: pandoc,
            wkhtmltoimageAvailable: wkhtmltoimage,
            pushoverConfigured: pushover,
            ghAvailable: gh,
            ghAuthenticated: ghAuth,
            tmuxAvailable: tmux,
            mutagenAvailable: mutagen
        )
    }

    /// Check if `gh` CLI is authenticated (exit code 0 = logged in).
    private static func checkGhAuth() async -> Bool {
        guard let ghPath = ShellCommand.findExecutable("gh"),
              let result = try? await ShellCommand.run(ghPath, arguments: ["auth", "status"]) else {
            return false
        }
        return result.succeeded
    }
}
