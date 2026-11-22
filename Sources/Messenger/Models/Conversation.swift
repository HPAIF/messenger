import Foundation

/// A one-to-one or group chat. Saved as one JSON file per conversation.
struct Conversation: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    /// Agent ids (`<plugin>:<agent>`), in the order they reply.
    var participants: [String]
    var messages: [Message] = []
    /// Claude Code session id per agent, used with `--resume`.
    var sessionIDs: [String: String] = [:]
    /// Group chats: id of the last message each agent has been given, so its next turn includes
    /// everything said since (founder messages too). Optional so older files still load.
    var lastSeenMessageID: [String: UUID]?
    /// Company folder the agents run in. Sessions are tied to it, so it is fixed per conversation.
    var workspacePath: String?
    var createdAt = Date()
    var updatedAt = Date()

    var isGroup: Bool { participants.count > 1 }

    var preview: String {
        guard let last = messages.last(where: { $0.kind != .notice }) else { return "No messages yet" }
        let text = last.text.isEmpty ? (last.error ?? "") : last.text
        return text.replacingOccurrences(of: "\n", with: " ")
    }
}
