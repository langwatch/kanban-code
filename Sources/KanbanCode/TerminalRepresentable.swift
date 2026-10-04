import SwiftUI
import AppKit
import SwiftTerm
import KanbanCodeCore

// MARK: - Batched terminal view

/// Subclass that batches incoming pty data before feeding it to the terminal.
/// SwiftTerm's default path feeds each pty read (often tiny chunks) individually,
/// triggering a display update per chunk. This batches all data arriving within
/// a short window into a single feed, dramatically reducing redraws during
/// tmux resize/repaint and making scrolling feel instant like Warp.
///
/// LocalProcess dispatches each read via dispatchQueue.sync, so plain
/// DispatchQueue.main.async runs between chunks (FIFO). We use asyncAfter
/// with a short delay so multiple chunks accumulate before flushing.
final class BatchedTerminalView: LocalProcessTerminalView {
    /// The tmux session this terminal shows, used to find its machine.
    var kanbanSession: String?

    private var pendingData: [UInt8] = []
    private var flushScheduled = false
    private var lastPendingDataWarningAt: CFTimeInterval = 0

    // Strategy: for small interactive responses (typing, cursor moves), render
    // immediately. For heavy streaming (Claude output), batch and drop frames.
    private static let batchDelay: DispatchTimeInterval = .milliseconds(32)  // 2 frames
    private static let chunkSize = 16 * 1024
    private static let maxBlockSeconds: Double = 0.008  // 8ms budget

    // Keep the last 32KB — enough for a full screen repaint with escape sequences.
    private static let keepBytes = 32 * 1024

    /// Hard caps on the pending buffer, enforced at append time. Normal mode
    /// tail-drops to `keepBytes` at flush, but nothing bounds the buffer
    /// between flushes; passthrough (copy-mode) has no drop at all, so a
    /// process flooding output while the user sits in copy-mode would grow
    /// the buffer without limit. Beyond the cap the oldest bytes go — tmux
    /// repaints the current screen state, so nothing is lost visually.
    private static let normalMaxPendingBytes = 4 * 1024 * 1024
    private static let passthroughMaxPendingBytes = 64 * 1024 * 1024

    /// Threshold: data chunks smaller than this are interactive (typing, cursor moves)
    /// and should be rendered immediately without batching delay.
    private static let interactiveThreshold = 256

    private var pendingOffset = 0
    private var scheduledFlushTime: UInt64 = 0

    /// When true, disables aggressive frame dropping (copy-mode, interactive scrolling).
    var passthroughMode = false

    /// Never drops output. Set for programs that redraw only what changed
    /// (rush), where a dropped byte stays on screen as a broken line.
    /// tmux repaints the whole screen, so its terminals can skip frames.
    var lossless = false

    private var dropsFrames: Bool { !passthroughMode && !lossless }

    // Stats collection
    private var statsReceiveCount = 0
    private var statsReceiveBytes = 0
    private var statsFlushCount = 0
    private var statsFeedCalls = 0
    private var statsFeedBytes = 0
    private var statsFeedTimeMs: Double = 0
    private var statsMaxFeedMs: Double = 0
    private var statsDropCount = 0
    private var statsDropBytes = 0
    private var statsYieldCount = 0
    private var statsMaxBacklog = 0
    private var statsStartTime = CACurrentMediaTime()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        pendingData.append(contentsOf: slice)
        statsReceiveCount += 1
        statsReceiveBytes += slice.count
        if pendingData.count - pendingOffset > statsMaxBacklog {
            statsMaxBacklog = pendingData.count - pendingOffset
        }

        // Enforce the hard cap up front so the buffer can't balloon no matter
        // how delayed the flush is. Cut on a newline boundary when one is
        // near, like the flush-time drop, to avoid splitting escape sequences.
        let hardCap = dropsFrames ? Self.normalMaxPendingBytes : Self.passthroughMaxPendingBytes
        if pendingData.count - pendingOffset > hardCap {
            var cutPoint = pendingData.count - hardCap
            let scanLimit = min(cutPoint + 1024, pendingData.count)
            while cutPoint < scanLimit && pendingData[cutPoint] != 0x0A { cutPoint += 1 }
            if cutPoint < scanLimit { cutPoint += 1 }
            if cutPoint > pendingOffset {
                statsDropCount += 1
                statsDropBytes += cutPoint - pendingOffset
                pendingData.removeSubrange(0..<cutPoint)
                pendingOffset = 0
            }
        }

        let totalPending = pendingData.count - pendingOffset
        if totalPending > 8 * 1024 * 1024 {
            let now = CACurrentMediaTime()
            if now - lastPendingDataWarningAt > 10 {
                lastPendingDataWarningAt = now
                KanbanCodeLog.warn(
                    "memory-context",
                    "terminal pendingData=\(totalPending / 1024)KiB passthrough=\(passthroughMode)"
                )
            }
        }

