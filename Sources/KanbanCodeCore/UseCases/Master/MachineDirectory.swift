import Foundation

/// One machine as the launch dialogs, the phone and the API offer it. An
/// ssh machine that also runs kanban-code-server, paired as a peer master,
/// is one machine: cards that run there are owned by its master, so they
/// keep going while this one is offline. The plain ssh path is left for
/// machines without a master.
public struct MachineChoice: Sendable, Equatable {
    /// Name shown and accepted as the target: the ssh machine's name when
    /// the machine is one, else the peer's name.
    public var name: String
    /// The peer master on the machine, when it runs one.
    public var master: MachineIdentity?
    public var masterOnline: Bool
    /// The ssh machine, when this master can reach it over ssh.
    public var sshMachine: SshMachine?

    public init(name: String, master: MachineIdentity? = nil, masterOnline: Bool = false, sshMachine: SshMachine? = nil) {
        self.name = name
        self.master = master
        self.masterOnline = masterOnline
        self.sshMachine = sshMachine
    }
}

public enum MachineDirectory {
    /// The host part of an ssh target: `user@host:port`, `[v6]` or an alias.
    public static func host(ofSshTarget target: String) -> String {
        var s = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            return String(s[s.index(after: s.startIndex)..<close]).lowercased()
        }
        if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return s.lowercased()
    }

    /// The host of a peer's Remote Control URL.
    public static func host(ofURL url: String) -> String? {
        URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
    }

    /// Whether the ssh machine and the peer are the same host: the ssh
    /// target reaches the peer's URL host, or the names match.
    public static func isSameMachine(_ ssh: SshMachine, _ status: PeerStatus, peerName: String? = nil) -> Bool {
        let sshHost = host(ofSshTarget: ssh.target)
        if !sshHost.isEmpty, let url = status.url, host(ofURL: url) == sshHost { return true }
        let name = ssh.name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return false }
        if let machine = status.machine, machine.name.lowercased() == name { return true }
        if let peerName, peerName.lowercased() == name { return true }
        return sshHost == status.machine?.name.lowercased()
    }

    /// Every machine a card can run on besides this master, one entry per
    /// machine: the ssh machines (with their master when they run one),
    /// then the peer masters that are no ssh machine.
    public static func choices(sshMachines: [SshMachine], peers: [PeerStatus]) -> [MachineChoice] {
        let known = peers.filter { $0.machine != nil }
            .sorted { ($0.machine?.name ?? "") < ($1.machine?.name ?? "") }
        var used = Set<String>()
        var out: [MachineChoice] = []
        for ssh in sshMachines where ssh.isComplete {
            var choice = MachineChoice(name: ssh.name, sshMachine: ssh)
            if let peer = known.first(where: { !used.contains($0.peerId) && isSameMachine(ssh, $0) }) {
                used.insert(peer.peerId)
                choice.master = peer.machine
                choice.masterOnline = peer.online
            }
            out.append(choice)
        }
        for peer in known where !used.contains(peer.peerId) {
            guard let machine = peer.machine else { continue }
            out.append(MachineChoice(name: machine.name, master: machine, masterOnline: peer.online))
        }
        return out
    }
}

extension AppState {
    /// The machines cards can run on besides this master (see `MachineDirectory`).
    public var machineChoices: [MachineChoice] {
        MachineDirectory.choices(sshMachines: boxdSettings?.sshMachines ?? [], peers: Array(peerStatuses.values))
    }

    /// The peer master `target` names: its machine id, its name, or the
    /// name of the ssh machine it runs on (any case).
    public func peerMachine(named target: String) -> MachineIdentity? {
        let wanted = target.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let lower = wanted.lowercased()
        for status in peerStatuses.values {
            guard let machine = status.machine else { continue }
            if machine.id == wanted || machine.name.lowercased() == lower { return machine }
        }
        return machineChoices.first { $0.name.lowercased() == lower }?.master
    }

    /// The name the machine choices give the peer master that owns the
    /// card (or takes it over), when that is not this master.
    public func ownerMachineChoice(cardId: String) -> String? {
        guard let owner = links[cardId]?.ownerMachine, !localMachineId.isEmpty, owner != localMachineId else { return nil }
        return machineChoices.first { $0.master?.id == owner }?.name
            ?? peerStatuses.values.first { $0.machine?.id == owner }?.machine?.name
    }

    /// The name of the peer master with this machine id: what it reports
    /// now, else the last name it reported, also from an earlier launch.
    /// nil for a machine never seen.
    public func peerMachineName(_ machineId: String) -> String? {
        peerStatuses.values.first { $0.machine?.id == machineId }?.machine?.name
            ?? knownMachineNames[machineId]
    }

    /// The line of a card moving between masters, with how far its
    /// transcript copy got; nil when the card is not moving.
    public func handoverLine(cardId: String) -> String? {
        guard let link = links[cardId], link.migrating == true else { return nil }
        func name(_ id: String?) -> String {
            guard let id else { return "another master" }
            return peerMachineName(id) ?? id
        }
        var text = isOwnedLocally(link)
            ? "Moving here from \(name(link.ownerRev?.machine))"
            : "Moving to \(name(link.ownerMachine))"
        if case .moving(let progress) = cardStarts[cardId], progress.totalBytes > 0 {
            text += ", copying the transcript (\(progress.label))"
        }
        return text
    }

    /// The ssh machine `name` names, when its master is the peer `machineId`.
    public func sshMachine(named name: String, runningMaster machineId: String) -> SshMachine? {
        machineChoices.first { $0.name.lowercased() == name.lowercased() && $0.master?.id == machineId }?.sshMachine
    }
}
