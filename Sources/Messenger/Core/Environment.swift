import Foundation

/// Finds the company's `ai-team/` workspace.
enum Workspace {
    /// Returns the folder that contains `ai-team/`, searching `folder` and its parents.
    static func aiTeamRoot(from folder: URL) -> URL? {
        let fm = FileManager.default
        var current = folder.standardizedFileURL
        while true {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: current.appending(path: "ai-team").path, isDirectory: &isDir), isDir.boolValue {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }
}

/// Finds the `claude` CLI.
enum ClaudeLocator {
    static func detect() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Apps started from Finder get a minimal PATH, so ask a login shell.
        return shellLookup("/usr/bin/which claude") ?? shellLookup("/bin/zsh -lc 'command -v claude'")
    }

    private static func shellLookup(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }
}
