#if canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import Foundation
import os
import Speech

/// What an engine reports while it listens: model download progress, the model being ready, how
/// loud, the words so far, or why the model could not load.
public enum DictationUpdate: Sendable {
    case downloading(Double)
    case ready
    case failed(String)
    case level(Double)
    case text(settled: String, guessing: String)
}

/// Something that turns the microphone into words: Apple's on-device SpeechTranscriber, or the
/// UI tests' scripted stand-in. Calls come one at a time from the composer.
public protocol DictationEngine: AnyObject, Sendable {
    /// Turns the microphone on and returns; the model loads behind it and reports `.ready`.
    func start(locale: String, update: @escaping @Sendable (DictationUpdate) -> Void) async throws
    /// Stops the microphone and returns once the model is ready and the last words have settled.
    func stop() async
    func cancel() async
}

public struct DictationFailure: LocalizedError {
    public let errorDescription: String?
    public init(_ reason: String) { errorDescription = reason }
}

/// A transcriber and its analyzer with the language's model loaded, ready to take audio.
final class VoiceModel: @unchecked Sendable {
    let locale: String
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let format: AVAudioFormat

    init(locale: String, transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat) {
        self.locale = locale
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
    }
}

/// Keeps one loaded model for five idle minutes after a dictation, so the next one starts warm.
actor VoiceModelShelf {
    static let shared = VoiceModelShelf()
    static let idle: Duration = .seconds(300)
    private var kept: VoiceModel?
    private var expiry: Task<Void, Never>?

    func take(_ locale: String) -> VoiceModel? {
        guard let kept, kept.locale == locale else { return nil }
        self.kept = nil
        return kept
    }

    func keep(_ model: VoiceModel) {
        kept = model
        expiry?.cancel()
        expiry = Task {
            try? await Task.sleep(for: Self.idle)
            if !Task.isCancelled { self.drop() }
        }
    }

    private func drop() { kept = nil }
}

/// Apple's on-device SpeechTranscriber fed from the microphone; speech never leaves the device.
/// The microphone starts at once and its sound waits in a buffer while the model loads or
/// downloads, then goes to the analyzer.
public final class TranscriberDictation: DictationEngine, @unchecked Sendable {
    private var audio: AVAudioEngine?
    private var model: Task<Running, Error>?
    private var locale = ""

    public init() {}

    private struct Running: Sendable {
        let model: VoiceModel
        let input: AsyncStream<AnalyzerInput>.Continuation
        let results: Task<Void, Never>
    }

    public func start(locale identifier: String, update: @escaping @Sendable (DictationUpdate) -> Void) async throws {
        locale = identifier
        let tap: Tap
        do {
            tap = try startMicrophone(update: update)
        } catch {
            stopMicrophone()
            throw error
        }
        model = Task {
            do {
                let model = try await Self.load(identifier, update: update)
                try Task.checkCancellation()
                guard let converter = AVAudioConverter(from: tap.microphone, to: model.format) else {
                    throw DictationFailure("The microphone's sound cannot be read for dictation.")
                }
                let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
                let results = Self.read(model.transcriber, update: update)
                tap.attach(Tap.Sink(converter: converter, format: model.format, input: input))
                try await model.analyzer.start(inputSequence: stream)
                update(.ready)
                return Running(model: model, input: input, results: results)
            } catch {
                if !Task.isCancelled { update(.failed(error.localizedDescription)) }
                throw error
            }
        }
    }

