import Foundation

public enum MastracodeSessionPath {
    public static func encode(databasePath: String, threadId: String) -> String {
        "\(databasePath)#\(threadId)"
    }

    public static func decode(_ sessionPath: String) -> (databasePath: String, threadId: String)? {
        guard let split = sessionPath.lastIndex(of: "#") else { return nil }
        let databasePath = String(sessionPath[..<split])
        let threadId = String(sessionPath[sessionPath.index(after: split)...])
        guard !databasePath.isEmpty, !threadId.isEmpty else { return nil }
        return (databasePath, threadId)
    }
}

