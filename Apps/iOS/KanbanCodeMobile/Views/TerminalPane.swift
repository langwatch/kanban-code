import SwiftUI
import SwiftTerm
import KanbanCodeRemoteKit

/// SwiftTerm's view for a remote terminal. With mouse reporting on, SwiftTerm
/// turns a pan into a button-1 drag, which agtop reads as a click where the
/// finger landed; `TerminalController` scrolls on a pan instead. It also
/// reads the screen out to accessibility.
final class RemoteTerminalView: TerminalView {
    override func mouseModeChanged(source: Terminal) {}

    override var isAccessibilityElement: Bool {
        get { true }
        set {}
    }

    override var accessibilityLabel: String? {
        get { "Terminal" }
        set {}
    }

    override var accessibilityValue: String? {
        get {
            let term = getTerminal()
            return (0..<term.rows).compactMap { term.getLine(row: $0)?.translateToString(trimRight: true) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {}
    }
}

/// One terminal viewer of a card: a SwiftTerm view fed from the terminal socket.
@Observable
final class TerminalController: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case closed(String?)
    }

    private(set) var state: State = .idle
    private(set) var connectedSession: String?
    var fontSize: CGFloat = 12 {
        didSet { applyFont() }
    }

    @ObservationIgnored let view: TerminalView
    @ObservationIgnored private var connection: RemoteTerminalConnection?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    /// The Mac scrolls tmux history on a `scroll` frame (`RemoteAPI.Feature.terminalScroll`).
    @ObservationIgnored private var serverScroll = false
    @ObservationIgnored private var scrollPan: UIPanGestureRecognizer!
    @ObservationIgnored private var scrollMode: ScrollMode?
    /// Finger travel not yet turned into whole lines.
    @ObservationIgnored private var scrollRemainder: CGFloat = 0
    /// Lines not yet turned into whole wheel events.
    @ObservationIgnored private var wheelRemainder = 0
    @ObservationIgnored private var pendingServerLines = 0
    @ObservationIgnored private var serverFlush: Task<Void, Never>?

    /// How a vertical pan scrolls the terminal.
    enum ScrollMode {
        /// The program reads the mouse (agtop, or tmux with mouse on): wheel
        /// events at the finger.
        case wheel
        /// A tmux client on the alternate screen: the Mac scrolls its history.
        case server
    }

    /// Lines agtop scrolls per wheel event, so the content follows the finger.
    static let linesPerWheel = 3