        // Small chunks (typing, cursor moves): feed directly on this main-thread
        // call — zero scheduling overhead for instant keystroke response.
        // Large chunks (Claude streaming): batch to avoid frame-per-byte overhead.
        // A lossless program (rush) paces its own frames, so each one is
        // drawn as it arrives instead of waiting for the batch timer.
        if (totalPending <= Self.interactiveThreshold || lossless) && !flushScheduled {
            // Feed directly — we're already on main thread (LocalProcess dispatches here).
            // This avoids DispatchQueue.main.async latency from pending SwiftUI layout work.
            statsFlushCount += 1
            statsFeedCalls += 1
            statsFeedBytes += totalPending
            let chunk = pendingData[pendingOffset...]
            feed(byteArray: chunk)
            pendingData.removeAll(keepingCapacity: true)
            pendingOffset = 0
        } else {
            // Batched: reset the flush timer on every data arrival.
            let now = DispatchTime.now().uptimeNanoseconds
            let delay: UInt64 = passthroughMode ? 8_000_000 : 32_000_000 // 8ms or 32ms
            scheduledFlushTime = now + delay

            if !flushScheduled {
                flushScheduled = true
                let deadline: DispatchTimeInterval = passthroughMode ? .milliseconds(8) : Self.batchDelay
                DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
                    self?.checkAndProcess()
                }
            }
        }
    }

    /// Only process if enough time has passed since the last data arrival.
    /// If data is still flowing, reschedule.
    private func checkAndProcess() {
        let now = DispatchTime.now().uptimeNanoseconds
        if now < scheduledFlushTime {
            // Data arrived recently — wait more
            DispatchQueue.main.asyncAfter(
                deadline: DispatchTime(uptimeNanoseconds: scheduledFlushTime)
            ) { [weak self] in
                self?.checkAndProcess()
            }
            return
        }
        processNextChunk()
    }

    private func processNextChunk() {
        guard pendingOffset < pendingData.count else {
            pendingData.removeAll(keepingCapacity: true)
            pendingOffset = 0
            flushScheduled = false
            return
        }

        // In normal mode, skip to the tail — only the final screen state matters.
        // In passthrough mode (copy-mode), render everything for smooth scrolling.
        let backlog = pendingData.count - pendingOffset
        if dropsFrames && backlog > Self.keepBytes {
            var cutPoint = pendingData.count - Self.keepBytes
            let scanLimit = min(cutPoint + 1024, pendingData.count)
            while cutPoint < scanLimit && pendingData[cutPoint] != 0x0A { cutPoint += 1 }
            if cutPoint < scanLimit { cutPoint += 1 }
            if cutPoint > pendingOffset {
                statsDropCount += 1
                statsDropBytes += cutPoint - pendingOffset
                pendingOffset = cutPoint
            }
        }

        statsFlushCount += 1
        let start = CACurrentMediaTime()

        while pendingOffset < pendingData.count {
            let remaining = pendingData.count - pendingOffset
            let count = min(Self.chunkSize, remaining)
            let chunk = pendingData[pendingOffset..<(pendingOffset + count)]

            let feedStart = CACurrentMediaTime()
            feed(byteArray: chunk)
            let feedMs = (CACurrentMediaTime() - feedStart) * 1000
            statsFeedCalls += 1
            statsFeedBytes += count
            statsFeedTimeMs += feedMs
            if feedMs > statsMaxFeedMs { statsMaxFeedMs = feedMs }

            pendingOffset += count

            if pendingOffset < pendingData.count && CACurrentMediaTime() - start > Self.maxBlockSeconds {
                statsYieldCount += 1
                DispatchQueue.main.async { [weak self] in
                    self?.processNextChunk()
                }
                return
            }
        }

        pendingData.removeAll(keepingCapacity: true)
        pendingOffset = 0
        flushScheduled = false

        // Print stats every 10 seconds — file I/O on background queue to avoid hitches
        let elapsed = CACurrentMediaTime() - statsStartTime
        if elapsed > 10 {
            let avgFeedMs = statsFeedCalls > 0 ? statsFeedTimeMs / Double(statsFeedCalls) : 0
            let line = String(format: "[TermStats] %.0fs | recv: %d calls %dKB | flush: %d | feed: %d calls %dKB avg:%.2fms max:%.1fms | yields: %d | maxBacklog: %dKB | dropped: %d %dKB\n",
                  elapsed, statsReceiveCount, statsReceiveBytes/1024,
                  statsFlushCount, statsFeedCalls, statsFeedBytes/1024,
                  avgFeedMs, statsMaxFeedMs, statsYieldCount,
                  statsMaxBacklog/1024, statsDropCount, statsDropBytes/1024)
            DispatchQueue.global(qos: .utility).async {
                let logPath = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code/logs/terminal-stats.log")
                if let data = line.data(using: .utf8) {
                    if let fh = FileHandle(forWritingAtPath: logPath) {
                        fh.seekToEndOfFile()
                        fh.write(data)
                        try? fh.close()
                    } else {
                        try? data.write(to: URL(fileURLWithPath: logPath))
                    }
                }
            }
            // Reset
            statsReceiveCount = 0; statsReceiveBytes = 0; statsFlushCount = 0
            statsFeedCalls = 0; statsFeedBytes = 0; statsFeedTimeMs = 0
            statsMaxFeedMs = 0; statsYieldCount = 0; statsMaxBacklog = 0
            statsDropCount = 0; statsDropBytes = 0; statsStartTime = CACurrentMediaTime()
        }
    }

    // MARK: - Copy

    /// With nothing selected here and the program drawing its own selection
    /// (it asked for the mouse), cmd+c goes to the program as a kitty-encoded
    /// super+c, so rush copies what was dragged over.
    override func copy(_ sender: Any) {
        if (getSelection() ?? "").isEmpty, terminal.mouseMode != .off {
            send(txt: "\u{1b}[99;9u")
            return
        }
        super.copy(sender)
    }

    /// Copy stays enabled while the program has the mouse: its selection is
    /// its own, so an empty one here doesn't mean there's nothing to copy.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)), terminal.mouseMode != .off { return true }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - Paste fix

    /// Override paste to always send bracketed paste codes. With our async+dropping
    /// batching, the escape sequence that enables bracketedPasteMode may be processed
    /// late, causing terminal.bracketedPasteMode to be false when the user pastes.
    /// Claude Code always expects bracketed paste for image detection.
    override func paste(_ sender: Any) {
        let clipboard = NSPasteboard.general
        let text = clipboard.string(forType: .string)
        if text == nil, let session = enclosingSessionName(),
           case .upload(let route) = TerminalPastePlan.plan(
               hasText: false, hasImage: Self.hasImage(clipboard), route: AppServices.terminalImageRoute(forSession: session)),
           let data = Self.pngData(from: clipboard),
           pasteImage(data, session: session, route: route) {
            return
        }
        sendBracketedPaste(text: text ?? "")
    }

    private func sendBracketedPaste(text: String) {
        // Always send bracketed paste codes — Claude Code needs them for image detection.
        // Raw bytes for \e[200~ and \e[201~ to avoid Swift 6 concurrency issues
        // with EscapeSequences static properties.
        let pasteStart: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e] // \e[200~
        let pasteEnd: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]   // \e[201~
        send(data: pasteStart[0...])
        if !text.isEmpty {
            send(txt: text)
        }
        send(data: pasteEnd[0...])
    }

    /// An image pasted into the terminal of a session that runs somewhere
    /// else. The assistant there reads the clipboard of its own machine,
    /// which has nothing, so the bytes go to that machine and the paste
    /// types the path of the file there, as a dropped file does. False when
    /// nothing can carry the bytes.
    private func pasteImage(_ data: Data, session: String, route: TerminalImageRoute) -> Bool {
        switch route {
        case .local:
            return false
        case .peer(let machineId, let cardId):
            let engine = AppComposition.shared.engine
            Task { [weak self] in
                do {
                    let remotePath = try await engine.uploadPastedImage(cardId: cardId, data: data)
                    // Typed through the terminal's own stream to the owner,
                    // the way keystrokes go.
                    self?.sendBracketedPaste(text: remotePath + " ")
                } catch {
                    Self.reportPasteFailure(session: session, place: engine.peerDisplayName(machineId), error: error)
                }
            }
            return true
        case .machine(let machine):
            guard let supervisor = AppServices.boxdSupervisor else { return false }
            Task {
                do {
                    let remotePath = try await supervisor.uploadPastedImage(machineName: machine, data: data)
                    // Pasted through the tmux server of the machine, which runs
                    // after the upload on the same bridge, so the assistant
                    // finds the file when it checks the pasted path.
                    try await AppServices.tmux.pasteText(to: session, text: remotePath + " ")
                } catch {
                    Self.reportPasteFailure(session: session, place: machine, error: error)
                }
            }
            return true
        }
    }

    /// Says in the terminal and in the app's banner that the image did not
    /// arrive, so the paste does not look like it did nothing.
    private static func reportPasteFailure(session: String, place: String, error: Error) {
        let message = "Could not paste the image on \(place): \(error.localizedDescription)"
        KanbanCodeLog.warn("terminal", message)
        TerminalCache.shared.showNotice(message, sessions: [session])
        AppComposition.shared.store.dispatch(.setError(message))
    }

    private static func hasImage(_ clipboard: NSPasteboard) -> Bool {
        clipboard.availableType(from: [.png, .tiff]) != nil
    }

    private func enclosingSessionName() -> String? {
        var view: NSView? = self
        while let current = view, !(current is TerminalContainerNSView) {
            view = current.superview
        }
        return (view as? TerminalContainerNSView)?.activeSession
    }

    /// PNG bytes of the image on the pasteboard; a screenshot arrives as TIFF.
    private static func pngData(from clipboard: NSPasteboard) -> Data? {
        if let png = clipboard.data(forType: .png) { return png }
        guard let tiff = clipboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Cmd+hover URL detection

    /// GitHub base URL for the card's project (e.g. "https://github.com/owner/repo").
    /// Set by TerminalContainerNSView when the terminal is shown.
    var githubBaseURL: String?

    /// Currently highlighted URL range for underline drawing.
    private var highlightedURL: (screenRow: Int, colStart: Int, colEnd: Int, url: String)?
    private var urlHighlightLayer: CAShapeLayer?
    private var isCommandHeld = false
    private var urlEventMonitor: Any?
    private var linkClickGate = CommandClickGate()

    /// The link under the pointer of a mouse event, if the pointer is over
    /// this terminal and on one.
    private func linkURL(at event: NSEvent) -> String? {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return nil }
        let pos = screenPosition(from: event)
        return detectURL(col: pos.col, screenRow: pos.screenRow)?.url
    }

    func installURLMonitor() {
        guard urlEventMonitor == nil else { return }
        urlEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self,
                  !self.isHidden,
                  self.window == event.window else { return event }
            // The drag and release of a kept cmd+press are handled wherever
            // the pointer goes, so the program never sees half of the click.
            let keptPress = self.linkClickGate.pressedLink != nil
                && (event.type == .leftMouseDragged || event.type == .leftMouseUp)
            // For mouse events, check the mouse is actually over this view
            if event.type != .flagsChanged, !keptPress {
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else {
                    // Mouse left this terminal — clear any highlight
                    if self.highlightedURL != nil { self.clearURLHighlight() }
                    return event
                }
            }
            return self.handleURLEvent(event)
        }
    }

    func removeURLMonitor() {
        if let monitor = urlEventMonitor {
            NSEvent.removeMonitor(monitor)
            urlEventMonitor = nil
        }
        linkClickGate = CommandClickGate()
        clearURLHighlight()
    }

    private func handleURLEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            isCommandHeld = event.modifierFlags.contains(.command)
            if isCommandHeld {
                let pos = screenPosition(from: event)
                updateURLHighlight(col: pos.col, screenRow: pos.screenRow)
            } else {
                clearURLHighlight()
            }
            return event

        case .mouseMoved:
            if isCommandHeld {
                let pos = screenPosition(from: event)
                updateURLHighlight(col: pos.col, screenRow: pos.screenRow)
            }
            return event

        case .leftMouseDown:
            let command = event.modifierFlags.contains(.command)
            let link = command ? linkURL(at: event) : nil
            return linkClickGate.mouseDown(command: command, link: link) == .pass ? event : nil

        case .leftMouseDragged:
            return linkClickGate.mouseDragged() == .pass ? event : nil

        case .leftMouseUp:
            let link = linkClickGate.pressedLink == nil ? nil : linkURL(at: event)
            switch linkClickGate.mouseUp(link: link) {
            case .pass:
                return event
            case .consume:
                return nil
            case .open(let raw):
                clearURLHighlight()
                // File paths: use URL(fileURLWithPath:) to handle +, spaces, etc.
                if raw.hasPrefix("/"), FileManager.default.fileExists(atPath: raw) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: raw))
                } else if let url = URL(string: raw) {
                    NSWorkspace.shared.open(url)
                }
                return nil
            }

        default:
            return event
        }
    }

    /// Cell dimensions matching SwiftTerm's internal calculation.
    private var cellSize: CGSize {
        let f = font
        let glyph = f.glyph(withName: "W")
        let cw = f.advancement(forGlyph: glyph).width
        let ch = ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f))
        return CGSize(width: max(1, cw), height: max(1, ch))
    }

    /// Compute screen row (0-based from top) and col from mouse event.
    private func screenPosition(from event: NSEvent) -> (col: Int, screenRow: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let cols = terminal.cols
        let rows = terminal.rows
        guard cols > 0, rows > 0 else { return (0, 0) }
        let cs = cellSize
        let col = min(max(0, Int(point.x / cs.width)), cols - 1)
        let screenRow = min(max(0, Int((bounds.height - point.y) / cs.height)), rows - 1)
        return (col, screenRow)
    }

    /// Extract the URL under the cursor at the given screen position, if any.
    /// Also detects GitHub issue/PR references like `owner/repo#123` or bare `#123`.
    private func detectURL(col: Int, screenRow: Int) -> (url: String, colStart: Int, colEnd: Int)? {
        guard let line = terminal.getLine(row: screenRow) else { return nil }

        // An OSC 8 hyperlink carries its own destination, so it wins over
        // anything read out of the text: the label of one rarely looks like a
        // URL, and where it does look like a reference the guess we would make
        // from it can point somewhere else entirely.
        let cols = min(terminal.cols, line.count)
        if let hyperlink = TerminalURLDetector.hyperlink(
            cols: cols, col: col, payloadAt: { line[$0].getPayload() as? String })
        {
            return (hyperlink.url, hyperlink.colStart, hyperlink.colEnd)
        }

        let text = line.translateToString(trimRight: true)
        guard let detection = TerminalURLDetector.detect(in: text, col: col, githubBaseURL: githubBaseURL) else {
            return nil
        }
        return (detection.url, detection.colStart, detection.colEnd)
    }

    private func updateURLHighlight(col: Int, screenRow: Int) {
        if let detected = detectURL(col: col, screenRow: screenRow) {
            if highlightedURL?.screenRow == screenRow,
               highlightedURL?.colStart == detected.colStart,
               highlightedURL?.colEnd == detected.colEnd { return }
            highlightedURL = (screenRow, detected.colStart, detected.colEnd, detected.url)
            drawURLHighlight(screenRow: screenRow, colStart: detected.colStart, colEnd: detected.colEnd)
            NSCursor.pointingHand.set()
        } else {
            clearURLHighlight()
        }
    }

    private func drawURLHighlight(screenRow: Int, colStart: Int, colEnd: Int) {
        urlHighlightLayer?.removeFromSuperlayer()
        let cs = cellSize
        let x = CGFloat(colStart) * cs.width
        // macOS origin is bottom-left; screenRow 0 = top of terminal
        let y = bounds.height - CGFloat(screenRow + 1) * cs.height
        let w = CGFloat(colEnd - colStart + 1) * cs.width

        let layer = CAShapeLayer()
        let underlineY = y + 1.0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: underlineY))
        path.addLine(to: CGPoint(x: x + w, y: underlineY))
        layer.path = path
        layer.strokeColor = NSColor.linkColor.cgColor
        layer.lineWidth = 1
        layer.fillColor = nil

        self.wantsLayer = true
        self.layer?.addSublayer(layer)
        urlHighlightLayer = layer
    }

    private func clearURLHighlight() {
        guard highlightedURL != nil else { return }
        highlightedURL = nil
        urlHighlightLayer?.removeFromSuperlayer()
        urlHighlightLayer = nil
        NSCursor.arrow.set()
    }

}

