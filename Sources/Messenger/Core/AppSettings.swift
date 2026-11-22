import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    /// Modes offered in the UI. `bypassPermissions` is deliberately not offered.
    static let permissionModes: [(id: String, label: String, help: String)] = [
        ("default", "Default (recommended)",
         "Tools that need approval are denied, unless allowed in the workspace's .claude/settings.json."),
        ("acceptEdits", "Accept edits",
         "File edits in the workspace are allowed automatically. Other tools that need approval are denied."),
        ("plan", "Plan only",
         "Agents can read and plan but not change anything."),
        ("dontAsk", "Don't ask",
         "Only tools pre-approved in settings run; everything else is denied without asking."),
        ("auto", "Auto",
         "Claude Code's classifier approves or denies each tool call."),
    ]

    /// The .app bundle (id org.hpaif.messenger) uses its standard defaults; `swift run` has no
    /// bundle id, so it opens the same domain by name. Both share one settings file.
    private let defaults = Bundle.main.bundleIdentifier != nil
        ? UserDefaults.standard
        : UserDefaults(suiteName: "org.hpaif.messenger") ?? .standard

    var claudePath: String {
        didSet { defaults.set(claudePath, forKey: "claudePath") }
    }
    var workspacePath: String {
        didSet { defaults.set(workspacePath, forKey: "workspacePath") }
    }
    var permissionMode: String {
        didSet { defaults.set(permissionMode, forKey: "permissionMode") }
    }
    /// Show the agent's tool steps ("🔧 Read …") above its reply. Off by default.
    var showToolSteps: Bool {
        didSet { defaults.set(showToolSteps, forKey: "showToolSteps") }
    }

    init() {
        showToolSteps = defaults.bool(forKey: "showToolSteps")
        claudePath = defaults.string(forKey: "claudePath") ?? ""
        workspacePath = defaults.string(forKey: "workspacePath") ?? ""
        let mode = defaults.string(forKey: "permissionMode") ?? "default"
        permissionMode = Self.permissionModes.contains { $0.id == mode } ? mode : "default"
        if claudePath.isEmpty || !FileManager.default.isExecutableFile(atPath: claudePath) {
            claudePath = ClaudeLocator.detect() ?? claudePath
        }
    }

    var claudeIsValid: Bool { FileManager.default.isExecutableFile(atPath: claudePath) }

    var workspaceURL: URL? {
        workspacePath.isEmpty ? nil : URL(fileURLWithPath: workspacePath, isDirectory: true)
    }
}
