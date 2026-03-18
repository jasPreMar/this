import Foundation

struct PersistedMessage: Codable {
    let role: String
    let text: String
}

struct PersistedChatSession: Codable {
    let id: String
    var sessionId: String?
    var title: String
    var subtitle: String
    var messages: [PersistedMessage]
    var startedAt: Date
    var completedAt: Date?
    var lastActivityAt: Date
    var workingDirectoryPath: String?
}

final class ChatSessionStore {
    static let shared = ChatSessionStore()

    private let sessionsDirectory: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDirectory = appSupport.appendingPathComponent("HyperPointer/ChatSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    }

    private func fileURL(for id: String) -> URL {
        sessionsDirectory.appendingPathComponent("\(id).json")
    }

    func save(_ session: PersistedChatSession) {
        do {
            let data = try encoder.encode(session)
            try data.write(to: fileURL(for: session.id), options: .atomic)
        } catch {
            print("[ChatSessionStore] Failed to save session \(session.id): \(error)")
        }
    }

    func loadAll() -> [PersistedChatSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return files.compactMap { url -> PersistedChatSession? in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(PersistedChatSession.self, from: data)
        }
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }
}
