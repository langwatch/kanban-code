import Foundation
import KanbanCodeRemoteKit

/// Delivers attention requests: a notification on the Mac, a silent copy on
/// the phone, and a phone alert when the request waits too long or the Mac
/// is away. Applies `AttentionPolicy` on every change and on a timer.
public actor AttentionCenter: AttentionDelivering {
    private var open: [String: AttentionRequest] = [:]
    private var delivered: [String: AttentionDeliveryState] = [:]
    private var reportedPresence: MacPresence?
    private var settings: AttentionPolicySettings
    private let mac: (any MacAttentionNotifier)?
    private var phone: (any PhonePushSender)?
    private let localPresence: (@Sendable () async -> MacPresence?)?
    private let cardName: @Sendable (String?) async -> String?
    private let localMachineId: @Sendable () async -> String?
    private let now: @Sendable () -> Date
    private var loop: Task<Void, Never>?
    /// Where delivery state is kept across restarts, so a request raised
    /// again after one is neither sent twice nor left on screen.
    private let stateFile: String?
    /// State read from `stateFile` for requests not raised again yet.
    private var restored: [String: AttentionDeliveryState] = [:]
    private let startedAt: Date
    /// How long after start a restored request may still be raised again
    /// before its notifications are taken down.
    private let restoreGrace: TimeInterval

    /// Steps taken, newest last, for the log and for tests.
    public private(set) var history: [(id: String, step: AttentionDeliveryStep)] = []

    public init(
        settings: AttentionPolicySettings = .init(),
        mac: (any MacAttentionNotifier)? = nil,
        phone: (any PhonePushSender)? = nil,
        localPresence: (@Sendable () async -> MacPresence?)? = nil,
        cardName: @escaping @Sendable (String?) async -> String? = { _ in nil },
        localMachineId: @escaping @Sendable () async -> String? = { nil },
        now: @escaping @Sendable () -> Date = { Date() },
        stateFile: String? = nil,
        restoreGrace: TimeInterval = 60
    ) {
        self.settings = settings
        self.mac = mac
        self.phone = phone
        self.localPresence = localPresence
        self.cardName = cardName
        self.localMachineId = localMachineId
        self.now = now
        self.stateFile = stateFile
        self.restoreGrace = restoreGrace
        self.startedAt = now()
        self.restored = stateFile.map(Self.load) ?? [:]
    }

    public func configure(settings: AttentionPolicySettings, phone: (any PhonePushSender)?) {
        self.settings = settings
        self.phone = phone
    }

    /// Presence a peer Mac reported, used when this master has no screen.
    public func reportPresence(_ presence: MacPresence) async {
        reportedPresence = presence
        await evaluateAll()
    }

    public func currentPresence() async -> MacPresence? {
        if let localPresence { return await localPresence() }
        return reportedPresence
    }

    /// Re-checks every open request every `interval` until cancelled.
    public func start(interval: Duration = .seconds(5)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.evaluateAll()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: AttentionDelivering

    public func deliver(_ request: AttentionRequest) async {
        let isNew = open[request.id] == nil
        open[request.id] = request
        if delivered[request.id] == nil {
            var restoredState = restored.removeValue(forKey: request.id)
            // The app's sheet does not outlive a restart: show it again.
            restoredState?.shownInApp = false
            delivered[request.id] = restoredState ?? AttentionDeliveryState()
            KanbanCodeLog.info("attention", "Raised \(request.id) kind=\(request.kind.rawValue) card=\(request.cardId ?? "none") machine=\(request.machineId ?? "local")\(restoredState.map { " (delivered before a restart: \($0))" } ?? "")")
        }
        if isNew { await mac?.showOpenCount(open.count) }
        await evaluate(request.id, explain: true)
    }

    public func update(_ request: AttentionRequest) async {
        open[request.id] = request
        await evaluate(request.id)
    }

    public func withdraw(_ request: AttentionRequest) async {
        if open.removeValue(forKey: request.id) != nil {
            await mac?.showOpenCount(open.count)
        }
        let state = delivered.removeValue(forKey: request.id) ?? AttentionDeliveryState()
        if state.macPosted {
            await mac?.remove(id: request.id)
            history.append((request.id, .removeMac))
        }
        if state.phoneSilentSent || state.phoneAlertSent {
            await phone?.withdraw(request)
        }
        save()
        KanbanCodeLog.info("attention", "Withdrew \(request.id) (\(request.resolution ?? "no answer") by \(request.resolvedBy ?? "?"))")
    }

    // MARK: Policy

    public func evaluateAll() async {
        for id in open.keys.sorted() {
            await evaluate(id)
        }
        await dropStaleRestored()
    }

    /// Takes down what was delivered before a restart for requests that
    /// were not raised again: they were settled while this master was down.
    private func dropStaleRestored() async {
        guard !restored.isEmpty, now().timeIntervalSince(startedAt) >= restoreGrace else { return }
        let stale = restored
        restored = [:]
        for (id, state) in stale where state.macPosted {
            await mac?.remove(id: id)
            history.append((id, .removeMac))
        }
        save()
    }

    private func evaluate(_ id: String, explain: Bool = false) async {
        guard let request = open[id] else { return }
        let presence = await currentPresence()
        let ownsPhone: Bool
        if let owner = request.machineId, let local = await localMachineId() {
            ownsPhone = owner == local
        } else {
            ownsPhone = true
        }
        var policy = settings
        var phoneNote = ""
        if request.isDeviceEnrolment {
            policy.phoneEnabled = false
            phoneNote = " (a device enrolment: the phone that asked cannot approve it, the Mac does)"
        } else if !ownsPhone {
            policy.phoneEnabled = false
            phoneNote = " (the master that raised it sends to the phone)"
        } else if phone == nil {
            policy.phoneEnabled = false
            if settings.phoneEnabled { phoneNote = " (no phone channel configured)" }
        }
        if let phone, !phone.sendsSilentCopy { policy.phoneSilentCopy = false }
        let at = now()
        let steps = AttentionPolicy.steps(
            for: request, delivered: delivered[id] ?? .init(), presence: presence,
            now: at, settings: policy, macAvailable: mac != nil)
        if explain {
            let why = AttentionPolicy.explain(request, presence: presence, now: at, settings: policy, macAvailable: mac != nil)
            KanbanCodeLog.info("attention", "\(id): steps=\(steps.map { "\($0)" }) because \(why)\(phoneNote)")
        }
        guard !steps.isEmpty else { return }
        let name = await cardName(request.cardId)
        for step in steps {
            // A request resolved while an earlier step awaited is left alone.
            guard open[id] != nil else { return }
            var state = delivered[id] ?? .init()
            switch step {
            case .postMac:
                await mac?.post(request, cardName: name)
                state.macPosted = true
            case .removeMac:
                await mac?.remove(id: id)
                state.macPosted = false
            case .showInApp:
                await mac?.showInApp(request)
                state.shownInApp = true
            case .phoneSilent:
                state.phoneSilentSent = true
                delivered[id] = state
                await sendPhone(request, name: name, level: .passive)
            case .phoneAlert:
                state.phoneAlertSent = true
                delivered[id] = state
                await sendPhone(request, name: name, level: .timeSensitive)
            }
            if open[id] != nil { delivered[id] = state }
            history.append((id, step))
            KanbanCodeLog.info("attention", "\(id): \(step)")
        }
        save()
    }

    private func sendPhone(_ request: AttentionRequest, name: String?, level: PhonePushLevel) async {
        guard let phone else {
            KanbanCodeLog.warn("attention", "Phone \(level.rawValue) for \(request.id) not sent: no phone channel")
            return
        }
        do {
            try await phone.send(request, cardName: name, level: level)
        } catch {
            KanbanCodeLog.warn("attention", "Phone push of \(request.id) failed: \(error)")
        }
    }

    public func deliveryState(_ id: String) -> AttentionDeliveryState? { delivered[id] }

    // MARK: State file

    private func save() {
        guard let stateFile else { return }
        let all = restored.merging(delivered) { _, live in live }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(
            atPath: (stateFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: stateFile), options: .atomic)
    }

    private static func load(_ path: String) -> [String: AttentionDeliveryState] {
        guard let data = FileManager.default.contents(atPath: path),
              let states = try? JSONDecoder().decode([String: AttentionDeliveryState].self, from: data)
        else { return [:] }
        return states
    }
}
