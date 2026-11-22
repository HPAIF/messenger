import Foundation

/// Discovers agents from installed Claude Code plugins.
///
/// Reads `~/.claude/plugins/installed_plugins.json`, then each plugin's
/// `<installPath>/agents/*.md`, whose YAML frontmatter has `name` and `description`.
enum AgentCatalog {
    static let preferredMarketplace = "ai-team"

    static var defaultPluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/plugins")
    }

    static func discover(pluginsDirectory: URL = defaultPluginsDirectory) -> [Agent] {
        let fm = FileManager.default
        let manifest = pluginsDirectory.appending(path: "installed_plugins.json")
        guard let data = try? Data(contentsOf: manifest),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any]
        else { return [] }

        var agents: [String: Agent] = [:]
        for (key, value) in plugins {
            // Keys look like "ai-lawyer@ai-team".
            let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
            let plugin = parts[0]
            let marketplace = parts.count > 1 ? parts[1] : ""
            let installs = value as? [[String: Any]] ?? []

            for install in installs {
                var dir: URL
                if let path = install["installPath"] as? String {
                    dir = URL(fileURLWithPath: path)
                } else if let version = install["version"] as? String {
                    dir = pluginsDirectory.appending(path: "cache/\(marketplace)/\(plugin)/\(version)")
                } else { continue }
                dir = dir.appending(path: "agents")

                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                let mdFiles = files.filter { $0.pathExtension == "md" }
                for file in mdFiles {
                    guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                    let meta = parseFrontmatter(text)
                    let name = meta["name"] ?? file.deletingPathExtension().lastPathComponent
                    let id = "\(plugin):\(name)"
                    guard agents[id] == nil else { continue }
                    let title = mdFiles.count == 1 ? Agent.prettify(plugin) : Agent.prettify(name)
                    agents[id] = Agent(
                        id: id,
                        plugin: plugin,
                        marketplace: marketplace,
                        name: name,
                        title: title,
                        description: meta["description"] ?? "",
                        colorName: meta["color"]
                    )
                }
            }
        }

        return agents.values.sorted { a, b in
            let aPreferred = a.marketplace == preferredMarketplace
            let bPreferred = b.marketplace == preferredMarketplace
            if aPreferred != bPreferred { return aPreferred }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// Minimal YAML frontmatter reader: `key: value` lines plus `>` / `|` block scalars.
    static func parseFrontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var result: [String: String] = [:]
        var blockKey: String?
        var blockLines: [String] = []

        func flushBlock() {
            if let key = blockKey { result[key] = blockLines.joined(separator: " ") }
            blockKey = nil
            blockLines = []
        }

        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if blockKey != nil, line.hasPrefix(" ") || line.hasPrefix("\t") {
                blockLines.append(line.trimmingCharacters(in: .whitespaces))
                continue
            }
            flushBlock()
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value == ">" || value == "|" || value == ">-" || value == "|-" {
                blockKey = key
                continue
            }
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        flushBlock()
        return result
    }
}