    /// The shelf's warm model for the language, else a newly loaded one (downloading it first).
    private static func load(_ identifier: String, update: (@Sendable (DictationUpdate) -> Void)?) async throws -> VoiceModel {
        if let warm = await VoiceModelShelf.shared.take(identifier) { return warm }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) ?? Locale(identifier: identifier)
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            // Warming the shelf never downloads.
            guard let update else { throw CancellationError() }
            try await install(request, update: update)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationFailure("Dictation does not support this language on this device.")
        }
        let analyzer = SpeechAnalyzer(
            modules: [transcriber], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        try await analyzer.prepareToAnalyze(in: format)
        return VoiceModel(locale: identifier, transcriber: transcriber, analyzer: analyzer, format: format)
    }

    /// Loads a fresh analyzer for the language onto the shelf; one analyzer serves one dictation.
    private static func warm(_ identifier: String) {
        Task.detached(priority: .utility) {
            guard let model = try? await load(identifier, update: nil) else { return }
            await VoiceModelShelf.shared.keep(model)
        }
    }

    private static func read(_ transcriber: SpeechTranscriber, update: @escaping @Sendable (DictationUpdate) -> Void) -> Task<Void, Never> {
        Task {
            var settled = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        settled = Dictation.join(settled, text)
                        update(.text(settled: settled, guessing: ""))
                    } else {
                        update(.text(settled: settled, guessing: text))
                    }
                }
            } catch {}
        }
    }

    private func startMicrophone(update: @escaping @Sendable (DictationUpdate) -> Void) throws -> Tap {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Measurement turns off the gain control, which suits the transcriber.
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        // A new engine each time: a reused one keeps the old microphone's format after a switch.
        let engine = AVAudioEngine()
        audio = engine
        let node = engine.inputNode
        let microphone = node.inputFormat(forBus: 0)
        guard microphone.sampleRate > 0, microphone.channelCount > 0 else {
            throw DictationFailure("This device has no microphone Kanban Code can use.")
        }
        let tap = Tap(microphone: microphone, update: update)
        node.installTap(onBus: 0, bufferSize: 1024, format: microphone, block: Self.block(tap))
        engine.prepare()
        try engine.start()
        return tap
    }

    /// Downloads the language's model, reporting its progress until it is installed.
    private static func install(_ request: AssetInstallationRequest, update: @escaping @Sendable (DictationUpdate) -> Void) async throws {
        let progress = Watched(request.progress)
        update(.downloading(0))
        let watcher = Task {
            while !Task.isCancelled {
                update(.downloading(min(progress.value.fractionCompleted, 0.99)))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        update(.downloading(1))
    }

    public func stop() async {
        // People tap stop as the last word ends: listen a moment longer, then add silence so the
        // transcriber commits the last word instead of dropping it.
        try? await Task.sleep(for: .milliseconds(200))
        stopMicrophone()
        guard let running = try? await model?.value else { return }
        let format = running.model.format
        if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 0.6)) {
            silence.frameLength = silence.frameCapacity
            for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            running.input.yield(AnalyzerInput(buffer: silence))
        }
        running.input.finish()
        try? await running.model.analyzer.finalizeAndFinishThroughEndOfInput()
        await running.results.value
        model = nil
        Self.warm(locale)
    }

    public func cancel() async {
        let model = model
        self.model = nil
        model?.cancel()
        stopMicrophone()
        guard let running = try? await model?.value else { return }
        running.input.finish()
        await running.model.analyzer.cancelAndFinishNow()
        running.results.cancel()
        Self.warm(locale)
    }

    private func stopMicrophone() {
        guard let audio else { return }
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        self.audio = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// The download's Progress, read by the watcher while the install runs.
    private struct Watched: @unchecked Sendable {
        let value: Progress
        init(_ value: Progress) { self.value = value }
    }

    /// The audio thread's side: reports the level, and keeps the sound until the model is ready,
    /// then converts it and every later buffer for the analyzer, in order.
    private final class Tap: @unchecked Sendable {
        struct Sink {
            let converter: AVAudioConverter
            let format: AVAudioFormat
            let input: AsyncStream<AnalyzerInput>.Continuation
        }

        let microphone: AVAudioFormat
        let update: @Sendable (DictationUpdate) -> Void
        private let lock = NSLock()
        private var pending: [AVAudioPCMBuffer] = []
        private var pendingFrames: AVAudioFramePosition = 0
        private var sink: Sink?

        init(microphone: AVAudioFormat, update: @escaping @Sendable (DictationUpdate) -> Void) {
            self.microphone = microphone
            self.update = update
        }

        func receive(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            if let sink {
                Self.feed(buffer, to: sink)
                return
            }
            // Up to ten minutes of sound waits for a model download.
            guard pendingFrames < AVAudioFramePosition(microphone.sampleRate * 600), let copy = Self.copy(buffer) else { return }
            pending.append(copy)
            pendingFrames += AVAudioFramePosition(copy.frameLength)
        }

        func attach(_ sink: Sink) {
            lock.lock()
            defer { lock.unlock() }
            for buffer in pending { Self.feed(buffer, to: sink) }
            pending = []
            self.sink = sink
        }

        private static func feed(_ buffer: AVAudioPCMBuffer, to sink: Sink) {
            let ratio = sink.format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: sink.format, frameCapacity: capacity) else { return }
            var fed = false
            sink.converter.convert(to: converted, error: nil) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard converted.frameLength > 0 else { return }
            sink.input.yield(AnalyzerInput(buffer: converted))
        }

        /// The tap reuses its buffers, so a kept one is copied.
        private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
            copy.frameLength = buffer.frameLength
            let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (source, target) in zip(from, to) {
                guard let data = source.mData, let destination = target.mData else { continue }
                memcpy(destination, data, Int(min(source.mDataByteSize, target.mDataByteSize)))
            }
            return copy
        }
    }

    /// Built outside any actor: the audio thread calls it, and an actor-bound block would trap.
    private static func block(_ tap: Tap) -> AVAudioNodeTapBlock {
        { buffer, _ in
            tap.update(.level(Dictation.level(decibels: decibels(buffer))))
            tap.receive(buffer)
        }
    }

    private static func decibels(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        var sum: Float = 0
        for index in 0 ..< Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        return Double(20 * log10(max(sqrt(sum / Float(buffer.frameLength)), 1e-6)))
    }
}

