import Foundation

/// Registry that maps `CodingAssistant` enum values to their adapter instances
/// (discovery, activity detector, session store). Used by composite adapters
/// to route operations to the correct assistant-specific implementation.
public final class CodingAssistantRegistry: @unchecked Sendable {
    private var discoveries: [CodingAssistant: SessionDiscovery] = [:]
    private var detectors: [CodingAssistant: ActivityDetector] = [:]
    private var stores: [CodingAssistant: SessionStore] = [:]

    public init() {}

    /// Register all three adapters for a coding assistant.
    public func register(
        _ assistant: CodingAssistant,
        discovery: SessionDiscovery,
        detector: ActivityDetector,
        store: SessionStore
    ) {
        discoveries[assistant] = discovery
        detectors[assistant] = detector
        stores[assistant] = store
    }

    /// Returns the session discovery adapter for the given assistant, if registered.
    public func discovery(for assistant: CodingAssistant) -> SessionDiscovery? {
        discoveries[assistant]
    }

    /// Returns the activity detector for the given assistant, if registered.
    public func detector(for assistant: CodingAssistant) -> ActivityDetector? {
        detectors[assistant]
    }

    /// Returns the session store for the given assistant, if registered.
    public func store(for assistant: CodingAssistant) -> SessionStore? {
        stores[assistant]
    }

    /// Remove all adapters for a coding assistant.
    public func unregister(_ assistant: CodingAssistant) {
        discoveries.removeValue(forKey: assistant)
        detectors.removeValue(forKey: assistant)
        stores.removeValue(forKey: assistant)
    }

    /// All registered assistants, sorted by raw value for deterministic ordering.
    public var available: [CodingAssistant] {
        Array(discoveries.keys).sorted { $0.rawValue < $1.rawValue }
    }
}
