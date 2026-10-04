import Foundation
import Observation

/// Drives one card's side chat for a chat view: asks, follows the run while
/// its answer streams, and forgets it when dismissed. The Mac reaches the
/// runs through its engine, the phone through the remote API; both give
/// their calls as a `Transport`.
@MainActor
@Observable
public final class SideChatController {
    public struct Transport: Sendable {
        public var start: @Sendable (RemoteSideChatRequest) async throws -> RemoteSideChatRun
        public var poll: @Sendable (_ runId: String) async throws -> RemoteSideChatRun
        public var cancel: @Sendable (_ runId: String) async -> Void

        public init(start: @escaping @Sendable (RemoteSideChatRequest) async throws -> RemoteSideChatRun,
                    poll: @escaping @Sendable (_ runId: String) async throws -> RemoteSideChatRun,
                    cancel: @escaping @Sendable (_ runId: String) async -> Void) {
            self.start = start
            self.poll = poll
            self.cancel = cancel
        }

        /// The side chat of a card through the remote API.
        public static func remote(_ client: RemoteClient, cardId: String) -> Transport {
            Transport(
                start: { try await client.startSideChat(cardId: cardId, $0) },
                poll: { try await client.sideChatRun(cardId: cardId, runId: $0) },
                cancel: { try? await client.cancelSideChat(cardId: cardId, runId: $0) })
        }
    }

    public private(set) var state = SideChatState()
    private let transport: Transport
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var asked = 0
    /// How often a running answer is read.
    public var pollInterval: Duration = .milliseconds(250)

    public init(transport: Transport) {
        self.transport = transport
    }

    /// Opens the panel with nothing asked (`/btw` alone).
    public func open() {
        state.apply(.opened)
    }

    public func run(_ command: SideChatCommand) {
        switch command {
        case .catchup: ask(.catchup)
        case .btw(let question): question.isEmpty ? open() : ask(.btw, question: question)
        }
    }

    /// Asks in the side chat; earlier exchanges go along. One question at a
    /// time: a question asked while another is answered is dropped.
    /// `fresh` runs a new catch-up even when the kept one still covers the
    /// session.
    public func ask(_ kind: RemoteSideChatKind, question: String = "", fresh: Bool = false) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isRunning, kind == .catchup || !question.isEmpty else { return }
        let history = state.history
        asked += 1
        let localId = "local-\(asked)"
        state.apply(.asked(localId: localId, kind: kind,
                           question: kind == .catchup ? SideChatState.catchUpQuestion : question))
        let catchUpId = kind == .btw ? state.catchUpId : nil
        let request = RemoteSideChatRequest(kind: kind, question: kind == .btw ? question : nil,
                                            history: history.isEmpty ? nil : history,
                                            fresh: fresh ? true : nil, catchUpId: catchUpId)
        let transport = self.transport
        let interval = pollInterval
        task = Task { [weak self] in
            var id = localId
            do {
                var run = try await transport.start(request)
                guard let self, !Task.isCancelled else {
                    await transport.cancel(run.id)
                    return
                }
                id = run.id
                self.state.apply(.started(localId: localId, run: run))
                while run.state == .running {
                    try await Task.sleep(for: interval)
                    run = try await transport.poll(run.id)
                    if Task.isCancelled { return }
                    self.state.apply(.progress(run))
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? RemoteError)?.error ?? error.localizedDescription
                self?.state.apply(.failed(id: id, message: message, unreachable: SideChatFailure.isUnreachable(error)))
            }
        }
    }

    /// Asks the question that failed again, in its place.
    public func retry() {
        guard let failed = state.failedEntry else { return }
        state.apply(.removed(id: failed.id))
        ask(failed.kind, question: failed.kind == .btw ? failed.question : "")
    }

    /// Runs the catch-up again from nothing: the side chat starts over
    /// with a new answer.
    public func refresh() {
        guard !state.isRunning else { return }
        state.apply(.dismissed)
        ask(.catchup, fresh: true)
    }

    /// Closes the panel; a run still answering is stopped.
    public func dismiss() {
        let running = state.runningId
        task?.cancel()
        task = nil
        state.apply(.dismissed)
        if let running, !running.hasPrefix("local-") {
            let transport = self.transport
            Task { await transport.cancel(running) }
        }
    }

    /// The prompt that continues this side chat in the main chat with `reply`.
    public func mainChatPrompt(reply: String) -> String {
        SideChatHandoff.mainChatPrompt(reply: reply, entries: state.entries)
    }
}

#if !os(Linux)
/// A catch-up item as text with its citations as links, for a `Text` view.
public enum SideChatLinks {
    public static let scheme = "kanban-sidechat"

    /// `kanban-sidechat://ref/m7`
    public static func url(forRef ref: String) -> URL? {
        URL(string: "\(scheme)://ref/\(ref)")
    }

    /// The citation a link of an item points at.
    public static func ref(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "ref" else { return nil }
        let ref = url.lastPathComponent
        return ref.isEmpty ? nil : ref
    }

    /// What a citation link reads: the time of the message, or its id.
    public static func label(for citation: String, in refs: [RemoteSideChatRef], timeZone: TimeZone = .current) -> String {
        guard let at = refs.first(where: { $0.ref == citation })?.at else { return citation }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: at)
    }

    /// The item's text followed by one link per citation that names a
    /// message of the index. A citation the index does not hold is dropped.
    public static func attributed(_ item: CatchUpSummary.Item, refs: [RemoteSideChatRef],
                                  timeZone: TimeZone = .current) -> AttributedString {
        var out = AttributedString(item.text)
        for citation in item.refs {
            guard refs.contains(where: { $0.ref == citation }), let url = url(forRef: citation) else { continue }
            out.append(AttributedString(" "))
            var link = AttributedString("↗\u{00A0}" + label(for: citation, in: refs, timeZone: timeZone))
            link.link = url
            out.append(link)
        }
        return out
    }
}
#endif