    override init() {
        view = RemoteTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        super.init()
        view.terminalDelegate = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        // Local scrollback scrolls natively, but only when this pan passes.
        view.panGestureRecognizer.require(toFail: pan)
        scrollPan = pan
        // Same colors as the card terminal on the Mac.
        view.nativeBackgroundColor = UIColor(white: 0.07, alpha: 1)
        view.nativeForegroundColor = UIColor(white: 0.93, alpha: 1)
        view.caretColor = .systemGreen
        let c = { (r: UInt16, g: UInt16, b: UInt16) in SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257) }
        view.installColors([
            c(0x33, 0x33, 0x33), c(0xFF, 0x5F, 0x56), c(0x5A, 0xF7, 0x8E), c(0xFF, 0xD7, 0x5F),
            c(0x57, 0xAC, 0xFF), c(0xFF, 0x6A, 0xC1), c(0x5A, 0xF7, 0xD4), c(0xE0, 0xE0, 0xE0),
            c(0x66, 0x66, 0x66), c(0xFF, 0x6E, 0x67), c(0x5A, 0xF7, 0x8E), c(0xFF, 0xFC, 0x67),
            c(0x6B, 0xC1, 0xFF), c(0xFF, 0x77, 0xD0), c(0x5A, 0xF7, 0xD4), c(0xFF, 0xFF, 0xFF),
        ])
        view.optionAsMetaKey = true
        // A steady caret: a blinking one keeps the app from ever idling.
        view.getTerminal().setCursorStyle(.steadyBlock)
        applyFont()
    }

    private func applyFont() {
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    func connect(client: RemoteClient, cardId: String, session: String?, serverScroll: Bool) {
        disconnect()
        self.serverScroll = serverScroll
        state = .connecting
        connectedSession = session
        let term = view.getTerminal()
        view.feed(text: "\u{1b}[2J\u{1b}[H")
        let conn = client.terminal(cardId: cardId, session: session, cols: term.cols, rows: term.rows)
        connection = conn
        readTask = Task { [weak self] in
            var first = true
            do {
                for try await chunk in conn.output {
                    guard let self else { return }
                    if first {
                        first = false
                        self.state = .connected
                        // The size may have changed while the socket opened.
                        let t = self.view.getTerminal()
                        conn.resize(cols: t.cols, rows: t.rows)
                    }
                    self.view.feed(byteArray: ArraySlice(chunk))
                }
                self?.state = .closed(nil)
            } catch {
                self?.state = .closed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        readTask?.cancel()
        readTask = nil
        connection?.close()
        connection = nil
        if state != .idle { state = .closed(nil) }
    }

    func toggleKeyboard() {
        if view.isFirstResponder {
            _ = view.resignFirstResponder()
        } else {
            _ = view.becomeFirstResponder()
        }
    }

    // MARK: Scrolling

    /// What a vertical pan does right now; nil leaves it to the scroll view,
    /// which moves through local scrollback.
    var currentScrollMode: ScrollMode? {
        let term = view.getTerminal()
        if term.mouseMode != .off { return .wheel }
        if term.isCurrentBufferAlternate, serverScroll, connection != nil { return .server }
        return nil
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === scrollPan, let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        scrollMode = currentScrollMode
        return scrollMode != nil
    }

    private var cellSize: CGSize {
        let term = view.getTerminal()
        return CGSize(width: view.bounds.width / CGFloat(max(term.cols, 1)),
                      height: view.bounds.height / CGFloat(max(term.rows, 1)))
    }

    @objc private func handleScrollPan(_ pan: UIPanGestureRecognizer) {
        let lineHeight = max(cellSize.height, 1)
        switch pan.state {
        case .began:
            scrollRemainder = 0
            wheelRemainder = 0
        case .changed:
            scrollRemainder += pan.translation(in: view).y
            pan.setTranslation(.zero, in: view)
            let lines = Int(scrollRemainder / lineHeight)
            scrollRemainder -= CGFloat(lines) * lineHeight
            scroll(lines: lines, at: pan.location(in: view))
        case .ended:
            // A flick carries on a little past the finger.
            let flick = pan.velocity(in: view).y / lineHeight * 0.15
            scroll(lines: max(-40, min(40, Int(flick))), at: pan.location(in: view))
            scrollMode = nil
        default:
            scrollMode = nil
        }
    }

    /// Scrolls by `lines`: positive shows older output, as a finger moving down does.
    func scroll(lines: Int, at point: CGPoint) {
        guard lines != 0, let mode = scrollMode ?? currentScrollMode else { return }
        switch mode {
        case .wheel:
            wheelRemainder += lines
            let events = wheelRemainder / Self.linesPerWheel
            wheelRemainder -= events * Self.linesPerWheel
            guard events != 0 else { return }
            let term = view.getTerminal()
            let cell = cellSize
            let col = min(max(Int(point.x / max(cell.width, 1)), 0), term.cols - 1)
            let row = min(max(Int((point.y - view.contentOffset.y) / max(cell.height, 1)), 0), term.rows - 1)
            let flags = term.encodeButton(button: events > 0 ? 4 : 5, release: false, shift: false, meta: false, control: false)
            for _ in 0..<abs(events) {
                term.sendEvent(buttonFlags: flags, x: col, y: row)
            }
        case .server:
            pendingServerLines += lines
            guard serverFlush == nil else { return }
            // One frame per 60 ms: each one runs tmux commands on the Mac.
            serverFlush = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard let self else { return }
                let lines = self.pendingServerLines
                self.pendingServerLines = 0
                self.serverFlush = nil
                self.connection?.scroll(lines: lines)
            }
        }
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        connection?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        connection?.send(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }

    func bell(source: TerminalView) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Hosts the controller's terminal view; only one host shows it at a time.
struct TerminalHost: UIViewRepresentable {
    let controller: TerminalController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = controller.view.nativeBackgroundColor
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if controller.view.superview !== container { attach(to: container) }
    }

    private func attach(to container: UIView) {
        let view = controller.view
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor, constant: 4),
            view.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -4),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            view.bottomAnchor.constraint(equalTo: container.keyboardLayoutGuide.topAnchor),
        ])
    }
}

