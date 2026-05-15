import Foundation

/// Errors from image sending operations.
public enum ImageSendError: Error, LocalizedError {
    case assistantNotReady(CodingAssistant)
    case imageUploadTimeout(expected: Int, assistant: CodingAssistant)

    public var errorDescription: String? {
        switch self {
        case .assistantNotReady(let assistant):
            "\(assistant.displayName) did not become ready within the timeout period"
        case .imageUploadTimeout(let n, let assistant):
            "Timed out waiting for image #\(n) to be accepted by \(assistant.displayName)"
        }
    }
}

/// Orchestrates sending images to a Claude Code session via tmux.
///
/// For each image:
/// 1. Sets the system clipboard to the image data (via injected closure)
/// 2. Sends an empty bracketed paste event to the tmux session
/// 3. Polls `tmux capture-pane` until Claude confirms the image with `[Image #N]`
public actor ImageSender {
    private let tmux: TmuxManagerPort

    public init(tmux: TmuxManagerPort) {
        self.tmux = tmux
    }

    /// Wait for the coding assistant to show its input prompt.
    public func waitForReady(
        sessionName: String,
        assistant: CodingAssistant = .claude,
        pollInterval: Duration = .milliseconds(500),
        timeout: Duration? = nil
    ) async throws {
        // Gemini and Codex can take longer to start (auth checks, banners, model setup).
        let effectiveTimeout = timeout ?? (assistant == .gemini || assistant == .codex ? .seconds(60) : .seconds(30))
        let start = ContinuousClock.now
        while ContinuousClock.now - start < effectiveTimeout {
            let output = try await tmux.capturePane(sessionName: sessionName)
            if PaneOutputParser.isReady(output, assistant: assistant) { return }
            try await Task.sleep(for: pollInterval)
        }
        throw ImageSendError.assistantNotReady(assistant)
    }

    /// Send images one by one, confirming each before sending the next.
    ///
    /// - Parameters:
    ///   - sessionName: tmux session target
    ///   - images: images to send
    ///   - setClipboard: closure that sets the system clipboard to image data (injected for testability)
    ///   - pollInterval: how often to check for confirmation
    ///   - timeout: max time to wait per image
    public func sendImages(
        sessionName: String,
        images: [ImageAttachment],
        assistant: CodingAssistant = .claude,
        setClipboard: @Sendable (Data) -> Void,
        pollInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(30)
    ) async throws {
        for (index, image) in images.enumerated() {
            // Count before sending
            let before = try await tmux.capturePane(sessionName: sessionName)
            let countBefore = PaneOutputParser.countImages(in: before)

            setClipboard(image.data)
            try await tmux.sendBracketedPaste(to: sessionName)

            // Poll until count goes up
            let start = ContinuousClock.now
            while ContinuousClock.now - start < timeout {
                try await Task.sleep(for: pollInterval)
                let output = try await tmux.capturePane(sessionName: sessionName)
                if PaneOutputParser.countImages(in: output) > countBefore {
                    break
                }
                if ContinuousClock.now - start >= timeout {
                    throw ImageSendError.imageUploadTimeout(expected: index + 1, assistant: assistant)
                }
            }
        }
    }

    /// Send a text prompt with image attachments as one user turn.
    ///
    /// Image placeholders in `prompt` (`[Image #1]`, `[Image #2]`, ...) are
    /// replaced by image paste events at the same position. If no placeholders
    /// are present, images are appended after the text for backwards
    /// compatibility with older stored prompts.
    public func sendPromptWithImages(
        sessionName: String,
        prompt: String,
        images: [ImageAttachment],
        assistant: CodingAssistant = .claude,
        setClipboard: @Sendable (Data) -> Void,
        pollInterval: Duration = .milliseconds(500),
        timeout: Duration = .seconds(30)
    ) async throws {
        let parts = PromptImageLayout.parts(in: prompt, imageCount: images.count)
        let hasInlineImages = parts.contains { $0.imageIndex != nil }

        if hasInlineImages {
            for part in parts {
                if let imageIndex = part.imageIndex {
                    try await sendImages(
                        sessionName: sessionName,
                        images: [images[imageIndex]],
                        assistant: assistant,
                        setClipboard: setClipboard,
                        pollInterval: pollInterval,
                        timeout: timeout
                    )
                } else if !part.text.isEmpty {
                    try await tmux.pasteText(to: sessionName, text: part.text)
                }
            }
        } else {
            if !prompt.isEmpty {
                try await tmux.pasteText(to: sessionName, text: prompt)
            }
            if !images.isEmpty {
                try await sendImages(
                    sessionName: sessionName,
                    images: images,
                    assistant: assistant,
                    setClipboard: setClipboard,
                    pollInterval: pollInterval,
                    timeout: timeout
                )
            }
        }

        if !prompt.isEmpty || !images.isEmpty {
            try await tmux.submitPrompt(to: sessionName)
        }
    }
}
