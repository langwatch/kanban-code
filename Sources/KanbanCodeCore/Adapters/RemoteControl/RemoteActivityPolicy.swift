import Foundation
import KanbanCodeRemoteKit

/// Which remote requests count as the human using a card from another
/// device (docs/remote-control.md, "Staying awake for the phone").
public enum RemoteActivityPolicy {
    /// A device of the human, or a paired master passing on what he does
    /// there. The masters' own sync carries no header, and agents never count.
    public static func actsForOwner(scope: RemoteScope, header: String?) -> Bool {
        switch scope {
        case .full: true
        case .peer: header == "1"
        case .agent, .terminal: false
        }
    }

    /// The card a request is about: any route under `cards/{id}`. A card
    /// search is about no card.
    public static func card(rest: [String]) -> String? {
        guard rest.count >= 2, rest[0] == "cards", !rest[1].isEmpty, rest != ["cards", "search"] else { return nil }
        return rest[1]
    }
}
