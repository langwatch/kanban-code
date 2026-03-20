import SwiftUI
import WebKit

// MARK: - Eruda DevTools script helpers

/// Pure-logic helper for generating Eruda injection and toggle scripts.
/// Testable without WKWebView — see BrowserDevToolsTests.
enum ErudaScript {
    /// JS that initializes Eruda (hidden by default). Injected after the library source.
    static let initializationScript: String = """
        if (typeof eruda !== 'undefined' && !eruda._isInit) {
            eruda.init({ useShadowDom: true, autoScale: true });
            eruda.hide();
        }
        """

    /// JS to show the Eruda panel.
    static let showScript = "if (typeof eruda !== 'undefined') { eruda.show(); }"

    /// JS to hide the Eruda panel.
    static let hideScript = "if (typeof eruda !== 'undefined') { eruda.hide(); }"

    /// Returns show or hide script based on current visibility.
    static func toggleScript(currentlyVisible: Bool) -> String {
        currentlyVisible ? hideScript : showScript
    }

    /// Loads eruda.min.js from bundle and appends the initialization call.
    /// Throws if the resource is missing.
    static func fullInjectionScript() throws -> String {
        guard let url = Bundle.appResources.url(forResource: "eruda.min", withExtension: "js") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let library = try String(contentsOf: url, encoding: .utf8)
        return library + "\n" + initializationScript
    }
}

// MARK: - Browser tab model

/// Holds a WKWebView and publishes navigation state for SwiftUI.
/// Each tab owns one web view that is reused across representable updates.
@MainActor
final class BrowserTab: ObservableObject {
    let id: String
    let webView: WKWebView

    @Published var currentURL: URL?
    @Published var pageTitle: String = ""
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0
    @Published var isDevToolsVisible: Bool = false

    private var observers: [NSKeyValueObservation] = []
    private var navigationCoordinator: BrowserNavigationCoordinator?

    init(id: String? = nil, url: URL = URL(string: "http://localhost:5560/")!) {
        self.id = id ?? "browser-\(UUID().uuidString)"

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Inject Eruda devtools script into every page load
        if let erudaJS = try? ErudaScript.fullInjectionScript() {
            let userScript = WKUserScript(
                source: erudaJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
            config.userContentController.addUserScript(userScript)
        }

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.isInspectable = true
        self.webView = wv

        let coordinator = BrowserNavigationCoordinator()
        self.navigationCoordinator = coordinator
        wv.navigationDelegate = coordinator

        setupObservers()
        navigate(to: url)
    }

    deinit {
        observers.removeAll()
        // deinit of @MainActor class always runs on main thread but Swift 6
        // considers it nonisolated — use assumeIsolated to silence the warning.
        MainActor.assumeIsolated {
            webView.navigationDelegate = nil
        }
    }

    // MARK: - KVO

    private func setupObservers() {
        observers.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor [weak self] in
                self?.currentURL = wv.url
            }
        })
        observers.append(webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor [weak self] in
                let trimmed = (wv.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self?.pageTitle = trimmed
            }
        })
        observers.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor [weak self] in
                self?.canGoBack = wv.canGoBack
            }
        })
        observers.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor [weak self] in
                self?.canGoForward = wv.canGoForward
            }
        })
        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor [weak self] in
                self?.isLoading = wv.isLoading
            }
        })
        observers.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor [weak self] in
                self?.estimatedProgress = wv.estimatedProgress
            }
        })
    }

    // MARK: - Navigation

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    /// Toggle Eruda DevTools visibility in the web page.
    func toggleDevTools() {
        let script = ErudaScript.toggleScript(currentlyVisible: isDevToolsVisible)
        webView.evaluateJavaScript(script) { _, _ in }
        isDevToolsVisible.toggle()
    }

    func navigate(to url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Detect URL vs search query and navigate accordingly.
    func navigateSmart(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let url = smartURL(from: trimmed) {
            navigate(to: url)
        }
    }

    private func smartURL(from input: String) -> URL? {
        // Already a full URL
        if input.hasPrefix("http://") || input.hasPrefix("https://") {
            return URL(string: input)
        }
        // localhost with optional port
        if input.hasPrefix("localhost") {
            return URL(string: "http://\(input)")
        }
        // Contains a dot → likely a domain
        if input.contains(".") {
            return URL(string: "https://\(input)")
        }
        // Treat as search query
        let encoded = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }
}

// MARK: - Navigation delegate (nonisolated — avoids @MainActor + GCD crash)

/// Separate class so WKNavigationDelegate callbacks don't inherit @MainActor
/// isolation from BrowserTab. See CLAUDE.md for the DispatchSource crash rule —
/// the same principle applies to any WebKit delegate callback.
private final class BrowserNavigationCoordinator: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // KVO observers on BrowserTab handle state updates.
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }
}

// MARK: - NSViewRepresentable wrapper

/// Embeds the BrowserTab's WKWebView into SwiftUI.
struct BrowserWebViewRepresentable: NSViewRepresentable {
    let tab: BrowserTab

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        let wv = tab.webView
        wv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: container.topAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let wv = tab.webView
        if wv.superview !== nsView {
            wv.removeFromSuperview()
            wv.translatesAutoresizingMaskIntoConstraints = false
            nsView.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: nsView.topAnchor),
                wv.bottomAnchor.constraint(equalTo: nsView.bottomAnchor),
                wv.leadingAnchor.constraint(equalTo: nsView.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: nsView.trailingAnchor),
            ])
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.window?.makeFirstResponder(nil)
    }
}

// MARK: - Browser content view

/// Full browser UI: navigation bar, progress indicator, and web content.
struct BrowserContentView: View {
    @ObservedObject var tab: BrowserTab
    var onNavigated: ((String, String?, String?) -> Void)? // (tabId, url?, title?)
    @State private var urlText: String = ""
    @State private var navigationDebounce: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Navigation bar
            HStack(spacing: 6) {
                Button(action: { tab.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!tab.canGoBack)
                .opacity(tab.canGoBack ? 1.0 : 0.4)

                Button(action: { tab.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!tab.canGoForward)
                .opacity(tab.canGoForward ? 1.0 : 0.4)

                if tab.isLoading {
                    Button(action: { tab.stopLoading() }) {
                        Image(systemName: "xmark")
                    }
                } else {
                    Button(action: { tab.reload() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }

                TextField("URL or search", text: $urlText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        tab.navigateSmart(urlText)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))

                Button(action: { tab.toggleDevTools() }) {
                    Image(systemName: "hammer.fill")
                        .foregroundStyle(tab.isDevToolsVisible ? Color.accentColor : .secondary)
                }
                .help("Toggle DevTools")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            .buttonStyle(.borderless)
            .font(.app(.caption))
            .padding(.horizontal, 8)
            .frame(height: 28)

            // Progress bar
            if tab.isLoading {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * tab.estimatedProgress, height: 2)
                }
                .frame(height: 2)
            }

            // Web content
            BrowserWebViewRepresentable(tab: tab)
        }
        .onChange(of: tab.currentURL) { _, newURL in
            urlText = newURL?.absoluteString ?? ""
            debouncePersist()
        }
        .onChange(of: tab.pageTitle) {
            debouncePersist()
        }
        .onAppear {
            urlText = tab.currentURL?.absoluteString ?? ""
        }
    }

    private func debouncePersist() {
        navigationDebounce?.cancel()
        navigationDebounce = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            onNavigated?(tab.id, tab.currentURL?.absoluteString, tab.pageTitle)
        }
    }
}
