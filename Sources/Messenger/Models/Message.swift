import Foundation

/// A file the founder attached. The file is copied into the app's attachments folder, so the
/// original is never moved or changed; agents read the copy.
struct Attachment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// Absolute path of the copy inside the app's attachments folder.
    var path: String
    var size: Int64?
}

struct Message: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case user    // the founder
        case agent   // a reply from an agent
        case notice  // app-generated info line
    }

    var id = UUID()
    var kind: Kind
    /// Set for `.agent` messages.
    var agentID: String?
    var text: String = ""
    /// Short tool activity lines, e.g. "🔧 Read ai-team/lawyer/journal.md".
    var activity: [String] = []
    /// Error output (CLI result error or stderr) if the run failed.
    var error: String?
    /// Live status while the reply is in progress ("Reading notes.md", "typing").
    /// Optional so conversations saved by older versions still load.
    var status: String?
    var isStreaming = false
    var wasStopped = false
    var date = Date()
    /// Files attached to a founder message. Optional so older conversation files still load.
    var attachments: [Attachment]?
    /// Notice in a one-to-one chat: colleagues the agent addressed ("For @lawyer: …") whom the
    /// founder can add to the conversation with one click. Optional for older files.
    var inviteAgentIDs: [String]?
    /// Who asked for the invited colleagues (agent id).
    var invitedBy: String?
    /// Agent replies: false until the founder has seen the message on screen. nil (older files,
    /// founder messages, notices) counts as read.
    var isRead: Bool?

    var isUnread: Bool { kind == .agent && isRead == false && (!text.isEmpty || error != nil) }

    static func user(_ text: String, attachments: [Attachment] = []) -> Message {
        var message = Message(kind: .user, text: text)
        message.attachments = attachments.isEmpty ? nil : attachments
        return message
    }

    /// Text for an agent prompt: the message plus the paths of its attachments.
    var promptText: String {
        guard let attachments, !attachments.isEmpty else { return text }
        let list = attachments.map { "- \($0.name): \($0.path)" }.joined(separator: "\n")
        let lead = text.isEmpty ? "" : text + "\n\n"
        return lead + "Attached files (read them with the Read tool; the originals stay with the founder):\n" + list
    }
    static func notice(_ text: String) -> Message { Message(kind: .notice, text: text) }
}
