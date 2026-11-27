#if canImport(Speech) && canImport(AVFoundation) && canImport(Observation)
import AVFoundation
import Foundation
import Observation
import Speech
#if canImport(UIKit)
import UIKit
#endif

/// The composer's dictation: asks for the microphone, runs one engine per dictation and keeps
/// the settled and guessed words for the box. The composer writes them into its draft through a
/// `DictationInsertion`.
@MainActor
@Observable
public final class ComposerDictation {
    public enum Phase: Sendable { case idle, starting, listening, finishing }

    public enum Problem: Identifiable, Sendable {
        case denied
        case failed(String)
        case stopped(String)

        public var id: String {
            switch self {
            case .denied: "denied"
            case let .failed(reason): "failed-\(reason)"
            case let .stopped(reason): "stopped-\(reason)"
            }
        }

        public var title: String {
            switch self {
            case .denied: "Kanban Code cannot use the microphone"
            case .failed: "Dictation did not start"
            case .stopped: "Dictation stopped"
            }
        }

        public var message: String {
            switch self {
            case .denied: "Allow the microphone for Kanban Code in Settings to dictate messages."
            case let .failed(reason), let .stopped(reason): reason
            }
        }
    }

    /// Every language the transcriber supports, the person's languages first; empty hides the
    /// microphone. Found once per launch.
    public struct Languages: Equatable, Sendable {
        public var all: [String] = []
        /// How many at the start of `all` match the person's languages.
        public var suggested = 0
        public var installed: Set<String> = []
        /// The closest supported locale to the system language, then the preferred languages.
        public var preferred: [String] = []
        /// The languages of the person's keyboards, used when no system language is supported.
        public var keyboard: [String] = []

        public init() {}

        init(all: [String], suggested: Int, installed: Set<String>, preferred: [String], keyboard: [String]) {
            self.all = all
            self.suggested = suggested
            self.installed = installed
            self.preferred = preferred
            self.keyboard = keyboard
        }
    }

    public private(set) var phase = Phase.idle
    public private(set) var settled = ""
    public private(set) var guessing = ""
    /// The voice's loudness, read by the level line once a frame; never observed, so a level
    /// re-renders nothing.
    @ObservationIgnored public let meter = DictationMeter()
    /// The voice model is loaded; until then the microphone's sound waits in a buffer.
    public private(set) var modelReady = false
    /// The model download's progress, 0 to 1, while a language's first dictation waits for it.
    public private(set) var download: Double?
    public private(set) var languages = Languages()
    public private(set) var remembered = UserDefaults.standard.string(forKey: ComposerDictation.languageKey)
    public var problem: Problem?

    private var engine: (any DictationEngine)?
    private var updates: AsyncStream<DictationUpdate>.Continuation?
    private var reader: Task<Void, Never>?
    private var stopping: Task<Bool, Never>?
    private static var resolved: Languages?
    public nonisolated static let languageKey = "dictationLocale"

    public init() {}

    public var isActive: Bool { phase != .idle }
    public var isOffered: Bool { !languages.all.isEmpty }
    public var transcript: String { Dictation.join(settled, guessing) }

    /// The remembered language while supported, else the closest to the person's languages.
    public var language: String? {
        Dictation.localeChoice(
            preferred: languages.preferred, keyboard: languages.keyboard, supported: languages.all, remembered: remembered)
    }

    /// The voice bar's line while a stop waits for the model to load or download.
    public var waiting: String? {
        guard phase == .finishing, !modelReady, let language else { return nil }
        return Dictation.waitingLine(language: Self.name(language), download: download)
    }

    public static func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Remembers the language on this device for every later dictation.
    public func choose(_ language: String) {
        remembered = language
        UserDefaults.standard.set(language, forKey: Self.languageKey)
    }

    public func resolve() async {
        if let resolved = Self.resolved {
            languages = resolved
            return
        }
        let found = await Self.findLanguages()
        Self.resolved = found
        languages = found
    }

    public func start() async {
        guard phase == .idle, let language else { return }
        phase = .starting
        settled = ""
        guessing = ""
        meter.level = 0
        modelReady = false
        download = nil
        guard await Self.microphoneAllowed() else {
            phase = .idle
            problem = .denied
            return
        }
        let engine = Self.makeEngine()
        self.engine = engine
        let (stream, continuation) = AsyncStream<DictationUpdate>.makeStream()
        updates = continuation
        reader = Task { [weak self] in
            for await update in stream { self?.apply(update, language: language) }
        }
        do {
            try await engine.start(locale: language) { continuation.yield($0) }
            guard self.engine === engine else { return }
            if phase == .starting { phase = .listening }
        } catch {
            guard self.engine === engine else { return }
            await engine.cancel()
            await finish()
            problem = .failed(error.localizedDescription)
        }
    }

