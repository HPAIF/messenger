import Foundation

/// Events produced while a `claude -p --output-format stream-json` run is in progress.
enum RunEvent: Sendable, Equatable {
    /// Session id reported by the CLI (init/result events). Store it for `--resume`.
    case session(String)
    /// A chunk of assistant text to append to the reply.
    case text(String)
    /// A one-line tool activity summary, e.g. "🔧 Read notes.md".
    case tool(String)
    /// The final `result` event.
    case result(text: String?, isError: Bool)
    /// The process ended. Always the last event.
    case exited(code: Int32, stderr: String)
}

/// Turns stream-json lines into `RunEvent`s.
///
/// With `--include-partial-messages` text arrives as `stream_event` deltas and again in the
/// complete `assistant` message; text already streamed for a message id is not repeated.
struct StreamParser {
    private(set) var sessionID: String?
    private var streamedMessageIDs: Set<String> = []
    private var currentStreamMessageID: String?
    private var lastTextMessageID: String?
    private var hasEmittedText = false

    mutating func parse(line: String) -> [RunEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return [] }

        var events: [RunEvent] = []
        if let id = object["session_id"] as? String, id != sessionID {
            sessionID = id
            events.append(.session(id))
        }
        // Skip traffic from subagents the agent may spawn; only the main reply is shown.
        if object["parent_tool_use_id"] is String { return events }

        switch type {
        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  let eventType = event["type"] as? String else { break }
            if eventType == "message_start" {
                currentStreamMessageID = (event["message"] as? [String: Any])?["id"] as? String
            } else if eventType == "content_block_delta",
                      let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String {
                if let id = currentStreamMessageID { streamedMessageIDs.insert(id) }
                events.append(emitText(text, messageID: currentStreamMessageID))
            }

        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { break }
            let messageID = message["id"] as? String
            let alreadyStreamed = messageID.map { streamedMessageIDs.contains($0) } ?? false
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if !alreadyStreamed, let text = block["text"] as? String, !text.isEmpty {
                        events.append(emitText(text, messageID: messageID))
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    events.append(.tool(Self.toolSummary(name: name, input: block["input"] as? [String: Any])))
                default:
                    break
                }
            }

        case "result":
            let subtype = object["subtype"] as? String
            let isError = (object["is_error"] as? Bool) ?? (subtype != "success")
            var text = object["result"] as? String
            if text == nil, let errors = object["errors"] as? [String], !errors.isEmpty {
                text = errors.joined(separator: "\n")
            }
            events.append(.result(text: text, isError: isError))

        default:
            break
        }
        return events
    }

    /// Separates text from different assistant messages (e.g. before and after a tool call).
    private mutating func emitText(_ text: String, messageID: String?) -> RunEvent {
        var chunk = text
        if hasEmittedText, messageID != lastTextMessageID { chunk = "\n\n" + chunk }
        hasEmittedText = true
        lastTextMessageID = messageID
        return .text(chunk)
    }

    static func toolSummary(name: String, input: [String: Any]?) -> String {
        // mcp__server__tool -> tool
        let shortName = name.hasPrefix("mcp__") ? String(name.split(separator: "_").last ?? Substring(name)) : name
        let keys = ["file_path", "path", "pattern", "command", "url", "query", "skill", "description", "subagent_type"]
        var detail = keys.lazy.compactMap { input?[$0] as? String }.first ?? ""
        detail = detail.replacingOccurrences(of: "\n", with: " ")
        if detail.count > 80 { detail = String(detail.prefix(79)) + "…" }
        return detail.isEmpty ? "🔧 \(shortName)" : "🔧 \(shortName) \(detail)"
    }
}