// MARK: - Terminal process cache

/// Caches tmux terminal views across drawer close/open cycles.
/// When the drawer closes, terminals are detached from the view hierarchy but kept alive.
/// When reopened, the cached terminal is reparented — no new tmux attach needed,
/// preserving scrollback and terminal state.
@MainActor
final class TerminalCache {
    static let shared = TerminalCache()
    static let defaultFontSize: CGFloat = 12
    static let fontSizeKey = "sessionDetailFontSize"

    private var terminals: [String: BatchedTerminalView] = [:]
    private var shiftEnterMonitor: Any?
    private var scrollWheelMonitor: Any?
    private var fontSizeObserver: Any?
    private var lastLoggedTerminalCount = 0

    private var currentFontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: TerminalCache.fontSizeKey)
        return stored > 0 ? CGFloat(stored) : TerminalCache.defaultFontSize
    }()

    /// Find the active (visible) session name for the terminal under the given window point.
    /// Bypasses hitTest which can be intercepted by SwiftUI overlay views.
    /// Checks both isHidden and effective opacity (parent container may be opacity 0).
    func sessionUnderPoint(_ windowPoint: NSPoint, in window: NSWindow) -> String? {
        for (sessionName, terminal) in terminals {
            guard !terminal.isHidden,
                  terminal.window == window else { continue }
            // Check if any ancestor has opacity 0 (e.g. when browser tab is selected)
            var view: NSView? = terminal.superview
            var effectivelyHidden = false
            while let v = view {
                if v.alphaValue < 0.01 { effectivelyHidden = true; break }
                view = v.superview
            }
            guard !effectivelyHidden else { continue }
            let localPoint = terminal.convert(windowPoint, from: nil)
            if terminal.bounds.contains(localPoint) {
                return sessionName
            }
        }
        return nil
    }

    /// How many overlays are currently drawn over the board and own the scroll
    /// wheel themselves.
    ///
    /// Scroll interception is an application-wide event monitor, and it decides
    /// what a scroll belongs to from the terminal's frame rather than from a hit
    /// test, so anything drawn on top of a terminal is invisible to it: it eats
    /// the wheel and spends it driving tmux copy-mode in the terminal
    /// underneath. A counter rather than a flag, so two overlays open at once
    /// cannot have the first one to close speak for the second.
    private var scrollPassthroughDepth = 0

    var passesScrollThrough: Bool { self.scrollPassthroughDepth > 0 }

    func beginScrollPassthrough() {
        self.scrollPassthroughDepth += 1
    }

    func endScrollPassthrough() {
        self.scrollPassthroughDepth = max(0, self.scrollPassthroughDepth - 1)
    }

    /// Tracks tmux copy-mode state per session for scroll interception.
    fileprivate var copyModeSessions: Set<String> = []

    /// Cooldown: after exiting copy-mode, ignore scroll events briefly
    /// to prevent residual momentum from re-entering copy-mode.
    fileprivate var copyModeExitTime: [String: ContinuousClock.Instant] = [:]

    /// Wheel ticks of a session on a machine, summed until the next flush.
    /// Each command to a machine is a round trip over the bridge, so one
    /// command carries the ticks of the last 60 ms instead of one per tick.
    private var remoteScrollPending: [String: Int] = [:]
    private var remoteScrollEnter: Set<String> = []
    private var remoteScrollFlush: [String: Task<Void, Never>] = [:]

    private init() {
        let tmux = Self.tmuxPath

        // Intercept keyDown events in terminal views for two purposes:
        // 1. Shift+Enter → send \n instead of \r (Claude Code newline vs submit)
        // 2. Any key while in tmux copy-mode → exit copy-mode first, then let key through
        shiftEnterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let terminal = event.window?.firstResponder as? TerminalView else { return event }

            // Shift+Enter: send newline instead of carriage return
            if event.keyCode == 36, event.modifierFlags.contains(.shift) {
                terminal.send([0x0a])
                return nil
            }

            guard let self else { return event }

            // Find the session for this terminal
            var view: NSView? = terminal
            while let v = view, !(v is TerminalContainerNSView) {
                view = v.superview
            }
            guard let container = view as? TerminalContainerNSView,
                  let session = container.activeSession else { return event }

            // If in copy-mode, exit it on any non-modifier keypress.
            // Uses -X cancel (copy-mode command) — no-op if already exited, never leaks.
            if self.copyModeSessions.contains(session) {
                // Ignore keys with Cmd/Opt/Ctrl held — let the system handle them
                // (e.g. Cmd+C for copy, Cmd+V for paste).
                let modifiers = event.modifierFlags.intersection([.command, .option, .control])
                guard modifiers.isEmpty else { return event }

                self.copyModeSessions.remove(session)
                self.copyModeExitTime[session] = .now
                self.terminals[session]?.passthroughMode = false

                // Esc just dismisses scroll mode — don't forward it to the shell.
                // The command must reach the server that owns the session: the
                // local tmux, or the bridge of the machine of a remote card.
                let isEscape = event.keyCode == 53
                let chars = isEscape ? "" : (event.characters ?? "")
                Task.detached {
                    guard let adapter = await Self.remoteAdapter(for: session) else { return }
                    _ = try? await adapter.run(["send-keys", "-t", session, "-X", "cancel"])
                    if !chars.isEmpty {
                        _ = try? await adapter.run(["send-keys", "-t", session, chars])
                    }
                }
                return nil // consume — key is re-sent via tmux above
            }

            return event // let the key through to the terminal
        }

        // Intercept scroll wheel events over terminal views and translate to tmux
        // copy-mode navigation. TerminalView (from SwiftTerm) consumes scrollWheel
        // events before parent views can handle them, so we intercept at the app level.
        // We check terminal bounds directly instead of using hitTest, which can be
        // intercepted by SwiftUI overlay views (e.g. inspector panel).
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard event.deltaY != 0 else { return event }

            // An overlay drawn over the board scrolls its own contents. The
            // bounds check below cannot see it, so without this a scroll inside
            // the quick search palette is swallowed here and spent scrolling the
            // terminal behind it, one tmux command per wheel tick.
            guard self?.passesScrollThrough != true else { return event }

            guard let window = event.window else { return event }
            guard let session = self?.sessionUnderPoint(event.locationInWindow, in: window) else { return event }
            // rush reads the wheel itself, through mouse reporting.
            if RushSessionName.isRush(session) { return event }

            let inCopyMode = self?.copyModeSessions.contains(session) ?? false

            // After exiting copy-mode, ignore scroll events for 500ms
            // to prevent residual trackpad momentum from re-entering.
            if let exitTime = self?.copyModeExitTime[session],
               exitTime.duration(to: .now) < .milliseconds(500) {
                return nil // consume during cooldown
            }

            if AppServices.tmux.isRemote(session) {
                self?.scrollRemote(session: session, deltaY: event.deltaY, inCopyMode: inCopyMode)
                return nil
            }

            if event.deltaY > 0 {
                // Scroll UP — enter copy-mode if needed, then scroll.
                // All scroll commands use -X (copy-mode commands) so they're
                // no-ops if copy-mode has already been exited by another task.
                let lines = max(1, Int(abs(event.deltaY)))
                if !inCopyMode {
                    self?.copyModeSessions.insert(session)
                    self?.terminals[session]?.passthroughMode = true
                    Task.detached {
                        _ = try? await ShellCommand.run(tmux, arguments: ["copy-mode", "-t", session])
                        _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "-N", "\(lines)", "cursor-up"])
                    }
                } else {
                    Task.detached {
                        _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "-N", "\(lines)", "cursor-up"])
                    }
                }
            } else if inCopyMode {
                // Scroll DOWN in copy-mode.
                // -X cursor-down is a copy-mode command: no-op if copy-mode already exited.
                // No literal keys ever reach the shell, regardless of concurrent task timing.
                let lines = max(1, Int(abs(event.deltaY)))
                Task.detached {
                    _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "-N", "\(lines)", "cursor-down"])
                    try? await Task.sleep(for: .milliseconds(50))
                    let result = try? await ShellCommand.run(
                        tmux, arguments: ["display-message", "-p", "-t", session, "#{scroll_position}"]
                    )
                    if result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
                        // Only the first task to reach here proceeds (remove returns nil for duplicates).
                        let shouldExit = await MainActor.run {
                            guard TerminalCache.shared.copyModeSessions.remove(session) != nil else { return false }
                            TerminalCache.shared.copyModeExitTime[session] = .now
                            TerminalCache.shared.terminals[session]?.passthroughMode = false
                            return true
                        }
                        if shouldExit {
                            _ = try? await ShellCommand.run(tmux, arguments: ["send-keys", "-t", session, "-X", "cancel"])
                        }
                    }
                }
            }

            return nil // consume the event — don't let TerminalView handle it
        }

        // Observe font size changes from Settings / Cmd+Plus/Minus
        fontSizeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyFontSizeIfChanged()
            }
        }
    }

    // MARK: - Scroll on a machine

    private func scrollRemote(session: String, deltaY: CGFloat, inCopyMode: Bool) {
        let lines = max(1, Int(abs(deltaY)))
        if deltaY > 0 {
            if !inCopyMode, !copyModeSessions.contains(session) {
                copyModeSessions.insert(session)
                terminals[session]?.passthroughMode = true
                remoteScrollEnter.insert(session)
            }
            remoteScrollPending[session, default: 0] += lines
        } else if inCopyMode {
            remoteScrollPending[session, default: 0] -= lines
        } else {
            return
        }
        guard remoteScrollFlush[session] == nil else { return }
        remoteScrollFlush[session] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            let enter = self.remoteScrollEnter.remove(session) != nil
            let delta = self.remoteScrollPending.removeValue(forKey: session) ?? 0
            self.remoteScrollFlush[session] = nil
            await self.flushRemoteScroll(session: session, enter: enter, delta: delta)
        }
    }

    /// The tmux adapter of a session on a machine. A machine the app has
    /// as paused or unreachable, but boxd reports running, is reconnected
    /// first, so the first wheel tick or key after a restart is not lost.
    private static func remoteAdapter(for session: String) async -> TmuxAdapter? {
        if let adapter = try? AppServices.tmux.adapter(for: session) { return adapter }
        guard let machine = AppServices.machine(forSession: session),
              let supervisor = AppServices.boxdSupervisor,
              await supervisor.reconnectIfRunning(machineName: machine) else { return nil }
        return try? AppServices.tmux.adapter(for: session)
    }

    private func flushRemoteScroll(session: String, enter: Bool, delta: Int) async {
        guard let adapter = await Self.remoteAdapter(for: session) else { return }
        for command in Self.remoteScrollCommands(session: session, enter: enter, delta: delta) {
            _ = try? await adapter.run(command)
        }
        guard delta < 0 else { return }
        // Back at the bottom: leave copy-mode, as the local path does.
        let position = try? await adapter.run(["display-message", "-p", "-t", session, "#{scroll_position}"])
        guard position?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0",
              copyModeSessions.remove(session) != nil else { return }
        copyModeExitTime[session] = .now
        terminals[session]?.passthroughMode = false
        _ = try? await adapter.run(["send-keys", "-t", session, "-X", "cancel"])
    }

    /// The tmux commands of one flush: enter copy-mode when asked, then move
    /// by the net number of lines. `-X` commands are no-ops outside copy-mode.
    nonisolated static func remoteScrollCommands(session: String, enter: Bool, delta: Int) -> [[String]] {
        var commands: [[String]] = []
        if enter { commands.append(["copy-mode", "-t", session]) }
        if delta > 0 {
            commands.append(["send-keys", "-t", session, "-X", "-N", "\(delta)", "cursor-up"])
        } else if delta < 0 {
            commands.append(["send-keys", "-t", session, "-X", "-N", "\(-delta)", "cursor-down"])
        }
        return commands
    }

    private func applyFontSizeIfChanged() {
        let stored = UserDefaults.standard.double(forKey: Self.fontSizeKey)
        let newSize = stored > 0 ? CGFloat(stored) : Self.defaultFontSize
        guard newSize != currentFontSize else { return }
        currentFontSize = newSize
        let font = NSFont.monospacedSystemFont(ofSize: newSize, weight: .regular)
        for terminal in terminals.values {
            terminal.font = font
        }
    }

    /// Tracks which terminals have had their process started.
    private var startedSessions: Set<String> = []

    /// Resolved tmux binary path — checked once, reused for all terminals.
    static let tmuxPath: String = ShellCommand.findExecutable("tmux") ?? "tmux"

    /// Get or create a terminal view for the given tmux session name.
    /// The process is NOT started here — call `startProcessIfNeeded` after layout
    /// so the terminal has a non-zero frame (avoids tmux SIGWINCH clear on resize from 0x0).
    func terminal(for sessionName: String, frame: NSRect) -> BatchedTerminalView {
        if let existing = terminals[sessionName] {
            return existing
        }
        let terminal = BatchedTerminalView(frame: frame)
        terminal.kanbanSession = sessionName
        // The assistant may ask for mouse tracking to select text on its
        // own. The terminal keeps its native selection instead, and the
        // wheel reaches tmux through the scroll monitor. rush draws its own
        // scrollback, so its sessions get the mouse.
        terminal.allowMouseReporting = RushSessionName.isRush(sessionName)
        terminal.lossless = RushSessionName.isRush(sessionName)
        // Dark terminal colors matching a real terminal
        terminal.nativeBackgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1.0)
        terminal.caretColor = .systemGreen

        // Brighter ANSI palette (SwiftTerm Color uses UInt16 0-65535, multiply 0-255 by 257)
        let c = { (r: UInt16, g: UInt16, b: UInt16) in SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257) }
        terminal.installColors([
            // Standard colors (0-7)
            c(0x33, 0x33, 0x33),  // black (slightly visible)
            c(0xFF, 0x5F, 0x56),  // red
            c(0x5A, 0xF7, 0x8E),  // green
            c(0xFF, 0xD7, 0x5F),  // yellow
            c(0x57, 0xAC, 0xFF),  // blue
            c(0xFF, 0x6A, 0xC1),  // magenta
            c(0x5A, 0xF7, 0xD4),  // cyan
            c(0xE0, 0xE0, 0xE0),  // white
            // Bright colors (8-15)
            c(0x66, 0x66, 0x66),  // bright black
            c(0xFF, 0x6E, 0x67),  // bright red
            c(0x5A, 0xF7, 0x8E),  // bright green
            c(0xFF, 0xFC, 0x67),  // bright yellow
            c(0x6B, 0xC1, 0xFF),  // bright blue
            c(0xFF, 0x77, 0xD0),  // bright magenta
            c(0x5A, 0xF7, 0xD4),  // bright cyan
            c(0xFF, 0xFF, 0xFF),  // bright white
        ])

        terminal.font = NSFont.monospacedSystemFont(ofSize: currentFontSize, weight: .regular)

        // Do NOT set autoresizingMask — we manage frame explicitly in layout()
        // to avoid intermediate sizes triggering tmux redraws during animations.
        terminal.autoresizingMask = []
        terminal.isHidden = true
        terminal.installURLMonitor()
        terminals[sessionName] = terminal
        logGrowthIfNeeded(trigger: "create session=\(sessionName)")
        return terminal
    }

    /// Retries of terminals waiting for their card's owner, by session.
    private var ownerWaits: [String: Int] = [:]

    /// Start the tmux attach process if the terminal has a non-zero frame and hasn't started yet.
    /// A terminal of a card whose owner is not known yet waits for it (up to 30 seconds).
    func startProcessIfNeeded(for sessionName: String) {
        guard let terminal = terminals[sessionName] else { return }
        guard !startedSessions.contains(sessionName) else { return }
        guard terminal.frame.width > 0, terminal.frame.height > 0 else { return }
        if AppServices.terminalWaitsForOwner(sessionName), (ownerWaits[sessionName] ?? 0) < 60 {
            ownerWaits[sessionName, default: 0] += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startProcessIfNeeded(for: sessionName)
            }
            return
        }
        ownerWaits[sessionName] = nil
        startedSessions.insert(sessionName)

        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script: String
        if let peer = AppServices.peerCard(forSession: sessionName),
           let peerScript = AppServices.peerAttachScript(machineId: peer.machineId, cardId: peer.cardId, session: sessionName) {
            // Another master runs the card: its terminal streams from there.
            script = peerScript
        } else if let machine = AppServices.machine(forSession: sessionName),
                  let rushId = RushSessionName.rushId(fromName: sessionName),
                  let target = AppServices.sshTargets[machine] {
            script = Self.remoteRushScript(
                target: target, id: rushId, readyMarker: AppServices.remoteReadyMarkerPath(for: sessionName))
        } else if let machine = AppServices.machine(forSession: sessionName) {
            script = Self.remoteAttachScript(
                boxd: AppServices.boxdPath,
                machine: machine,
                session: sessionName,
                readyMarker: AppServices.remoteReadyMarkerPath(for: sessionName),
                sshTargets: AppServices.sshTargets
            )
        } else if AppServices.isRemoteSessionExpected(sessionName) {
            // The launch has not reached its machine yet; the marker names it.
            script = Self.remoteAttachScript(
                boxd: AppServices.boxdPath,
                machine: nil,
                session: sessionName,
                readyMarker: AppServices.remoteReadyMarkerPath(for: sessionName),
                sshTargets: AppServices.sshTargets
            )
        } else if let rushId = RushSessionName.rushId(fromName: sessionName) {
            script = Self.rushScript(rush: RushCliAdapter.findExecutable(), id: rushId)
        } else {
            script = Self.attachScript(tmux: Self.tmuxPath, session: sessionName)
        }
        terminal.startProcess(
            executable: userShell,
            args: ["-l", "-c", script],
            environment: nil,
            execName: nil,
            currentDirectory: nil
        )
    }

    /// Attaches to a tmux session on a boxd machine. The terminal opens when
    /// the launch starts, so it first waits for the ready marker the launch
    /// writes once the session exists (up to 20 minutes, a machine may have
    /// to be created and a repository checked out first). The marker names
    /// the machine, which wins over `machine` when it is not empty, so a
    /// terminal that started before the launch knew the machine still
    /// attaches to the right one. The machine may still be resuming after
    /// that, so the attach itself is retried for a while.
    ///
    /// The transport is `boxd machine connect`, the interactive shell of the
    /// CLI: it puts the local pty in raw mode, sizes the remote pty and
    /// follows resizes, and the session lives as long as the shell. (`exec
    /// --tty` does none of that and hangs up a full-screen program after a
    /// few seconds.) `connect` takes no command, so `expect` drives it: it
    /// waits for the prompt, types the tmux attach and hands the pty over
    /// with `interact`. The shell on the machine prints the exit status of
    /// tmux behind a sentinel and exits, so a detach ends the connection and
    /// a failed attach is retried. `connect` itself exits 0 whatever the
    /// command did, so the sentinel is the only word on the outcome. The
    /// tmux client runs with `-u` so it writes UTF-8 whatever the locale of
    /// the machine.
    ///
    /// A session that is not there yet is tried for 10 minutes: a resume
    /// creates the tmux session a few seconds after the bridge connects, and
    /// a push of a large transcript before it can take a while. A connection
    /// that fails or drops (no network, the machine still coming back) does
    /// not use up those tries: the session is still running on the machine,
    /// so the attach is retried for as long as the terminal is open.
    ///
    /// A machine reached over ssh (`sshTargets`, machine name to ssh target)
    /// needs none of that: `ssh -tt` sizes the remote pty and follows
    /// resizes, and it returns the exit status of the command, so the same
    /// statuses drive the loop (`noSessionStatus` for a missing session, 255
    /// for a connection that failed).
    static func remoteAttachScript(boxd: String, machine: String?, session: String, readyMarker: String? = nil, sshTargets: [String: String] = [:]) -> String {
        let quote = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let fallback = quote(machine ?? "")
        let program = expectProgram(boxd: boxd, session: session)
        let boxdAttach = "KANBAN_MACHINE=\"$m\" /usr/bin/expect -c \(quote(program)); r=$?"
        let attach: String
        if sshTargets.isEmpty {
            attach = "\(boxdAttach); [ $r -eq 0 ] && break"
        } else {
            let cases = sshTargets.sorted { $0.key < $1.key }
                .map { "\(quote($0.key))) t=\(quote($0.value));;" }
                .joined(separator: " ")
            let remote = "tmux has-session -t \(quote(session)) 2>/dev/null || exit \(noSessionStatus); "
                + "COLORTERM=truecolor exec tmux -u -T hyperlinks attach-session -t \(quote(session))"
            let ssh = "/usr/bin/ssh -tt -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \"$t\" -- \(quote(remote)); r=$?"
            attach = "t=; case \"$m\" in \(cases) esac; if [ -n \"$t\" ]; then \(ssh); else \(boxdAttach); fi; [ $r -eq 0 ] && break"
        }
        // A missing session counts against the tries, a failed connection
        // only waits a little longer.
        let again = "if [ $r -eq \(noSessionStatus) ]; then n=$((n+1)); sleep 2; else sleep 3; fi"
        guard let readyMarker else {
            return "m=\(fallback); n=0; while [ $n -lt \(attachTries) ]; do \(attach); \(again); done; echo 'Session ended.'"
        }
        // `boxd machine connect` wakes a paused machine, so the pause marker
        // is read before every try, not after: a connect that succeeds takes
        // the machine out of standby and the loop never comes back to look.
        // The machine name is read from the marker on every try as well: a
        // resume may move the session.
        let marker = quote(readyMarker)
        let paused = quote(readyMarker + Self.pausedMarkerSuffix)
        return "for i in $(seq 1 2400); do [ -e \(marker) ] && break; sleep 0.5; done; "
            + "n=0; while [ $n -lt \(attachTries) ]; do "
            + "if [ -e \(paused) ]; then echo 'Machine paused.'; while [ -e \(paused) ]; do sleep 1; done; n=0; fi; "
            + "m=\"$(cat \(marker) 2>/dev/null)\"; [ -n \"$m\" ] || m=\(fallback); "
            + "\(attach); "
            + "if [ -e \(paused) ]; then continue; fi; "
            + "\(again); done; echo 'Session ended.'"
    }

    /// Suffix of the file next to the ready marker that tells the attach loop
    /// the app has the machine paused.
    static let pausedMarkerSuffix = BoxdMachineSupervisor.pausedMarkerSuffix

    /// How many times a session that is not on the machine is tried, 2
    /// seconds and a connect apart, before the terminal gives up on it.
    static let attachTries = 150

    /// The status the shell on the machine reports when the tmux session is
    /// not there, as opposed to tmux ending or the connection dropping.
    static let noSessionStatus = 9

    /// The word the shell on the machine prints when tmux exits, followed by
    /// the exit status of tmux.
    static let attachExitSentinel = "KANBAN_TMUX_EXIT"

    /// The Tcl program `expect` runs for one attach. The machine comes in
    /// through `KANBAN_MACHINE`, because `expect -c` takes no arguments. A
    /// prompt that never shows (a machine still resuming) sends the command
    /// after the timeout anyway. The shell on the machine first asks tmux
    /// whether the session exists and reports `noSessionStatus` when it does
    /// not; otherwise it runs tmux, prints the sentinel with the exit status
    /// of tmux and exits. `interact` watches the output for the sentinel,
    /// swallows it, and ends with that status, so a session that is not
    /// there yet is retried a bounded number of times, a detach (status 0)
    /// ends the terminal, and a connection that never opens or drops before
    /// the sentinel (status 1) is retried for as long as the terminal is
    /// open. The WINCH trap copies the size of the local pty to the pty of
    /// `connect`, which forwards it to the machine.
    static func expectProgram(boxd: String, session: String) -> String {
        // The status is typed in quotes so the echo of the command, which
        // `interact` sees as well, never matches the sentinel pattern. Only
        // what the shell prints after running it does.
        let attach = " tmux has-session -t \(session) 2>/dev/null || { echo \(attachExitSentinel):\\\"\(noSessionStatus)\\\"; exit; }; "
            + "tmux -u -T hyperlinks attach-session -t \(session) 2>/dev/null; echo \(attachExitSentinel):$?; exit\\r"
        return [
            "set timeout 20",
            "spawn -noecho {\(boxd)} machine connect $env(KANBAN_MACHINE)",
            "trap {stty rows [stty rows] columns [stty columns] < $spawn_out(slave,name)} WINCH",
            "expect -re {\\$ $} {send \"\(attach)\"} timeout {send \"\(attach)\"} eof {exit 1}",
            "interact -o -re {\(attachExitSentinel):([0-9]+)} {exit $interact_out(1,string)} eof {exit 1}",
        ].joined(separator: "; ")
    }

    /// The shell command a terminal runs to reach its tmux session.
    ///
    /// `-T hyperlinks` tells tmux that this client understands OSC 8. Without
    /// it tmux drops the escape and passes on only the label, so a link an
    /// agent writes arrives as ordinary text with no destination behind it.
    /// The flag is probed rather than assumed, because tmux gained it in 3.2
    /// and an older one answers a flag it does not know by refusing to start.
    static func attachScript(tmux: String, session: String) -> String {
        let escaped = session.replacingOccurrences(of: "'", with: "'\\''")
        let attach = { (flags: String) in "exec '\(tmux)' \(flags)attach-session -t '\(escaped)'" }
        return "for i in $(seq 1 50); do '\(tmux)' has-session -t '\(escaped)' 2>/dev/null"
            + " && if '\(tmux)' -T hyperlinks -V >/dev/null 2>&1;"
            + " then \(attach("-T hyperlinks ")); else \(attach("")); fi;"
            + " sleep 0.1; done; echo 'Session ended.'"
    }

    /// The shell command a terminal runs to show a rush session on an ssh
    /// machine: `rush open <id>` there (`agtop open <id> --solo` on a machine
    /// that has only agtop), over `ssh -tt`, which sizes the remote pty and
    /// follows resizes. It waits for the ready marker of the launch first,
    /// like `remoteAttachScript`, and opens the view again when it is quit
    /// or the connection drops. ssh passes TERM on; COLORTERM it does not,
    /// so it is set on the machine.
    static func remoteRushScript(target: String, id: String, readyMarker: String?) -> String {
        let quote = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let remote = "PATH=\"$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/go/bin\" COLORTERM=truecolor; "
            + "export COLORTERM \(RushCliAdapter.copyOnSelectOff); \(RushCliAdapter.remoteOpenScript(id: id))"
        let ssh = "/usr/bin/ssh -tt -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "
            + "\(quote(target)) -- \(quote(remote))"
        let wait = readyMarker.map { "for i in $(seq 1 2400); do [ -e \(quote($0)) ] && break; sleep 0.5; done; " } ?? ""
        return wait + "while :; do \(ssh); sleep 1; done"
    }

    /// The shell command a terminal runs to show a rush session. The view
    /// shows that one session only, and quitting it leaves the host running,
    /// so it opens again.
    static func rushScript(rush: String?, id: String) -> String {
        guard let rush else { return "echo 'rush is not installed.'" }
        let open = RushCliAdapter.openArguments(executable: rush, id: id)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        // Copying is asked for with cmd+c here, never by letting go of a drag.
        return "export \(RushCliAdapter.copyOnSelectOff); while :; do \(open); sleep 0.3; done"
    }

    /// Remove and terminate a specific terminal (e.g., when user kills a session).
    /// Writes a line of the app into the terminals of the given sessions, in
    /// dim text, so a person who clicks a paused terminal sees an answer at
    /// once. The next tmux repaint takes it away.
    func showNotice(_ text: String, sessions: some Sequence<String>) {
        for session in sessions {
            terminals[session]?.feed(text: "\r\n\u{1b}[2m" + text + "\u{1b}[0m\r\n")
        }
    }

    func remove(_ sessionName: String) {
        startedSessions.remove(sessionName)
        if let terminal = terminals.removeValue(forKey: sessionName) {
            terminal.removeURLMonitor()
            terminal.removeFromSuperview()
            terminal.terminate()
        }
    }

    /// Check if a terminal exists for this session.
    func has(_ sessionName: String) -> Bool {
        terminals[sessionName] != nil
    }

    func diagnosticSummary() -> String {
        "terminalCache terminals=\(terminals.count) started=\(startedSessions.count) copyMode=\(copyModeSessions.count) copyModeCooldowns=\(copyModeExitTime.count)"
    }

    private func logGrowthIfNeeded(trigger: String) {
        let terminalCount = terminals.count
        guard terminalCount >= 8, terminalCount != lastLoggedTerminalCount else { return }
        lastLoggedTerminalCount = terminalCount
        KanbanCodeLog.warn(
            "memory-context",
            "terminalCache grew trigger=\(trigger) terminals=\(terminalCount) started=\(startedSessions.count) copyMode=\(copyModeSessions.count)"
        )
    }

    /// Focus the terminal for a session directly (bypasses NSViewRepresentable update).
    func focusTerminal(for sessionName: String) {
        guard let terminal = terminals[sessionName] else { return }
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak terminal] in
            guard let terminal, terminal.window?.firstResponder !== terminal else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }
}

