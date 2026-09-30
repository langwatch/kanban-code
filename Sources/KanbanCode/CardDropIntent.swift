import KanbanCodeCore

enum CardDropIntent: Equatable {
    case move
    case start
    case resume
    case archive
    case invalid(String)

    var isAllowed: Bool {
        if case .invalid = self {
            return false
        }
        return true
    }

    static func resolve(_ card: KanbanCodeCard, to column: KanbanCodeColumn) -> CardDropIntent {
        switch column {
        case .inProgress:
            if card.link.tmuxLink != nil {
                return .invalid("Session is already running - card moves to In Progress automatically when Claude is actively working")
            }
            if card.column == .backlog && card.link.sessionLink == nil {
                return .start
            }
            if card.link.sessionLink != nil {
                return .resume
            }
            return .move

        case .inReview:
            if card.link.prLinks.isEmpty {
                return .invalid("Cannot move to In Review - card has no pull request")
            }
            return .move

        case .allSessions:
            return .archive

        // Done accepts any card: work merged locally never has a PR to prove it.
        case .backlog, .waiting, .done:
            return .move
        }
    }
}
