import Foundation
import Observation
import Security
import KanbanCodeRemoteKit

/// A Mac this phone has paired with. The token lives in the Keychain.
struct SavedServer: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var baseURL: URL
    var addedAt: Date
}

/// The paired Macs and which one is showing.
@Observable
final class ServerStore {
    private(set) var servers: [SavedServer] = []
    var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: Self.selectedKey) }
    }

    private static let listKey = "servers.v1"
    private static let selectedKey = "servers.selected"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.listKey),
           let saved = try? JSONDecoder().decode([SavedServer].self, from: data) {
            servers = saved
        }
        let selected = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
        selectedID = servers.contains { $0.id == selected } ? selected : servers.first?.id
    }

    var selected: SavedServer? { servers.first { $0.id == selectedID } }

    static func client(for server: SavedServer) -> RemoteClient? {
        guard let token = Keychain.token(for: server.id) else { return nil }
        return RemoteClient(baseURL: server.baseURL, token: token)
    }

    /// Adds the Mac, or replaces the token of one already saved at the same URL.
    @discardableResult
    func add(link: RemotePairLink, name: String) -> SavedServer {
        let server: SavedServer
        if let index = servers.firstIndex(where: { $0.baseURL == link.baseURL }) {
            servers[index].name = name
            server = servers[index]
        } else {
            server = SavedServer(id: UUID(), name: name, baseURL: link.baseURL, addedAt: .now)
            servers.append(server)
        }
        Keychain.setToken(link.token, for: server.id)
        persist()
        selectedID = server.id
        return server
    }

    func remove(_ server: SavedServer) {
        Keychain.deleteToken(for: server.id)
        servers.removeAll { $0.id == server.id }
        persist()
        if selectedID == server.id { selectedID = servers.first?.id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Self.listKey)
        }
    }
}

enum Keychain {
    private static let service = "io.kanbancode.mobile.token"

    static func token(for id: UUID) -> String? {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for id: UUID) {
        deleteToken(for: id)
        var query = base(id)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func deleteToken(for id: UUID) {
        SecItemDelete(base(id) as CFDictionary)
    }

    private static func base(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
}