// MARK: - Multi-terminal container (manages all terminals for a card)

/// A single NSViewRepresentable that manages multiple tmux terminal subviews.
/// Uses TerminalCache to persist terminals across drawer close/open cycles.
/// Terminals are created once globally and reparented as needed — never destroyed
/// just because the drawer was toggled.
struct TerminalContainerView: NSViewRepresentable, Equatable {
    /// All tmux session names to show tabs for.
    let sessions: [String]
    /// Which session is currently visible.
    let activeSession: String
    /// When true, the terminal grabs keyboard focus (user clicked a tab).
    /// When false, the terminal is shown but focus stays where it was (keyboard nav, drawer open).
    var grabFocus: Bool = false
    /// GitHub base URL for the card's project, used for resolving #123 references.
    var githubBaseURL: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        // Ultra-strict: only sessions matter. grabFocus changes should NOT
        // trigger updateNSView — we handle focus separately.
        lhs.sessions == rhs.sessions
            && lhs.activeSession == rhs.activeSession
    }

    func makeNSView(context: Context) -> TerminalContainerNSView {
        KanbanCodeLog.info("terminal-view", "makeNSView: sessions=\(sessions) active=\(activeSession)")
        let container = TerminalContainerNSView()
        container.githubBaseURL = githubBaseURL
        for session in sessions {
            container.ensureTerminal(for: session)
        }
        container.showTerminal(for: activeSession, grabFocus: grabFocus)
        return container
    }

    func updateNSView(_ nsView: TerminalContainerNSView, context: Context) {
        KanbanCodeLog.info("terminal-view", "updateNSView called: sessions=\(sessions) active=\(activeSession) grabFocus=\(grabFocus)")
        nsView.githubBaseURL = githubBaseURL
        // When sessions are empty (terminal not yet created), just clean up and return.
        guard !sessions.isEmpty, !activeSession.isEmpty else {
            nsView.removeTerminalsNotIn([])
            return
        }
        // Add any new sessions (idempotent — reuses cached terminals)
        for session in sessions {
            nsView.ensureTerminal(for: session)
        }
        // Remove terminals that are no longer in the list
        nsView.removeTerminalsNotIn(Set(sessions))
        // Switch visible terminal
        nsView.showTerminal(for: activeSession, grabFocus: grabFocus)
    }

    static func dismantleNSView(_ nsView: TerminalContainerNSView, coordinator: ()) {
        KanbanCodeLog.info("terminal-view", "dismantleNSView — detaching all terminals")
        // Detach terminals from this container but do NOT terminate them.
        // They live on in TerminalCache and will be reparented when the drawer reopens.
        nsView.detachAll()
    }
}

