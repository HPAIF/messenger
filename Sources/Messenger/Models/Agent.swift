import Foundation

/// An agent provided by an installed Claude Code plugin, addressed as `<plugin>:<name>`.
struct Agent: Identifiable, Hashable, Codable, Sendable {
    /// Full agent id passed to `claude --agent`, e.g. `ai-lawyer:lawyer`.
    var id: String
    var plugin: String
    var marketplace: String
    /// Short name from the agent's frontmatter, e.g. `lawyer`.
    var name: String
    /// Human title shown in the UI, e.g. `AI Lawyer`.
    var title: String
    var description: String
    /// Optional colour name from the agent's frontmatter (`blue`, `green`, ...).
    var colorName: String?

    /// Used when a conversation refers to an agent that is no longer installed.
    static func placeholder(id: String) -> Agent {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.last ?? id
        return Agent(
            id: id,
            plugin: parts.first ?? id,
            marketplace: "",
            name: name,
            title: prettify(name),
            description: "Not installed",
            colorName: nil
        )
    }

    /// `ai-lawyer` -> `AI Lawyer`, `cto` -> `CTO`.
    static func prettify(_ raw: String) -> String {
        let acronyms: Set<String> = ["ai", "cto", "cfo", "ceo", "coo", "cmo", "hr", "qa", "ux", "ui", "seo", "pr"]
        return raw
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { word in
                let w = word.lowercased()
                return acronyms.contains(w) ? w.uppercased() : w.prefix(1).uppercased() + w.dropFirst()
            }
            .joined(separator: " ")
    }
}
