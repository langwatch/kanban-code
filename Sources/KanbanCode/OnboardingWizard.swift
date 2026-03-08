import SwiftUI
import KanbanCodeCore

struct OnboardingWizard: View {
    let settingsStore: SettingsStore
    var onComplete: () -> Void = {}

    @State private var currentStep = 0
    @State private var status: DependencyChecker.Status?
    @State private var enabledAssistants: Set<CodingAssistant> = Set(CodingAssistant.allCases)
    @State private var hookErrors: [CodingAssistant: String] = [:]
    @State private var pushoverEnabled = false
    @State private var pushoverToken = ""
    @State private var pushoverUserKey = ""
    @State private var testSending = false
    @State private var testResult: String?
    @State private var isChecking = false
    @State private var navigatingForward = true
    @State private var runningSessions: [CodingAssistant: Int] = [:]
    @State private var killedSessions: Set<CodingAssistant> = []
    @State private var renderMarkdownImage = false

    /// Steps are built dynamically: Welcome, Assistants, [per-assistant hooks...], Dependencies, Notifications, Complete.
    private var steps: [OnboardingStep] {
        var result: [OnboardingStep] = [.welcome, .assistants]
        // Add a hooks step for each enabled + available assistant
        for assistant in CodingAssistant.allCases {
            let available: Bool
            switch assistant {
            case .claude: available = status?.claudeAvailable ?? false
            case .gemini: available = status?.geminiAvailable ?? false
            }
            if available && enabledAssistants.contains(assistant) {
                result.append(.hooks(assistant))
            }
        }
        result.append(contentsOf: [.dependencies, .notifications, .complete])
        return result
    }

    private var totalSteps: Int { steps.count }

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(stepColor(for: step))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Step content
            Group {
                switch steps[min(currentStep, totalSteps - 1)] {
                case .welcome: welcomeStep
                case .assistants: assistantsStep
                case .hooks(let assistant): hooksStep(for: assistant)
                case .dependencies: dependenciesStep
                case .notifications: notificationsStep
                case .complete: completeStep
                }
            }
            .id(currentStep)
            .transition(.push(from: navigatingForward ? .trailing : .leading))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            Divider()