/// AppKit container that owns multiple LocalProcessTerminalView instances.
/// Uses TerminalCache for process lifecycle — terminal processes survive view teardown.
final class TerminalContainerNSView: NSView {
    private static let terminalPadding: CGFloat = 6

    /// Ordered list of session names managed by this container.
    private var managedSessions: [String] = []
    fileprivate private(set) var activeSession: String?
    /// GitHub base URL for resolving bare #123 references in terminals.
    var githubBaseURL: String? {
        didSet {
            for name in managedSessions {
                TerminalCache.shared.terminal(for: name, frame: bounds).githubBaseURL = githubBaseURL
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0).cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1.0).cgColor
    }

    /// Ensure a terminal for `sessionName` is attached to this container.
    func ensureTerminal(for sessionName: String) {
        guard !managedSessions.contains(sessionName) else { return }
        let terminal = TerminalCache.shared.terminal(for: sessionName, frame: bounds)
        terminal.githubBaseURL = githubBaseURL
        if terminal.superview !== self {
            terminal.removeFromSuperview()
            addSubview(terminal)
        }
        // Show immediately with old content — no hiding/alpha tricks.
        // Combined with BatchedTerminalView, any tmux redraw lands as
        // one batched update instead of visible scrolling.
        terminal.isHidden = true
        managedSessions.append(sessionName)
    }