    /// Stops listening and waits for the model and the last words; false when cancelled meanwhile.
    @discardableResult
    public func stop() async -> Bool {
        switch phase {
        case .idle: return true
        case .starting: return false
        case .finishing: return await stopping?.value ?? false
        case .listening:
            guard let engine else { return false }
            phase = .finishing
            let task = Task { [weak self] in
                await engine.stop()
                guard let self, self.engine === engine else { return false }
                await self.finish()
                return true
            }
            stopping = task
            return await task.value
        }
    }

    /// Stops at once and drops words not yet reported.
    public func cancel() {
        guard let engine else { return }
        updates?.finish()
        updates = nil
        reader?.cancel()
        reader = nil
        self.engine = nil
        stopping = nil
        phase = .idle
        meter.level = 0
        download = nil
        Task { await engine.cancel() }
    }

    private func apply(_ update: DictationUpdate, language: String) {
        switch update {
        case let .downloading(fraction): download = fraction < 1 ? fraction : nil
        case .ready:
            modelReady = true
            download = nil
            if !languages.installed.contains(language) {
                languages.installed.insert(language)
                Self.resolved = languages
            }
        case let .failed(reason):
            cancel()
            problem = .stopped(reason)
        case let .level(value):
            meter.level = value
        case let .text(settled, guessing):
            self.settled = settled
            self.guessing = guessing
        }
    }

    private func finish() async {
        updates?.finish()
        await reader?.value
        updates = nil
        reader = nil
        engine = nil
        stopping = nil
        phase = .idle
        meter.level = 0
        download = nil
    }

    // MARK: Engine choice

    private static var launchSettings: [String: String] { ProcessInfo.processInfo.environment }
    /// UI tests run the scripted stand-in; real speech cannot run there.
    private static var scripted: Bool {
        launchSettings["KANBANCODE_DICTATION_SCRIPT"] != nil || launchSettings["KANBANCODE_DICTATION_DENIED"] == "1"
    }

    private static func makeEngine() -> any DictationEngine {
        let settings = launchSettings
        if let script = settings["KANBANCODE_DICTATION_SCRIPT"] {
            return ScriptedDictation(
                script: script, loading: Double(settings["KANBANCODE_DICTATION_LOAD"] ?? "") ?? 0,
                failure: settings["KANBANCODE_DICTATION_FAIL"])
        }
        return TranscriberDictation()
    }

    private static func findLanguages() async -> Languages {
        var preferred = Locale.preferredLanguages
        #if canImport(UIKit)
        let keyboard = UITextInputMode.activeInputModes.compactMap(\.primaryLanguage)
            .filter { $0 != "emoji" && $0 != "dictation" }
        #else
        let keyboard: [String] = []
        #endif
        let supported: [String]
        let installed: [String]
        if scripted {
            supported = (launchSettings["KANBANCODE_DICTATION_LOCALES"] ?? "en_US,en_GB,pt_BR,fr_FR").split(separator: ",").map(String.init)
            installed = supported
        } else {
            guard SpeechTranscriber.isAvailable else { return Languages() }
            supported = await SpeechTranscriber.supportedLocales.map(\.identifier)
            installed = await SpeechTranscriber.installedLocales.map(\.identifier)
            let system = Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
            if let closest = await SpeechTranscriber.supportedLocale(equivalentTo: system) {
                preferred.insert(closest.identifier, at: 0)
            }
        }
        let own = preferred + keyboard
        return Languages(
            all: Dictation.orderedLocales(preferred: own, supported: supported) { name($0) },
            suggested: Dictation.languages(preferred: own, supported: supported).count,
            installed: Set(installed.map(Dictation.normalised)),
            preferred: preferred,
            keyboard: keyboard)
    }

    static func microphoneAllowed() async -> Bool {
        if launchSettings["KANBANCODE_DICTATION_DENIED"] == "1" { return false }
        if launchSettings["KANBANCODE_DICTATION_SCRIPT"] != nil { return true }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
}

/// The voice's latest loudness, 0 to 1. A plain box outside observation: the audio writes it about
/// fifty times a second and only the level line's frames read it.
public final class DictationMeter {
    public var level = 0.0
    public init() {}
}
#endif