            // Navigation buttons
            HStack {
                if currentStep > 0 && currentStep < totalSteps - 1 {
                    Button("Back") {
                        navigatingForward = false
                        withAnimation(.easeInOut(duration: 0.3)) { currentStep -= 1 }
                    }
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    if currentStep > 0 {
                        Button("Skip") {
                            navigatingForward = true
                            withAnimation(.easeInOut(duration: 0.3)) { currentStep += 1 }
                        }
                        .foregroundStyle(.secondary)
                    }

                    Button(currentStep == 0 ? "Get Started" : "Continue") {
                        navigatingForward = true
                        withAnimation(.easeInOut(duration: 0.3)) { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Done") {
                        Task {
                            var settings = (try? await settingsStore.read()) ?? Settings()
                            settings.hasCompletedOnboarding = true
                            try? await settingsStore.write(settings)
                        }
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: 460)
        .task {
            await refreshStatus()
        }
        .onChange(of: enabledAssistants) {
            if currentStep >= totalSteps {
                currentStep = totalSteps - 1
            }
        }
    }

    private func stepColor(for step: Int) -> Color {
        if step == currentStep { return .accentColor }
        if step < currentStep { return .green }
        return .secondary.opacity(0.3)
    }

    // MARK: - Step: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "rectangle.3.group")
                .font(.app(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to Kanban")
                .font(.app(.title2))
                .fontWeight(.semibold)

            Text("Let's set up everything you need to manage your coding agent sessions.")
                .font(.app(.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Spacer()
        }
        .padding()
    }

    // MARK: - Step: Coding Assistants

    private var assistantsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                icon: "terminal",
                title: "Coding Assistants",
                description: "Kanban manages sessions from coding assistants. Enable the ones you want to use."
            )

            ForEach(CodingAssistant.allCases, id: \.self) { assistant in
                let available: Bool = {
                    switch assistant {
                    case .claude: status?.claudeAvailable ?? false
                    case .gemini: status?.geminiAvailable ?? false
                    }
                }()

                HStack {
                    Toggle(assistant.displayName, isOn: Binding(
                        get: { enabledAssistants.contains(assistant) },
                        set: { newValue in
                            if newValue {
                                enabledAssistants.insert(assistant)
                            } else {
                                enabledAssistants.remove(assistant)
                            }
                            saveEnabledAssistants()
                        }
                    ))
                    .font(.app(.callout))

                    Spacer()

                    if available {
                        Label("CLI Available", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.app(.caption))
                    } else {
                        Text("Not Installed")
                            .foregroundStyle(.orange)
                            .font(.app(.caption))
                    }
                }
            }

            let anyMissing = CodingAssistant.allCases.contains { assistant in
                guard enabledAssistants.contains(assistant) else { return false }
                switch assistant {
                case .claude: return !(status?.claudeAvailable ?? false)
                case .gemini: return !(status?.geminiAvailable ?? false)
                }
            }

            if anyMissing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install missing assistants:")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)

                    ForEach(CodingAssistant.allCases.filter { enabledAssistants.contains($0) }, id: \.self) { assistant in
                        let available: Bool = {
                            switch assistant {
                            case .claude: status?.claudeAvailable ?? false
                            case .gemini: status?.geminiAvailable ?? false
                            }
                        }()

                        if !available {
                            let command = assistant.installCommand
                            HStack {
                                Text(command)
                                    .font(.app(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(command, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("Copy to clipboard")
                            }
                        }
                    }

                    Text("Kanban works without assistants installed — columns will just be empty until sessions are created.")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                }

                recheckButton
            }

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Step: Hooks (per-assistant)

    private func hooksStep(for assistant: CodingAssistant) -> some View {
        let installed = status?.assistantHooks[assistant] ?? false
        let count = runningSessions[assistant] ?? 0
        let killed = killedSessions.contains(assistant)

        return VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                icon: "antenna.radiowaves.left.and.right",
                title: "\(assistant.displayName) Hooks",
                description: "Hooks let Kanban detect when \(assistant.displayName) starts, stops, or needs your attention."
            )

            statusCheckRow("Hooks installed", done: installed)

            if installed {
                Label("All hooks are installed and ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.app(.callout))

                // Check for pre-existing sessions that won't have hooks
                if count > 0 && !killed {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(count) \(assistant.displayName) session\(count == 1 ? "" : "s") running without hooks", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.app(.callout))

                        Text("These were started before hooks were installed and won't be tracked by Kanban. Kill them so they can be restarted with hooks.")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)

                        Button("Kill All \(assistant.displayName) Sessions") {
                            Task { await killRunningSessions(for: assistant) }
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                } else if killed {
                    Label("Old sessions killed — restart them to get full tracking", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.app(.callout))
                }
            } else {
                Button("Install Hooks") {
                    do {
                        try HookManager.install(for: assistant)
                        hookErrors[assistant] = nil
                        Task {
                            await refreshStatus()
                            await checkRunningSessions(for: assistant)
                        }
                    } catch {
                        hookErrors[assistant] = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)

                if let error = hookErrors[assistant] {
                    Text(error)
                        .font(.app(.caption))
                        .foregroundStyle(.red)
                }
            }

            Spacer()
        }
        .padding(24)
        .task {
            if status?.assistantHooks[assistant] == true {
                await checkRunningSessions(for: assistant)
            }
        }
    }

    private func checkRunningSessions(for assistant: CodingAssistant) async {
        do {
            let result = try await ShellCommand.run(
                "/bin/bash",
                arguments: ["-c", "pgrep -f '\\b\(assistant.cliCommand)\\b' | wc -l"]
            )
            runningSessions[assistant] = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        } catch {
            runningSessions[assistant] = 0
        }
    }

    private func killRunningSessions(for assistant: CodingAssistant) async {
        _ = try? await ShellCommand.run(
            "/usr/bin/pkill",
            arguments: ["-f", assistant.cliCommand]
        )
        killedSessions.insert(assistant)
        runningSessions[assistant] = 0
    }

    // MARK: - Step: Dependencies

    private var dependenciesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(
                icon: "shippingbox",
                title: "Dependencies",
                description: "Tools that Kanban Code needs for session management and GitHub integration."
            )

            Group {
                statusCheckRow("tmux", done: status?.tmuxAvailable ?? false)
                statusCheckRow("GitHub CLI (gh)", done: status?.ghAvailable ?? false)
                if status?.ghAvailable == true && !(status?.ghAuthenticated ?? false) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("gh is installed but not logged in. Run")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                        Text("gh auth login")
                            .font(.app(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text("in a terminal.")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 24)
                }
            }

            if let command = brewInstallCommand {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install missing dependencies:")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(command)
                            .font(.app(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy to clipboard")
                    }
                }
            }

            recheckButton

            Spacer()
        }
        .padding(24)
    }

    private var brewInstallCommand: String? {
        var packages: [String] = []
        if !(status?.tmuxAvailable ?? false) { packages.append("tmux") }
        if !(status?.ghAvailable ?? false) { packages.append("gh") }
        guard !packages.isEmpty else { return nil }
        return "brew install \(packages.joined(separator: " "))"
    }

    // MARK: - Step: Notifications

    private var notificationsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stepHeader(
                    icon: "bell.badge",
                    title: "Notifications",
                    description: "Get notified when your coding assistant stops and needs your input."
                )

                statusCheckRow("macOS Notifications", done: true)

                Toggle("Enable Pushover (mobile push notifications)", isOn: $pushoverEnabled)

                if pushoverEnabled {
                    TextField("App Token", text: $pushoverToken)
                        .textFieldStyle(.roundedBorder)
                    TextField("User Key", text: $pushoverUserKey)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button {
                            testPushover()
                        } label: {
                            HStack(spacing: 4) {
                                if testSending {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "play.circle")
                                }
                                Text("Send Test")
                            }
                        }
                        .controlSize(.small)
                        .disabled(pushoverToken.isEmpty || pushoverUserKey.isEmpty || testSending)

                        if let testResult {
                            Text(testResult)
                                .font(.app(.caption))
                                .foregroundStyle(testResult.contains("Sent") ? .green : .red)
                        }
                    }

                    Text("Get your keys at pushover.net")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)

