import Foundation

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

    static func user(_ text: String) -> Message { Message(kind: .user, text: text) }
    static func notice(_ text: String) -> Message { Message(kind: .notice, text: text) }
}
