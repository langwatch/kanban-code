import Foundation
#if canImport(IOKit)
import IOKit.pwr_mgt
#endif

/// Keeps the Mac awake for a while after the human used one of its cards
/// from another device. A Mac with its lid closed that woke for a moment
/// (a dark wake) goes back to sleep within a minute or two unless something
/// holds it; the phone would lose the card in the middle of an answer.
///
/// The hold is a `PreventSystemSleep` power assertion, which macOS honours
/// on AC power, also with the lid closed. It carries its own timeout, so
/// it ends even when the app does not come back to release it.
public final class RemoteWakeHold: @unchecked Sendable {
    public static let shared = RemoteWakeHold()
    /// How long after the last request the Mac stays awake. A side chat run
    /// ends within `SideChatRunner`'s 10 minutes, so the request that
    /// starts one covers the whole run.
    public static let window: TimeInterval = 10 * 60
    /// The UserDefaults key of the switch in Settings > Amphetamine. On
    /// unless turned off.
    public static let enabledKey = "remoteWakeHoldEnabled"

    public typealias Take = @Sendable (_ seconds: TimeInterval) -> UInt32?
    public typealias Drop = @Sendable (UInt32) -> Void

    private let lock = NSLock()
    private var until: Date?
    private var assertion: UInt32?
    private var takenAt: Date?
    private let take: Take
    private let drop: Drop
    private let enabled: @Sendable () -> Bool
    /// A new assertion replaces the held one at most this often.
    private let renewEvery: TimeInterval

    public init(take: @escaping Take = RemoteWakeHold.takeAssertion, drop: @escaping Drop = RemoteWakeHold.dropAssertion,
                enabled: @escaping @Sendable () -> Bool = RemoteWakeHold.enabledInSettings, renewEvery: TimeInterval = 30) {
        self.take = take
        self.drop = drop
        self.enabled = enabled
        self.renewEvery = renewEvery
    }

    public static func enabledInSettings() -> Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The human used a card on this Mac from another device.
    public func touch(card: String, now: Date = Date()) {
        guard enabled() else {
            release()
            return
        }
        lock.lock()
        let wasHolding = until.map { $0 > now } ?? false
        until = now.addingTimeInterval(Self.window)
        let renew = takenAt.map { now.timeIntervalSince($0) >= renewEvery } ?? true
        var old: UInt32?
        if renew {
            old = assertion
            // A little past the window, so the marker app and the assertion
            // do not end in the same second.
            assertion = take(Self.window + 30)
            takenAt = now
        }
        lock.unlock()
        if let old { drop(old) }
        if !wasHolding {
            KanbanCodeLog.info("wake", "Holding this Mac awake for \(Int(Self.window / 60)) min: card \(card.prefix(12)) was used from another device")
        }
    }

    /// Whether a request within the window still holds the Mac awake.
    public func isHolding(now: Date = Date()) -> Bool {
        guard enabled() else { return false }
        return lock.withLock { until.map { $0 > now } ?? false }
    }

    public func release() {
        lock.lock()
        let old = assertion
        assertion = nil
        takenAt = nil
        until = nil
        lock.unlock()
        if let old { drop(old) }
    }

    public static func takeAssertion(seconds: TimeInterval) -> UInt32? {
        #if canImport(IOKit)
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            "Kanban Code: a card on this Mac is in use from another device" as CFString,
            nil, nil, nil, seconds, kIOPMAssertionTimeoutActionRelease as CFString, &id)
        guard result == kIOReturnSuccess else {
            KanbanCodeLog.warn("wake", "could not take the power assertion: \(result)")
            return nil
        }
        return id
        #else
        return nil
        #endif
    }

    public static func dropAssertion(_ id: UInt32) {
        #if canImport(IOKit)
        IOPMAssertionRelease(id)
        #endif
    }
}