/// The UI tests' stand-in, on KANBANCODE_DICTATION_SCRIPT: the level moves from the first moment
/// and a word is heard every 600 ms; words show once the model is ready
/// (KANBANCODE_DICTATION_LOAD seconds), warm for five minutes after. KANBANCODE_DICTATION_FAIL
/// makes the model fail with that reason.
public final class ScriptedDictation: DictationEngine, @unchecked Sendable {
    private let script: String
    private let loading: Double
    private let failure: String?
    private var playing: Task<Void, Never>?
    private var model: Task<Bool, Never>?
    private var update: (@Sendable (DictationUpdate) -> Void)?
    private let ready = OSAllocatedUnfairLock(initialState: false)
    private static let warmUntil = OSAllocatedUnfairLock<Date?>(initialState: nil)

    public init(script: String, loading: Double = 0, failure: String? = nil) {
        self.script = script
        self.loading = loading
        self.failure = failure
    }

    public func start(locale _: String, update: @escaping @Sendable (DictationUpdate) -> Void) async throws {
        self.update = update
        let warm = Self.warmUntil.withLock { ($0 ?? .distantPast) > .now }
        let loading = warm ? 0 : loading, failure = failure
        let ready = ready
        model = Task {
            if loading > 0 { try? await Task.sleep(for: .seconds(loading)) }
            if Task.isCancelled { return false }
            if let failure {
                update(.failed(failure))
                return false
            }
            ready.withLock { $0 = true }
            Self.warmUntil.withLock { $0 = .now.addingTimeInterval(300) }
            update(.ready)
            return true
        }
        let steps = Dictation.script(script)
        playing = Task {
            var tick = 0, shown = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                tick += 1
                update(.level(0.3 + 0.5 * abs(sin(Double(tick) * 0.7))))
                let heard = min(tick / 4, steps.count)
                guard heard > shown, ready.withLock({ $0 }) else { continue }
                shown = heard
                let step = steps[heard - 1]
                update(.text(settled: step.settled, guessing: step.guessing))
            }
        }
    }

    public func stop() async {
        playing?.cancel()
        guard await model?.value == true else { return }
        let words = script.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        update?(.text(settled: words, guessing: ""))
        update?(.level(0))
    }

    public func cancel() async {
        playing?.cancel()
        model?.cancel()
    }
}
#endif