struct TerminalPane: View {
    let card: RemoteCard
    let client: RemoteClient?
    /// The Mac takes `scroll` frames for tmux terminals.
    var serverScroll = false
    let controller: TerminalController
    @Binding var session: String?
    var isFullScreen = false
    var onFullScreen: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            bar
            ZStack {
                TerminalHost(controller: controller)
                    .ignoresSafeArea(.keyboard)
                overlay
            }
        }
        .background(Color(white: 0.07))
        .task(id: session) { connectIfNeeded() }
    }

    private var selectedSession: String? {
        session ?? card.terminals.first(where: \.isPrimary)?.sessionName ?? card.terminals.first?.sessionName
    }

    private func connectIfNeeded(force: Bool = false) {
        guard let client else { return }
        let target = selectedSession
        if !force, controller.connectedSession == target,
           controller.state == .connected || controller.state == .connecting { return }
        controller.connect(client: client, cardId: card.id, session: target, serverScroll: serverScroll)
    }

    private var bar: some View {
        HStack(spacing: 14) {
            if card.terminals.count > 1 {
                Menu {
                    Picker("Terminal", selection: Binding(
                        get: { selectedSession ?? "" },
                        set: { session = $0 }
                    )) {
                        ForEach(card.terminals) { t in
                            Text(t.label).tag(t.sessionName)
                        }
                    }
                } label: {
                    Label(card.terminals.first { $0.sessionName == selectedSession }?.label ?? "Terminal",
                          systemImage: "chevron.up.chevron.down")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .accessibilityIdentifier("terminalPicker")
            } else {
                Text(stateText)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { controller.fontSize = max(8, controller.fontSize - 1) } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .accessibilityLabel("Smaller text")
            Button { controller.fontSize = min(24, controller.fontSize + 1) } label: {
                Image(systemName: "textformat.size.larger")
            }
            .accessibilityLabel("Larger text")
            Button { controller.toggleKeyboard() } label: {
                Image(systemName: "keyboard")
            }
            .accessibilityLabel("Keyboard")
            .accessibilityIdentifier("terminalKeyboard")
            if isFullScreen {
                Button("Done", action: onClose)
                    .fontWeight(.semibold)
            } else {
                Button(action: onFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Full screen")
            }
        }
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var stateText: String {
        switch controller.state {
        case .idle, .connecting: "Connecting"
        case .connected: card.terminals.first { $0.sessionName == selectedSession }?.label ?? "Terminal"
        case .closed: "Disconnected"
        }
    }

    @ViewBuilder private var overlay: some View {
        switch controller.state {
        case .idle, .connecting:
            ProgressView().tint(.white)
        case .connected:
            EmptyView()
        case .closed(let message):
            VStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.largeTitle)
                Text(message ?? "The terminal closed.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("Reconnect", systemImage: "arrow.clockwise") { connectIfNeeded(force: true) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("terminalReconnect")
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .environment(\.colorScheme, .dark)
        }
    }
}

struct FullScreenTerminal: View {
    let card: RemoteCard
    let client: RemoteClient?
    var serverScroll = false
    let controller: TerminalController
    @Binding var session: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TerminalPane(card: card, client: client, serverScroll: serverScroll, controller: controller, session: $session,
                     isFullScreen: true, onClose: { dismiss() })
            .environment(\.colorScheme, .dark)
            .statusBarHidden()
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}