                    Divider()
                        .padding(.vertical, 4)

                    Toggle("Render full output as markdown image", isOn: $renderMarkdownImage)
                        .disabled(pushoverToken.isEmpty || pushoverUserKey.isEmpty)

                    if pushoverToken.isEmpty || pushoverUserKey.isEmpty {
                        Text("Enter Pushover credentials above to enable this option.")
                            .font(.app(.caption))
                            .foregroundStyle(.tertiary)
                } else if renderMarkdownImage {
                    Group {
                        statusCheckRow("pandoc", done: status?.pandocAvailable ?? false)
                        statusCheckRow("wkhtmltoimage", done: status?.wkhtmltoimageAvailable ?? false)
                    }

                    if !(status?.pandocAvailable ?? false) {
                        Text("brew install pandoc")
                            .font(.app(.caption, design: .monospaced))
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }

                    if !(status?.wkhtmltoimageAvailable ?? false) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("wkhtmltopdf is no longer in Homebrew. Install it manually:")
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                            Link("Download wkhtmltox-0.12.6-2.macos-cocoa.pkg",
                                 destination: URL(string: "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-2/wkhtmltox-0.12.6-2.macos-cocoa.pkg")!)
                                .font(.app(.caption, design: .monospaced))
                        }
                    }

                    recheckButton
                }
                } // end if pushoverEnabled
            }
            .padding(24)
        }
        .task {
            if let settings = try? await settingsStore.read() {
                pushoverEnabled = settings.notifications.pushoverEnabled
                pushoverToken = settings.notifications.pushoverToken ?? ""
                pushoverUserKey = settings.notifications.pushoverUserKey ?? ""
                renderMarkdownImage = settings.notifications.renderMarkdownImage
            }
        }
        .onDisappear {
            Task {
                var settings = (try? await settingsStore.read()) ?? Settings()
                settings.notifications.pushoverEnabled = pushoverEnabled
                settings.notifications.pushoverToken = pushoverToken.isEmpty ? nil : pushoverToken
                settings.notifications.pushoverUserKey = pushoverUserKey.isEmpty ? nil : pushoverUserKey
                settings.notifications.renderMarkdownImage = renderMarkdownImage
                try? await settingsStore.write(settings)
            }
        }
    }

    // MARK: - Step: Complete

    private var completeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                stepHeader(
                    icon: "checkmark.seal",
                    title: "Setup Complete",
                    description: "Here's a summary of your configuration."
                )

                Group {
                    ForEach(CodingAssistant.allCases, id: \.self) { assistant in
                        let available: Bool = {
                            switch assistant {
                            case .claude: status?.claudeAvailable ?? false
                            case .gemini: status?.geminiAvailable ?? false
                            }
                        }()
                        summaryRow(assistant.displayName, status: available)
                        if available {
                            summaryRow("  \(assistant.displayName) Hooks", status: status?.assistantHooks[assistant] ?? false)
                        }
                    }
                    summaryRow("Pushover", status: status?.pushoverConfigured ?? false)
                    summaryRow("tmux", status: status?.tmuxAvailable ?? false)
                    summaryRow("GitHub CLI", status: status?.ghAuthenticated ?? false)
                }

                Text("You can always reopen this wizard from Settings → General.")
                    .font(.app(.caption))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(24)
        }
        .task { await refreshStatus() }
    }

    // MARK: - Helpers

    private func stepHeader(icon: String, title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.app(.title3))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.app(.title3))
                    .fontWeight(.semibold)
            }
            Text(description)
                .font(.app(.callout))
                .foregroundStyle(.secondary)
        }
    }

    private func statusCheckRow(_ name: String, done: Bool) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            Text(name)
                .font(.app(.callout))
            Spacer()
            Text(done ? "Ready" : "Not set up")
                .font(.app(.caption))
                .foregroundStyle(done ? .green : .orange)
        }
    }

    private func summaryRow(_ name: String, status: Bool) -> some View {
        HStack {
            Image(systemName: status ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(status ? .green : .orange)
            Text(name)
                .font(.app(.callout))
            Spacer()
        }
    }

    private var recheckButton: some View {
        Button {
            isChecking = true
            Task {
                await refreshStatus()
                isChecking = false
            }
        } label: {
            HStack(spacing: 4) {
                if isChecking {
                    ProgressView().controlSize(.mini)
                }
                Text("Re-check")
            }
        }
        .controlSize(.small)
    }

    private func refreshStatus() async {
        status = await DependencyChecker.checkAll(settingsStore: settingsStore)
        // Load enabled assistants from settings
        if let settings = try? await settingsStore.read() {
            enabledAssistants = Set(settings.enabledAssistants)
        }
    }

    private func saveEnabledAssistants() {
        Task {
            var settings = (try? await settingsStore.read()) ?? Settings()
            settings.enabledAssistants = CodingAssistant.allCases.filter { enabledAssistants.contains($0) }
            try? await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }

    private func testPushover() {
        testSending = true
        testResult = nil
        Task {
            do {
                let client = PushoverClient(token: pushoverToken, userKey: pushoverUserKey)
                try await client.sendNotification(
                    title: "Kanban Test",
                    message: "Notifications are working!",
                    imageData: nil,
                    cardId: nil
                )
                testResult = "Sent!"
            } catch {
                testResult = "Failed"
            }
            testSending = false
        }
    }
}

/// Dynamic onboarding steps — hooks steps are added per available assistant.
private enum OnboardingStep: Hashable {
    case welcome
    case assistants
    case hooks(CodingAssistant)
    case dependencies
    case notifications
    case complete
}