    /// Show only the terminal for `sessionName`, hide all others.
    func showTerminal(for sessionName: String, grabFocus: Bool = false) {
        activeSession = sessionName
        for name in managedSessions {
            let terminal = TerminalCache.shared.terminal(for: name, frame: bounds)
            let isActive = (name == sessionName)
            if terminal.isHidden != !isActive {
                terminal.isHidden = !isActive
            }
            if isActive {
                disableScrollbar(on: terminal)
                if grabFocus {
                    // Try immediately, then retry after a delay for heavy cards
                    // where SwiftUI re-renders steal focus during history loading.
                    DispatchQueue.main.async { [weak self] in
                        self?.window?.makeFirstResponder(terminal)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, self.activeSession == sessionName,
                              self.window?.firstResponder !== terminal else { return }
                        self.window?.makeFirstResponder(terminal)
                    }
                }
            }
        }
    }

    /// Hide SwiftTerm's built-in NSScroller.
    private func disableScrollbar(on terminal: NSView) {
        for subview in terminal.subviews {
            if let scroller = subview as? NSScroller {
                scroller.isHidden = true
            }
        }
    }

    /// Remove terminals whose session names are not in `keep`.
    func removeTerminalsNotIn(_ keep: Set<String>) {
        let toRemove = managedSessions.filter { !keep.contains($0) }
        for name in toRemove {
            TerminalCache.shared.remove(name)
            managedSessions.removeAll { $0 == name }
        }
    }

    /// Detach all terminals from this container without terminating them.
    func detachAll() {
        for sub in subviews {
            sub.removeFromSuperview()
        }
        managedSessions.removeAll()
        activeSession = nil
    }

    override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: Self.terminalPadding, dy: Self.terminalPadding)
        guard inset.width > 0, inset.height > 0 else { return }

        for sub in subviews {
            // Only resize if the change is >= 1px to avoid tmux SIGWINCH
            // from sub-pixel layout jitter during background state updates.
            let delta = abs(sub.frame.origin.x - inset.origin.x)
                + abs(sub.frame.origin.y - inset.origin.y)
                + abs(sub.frame.width - inset.width)
                + abs(sub.frame.height - inset.height)
            if delta >= 1.0 {
                KanbanCodeLog.info("terminal-layout", "RESIZE delta=\(String(format: "%.1f", delta))px old=\(sub.frame) new=\(inset) sessions=\(managedSessions)")
                sub.frame = inset
            }
        }

        for name in managedSessions {
            TerminalCache.shared.startProcessIfNeeded(for: name)
        }
    }

}
