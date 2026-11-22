import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Claude Code CLI") {
                HStack {
                    TextField("Path to claude", text: $settings.claudePath)
                    Button("Detect") {
                        if let path = ClaudeLocator.detect() { settings.claudePath = path }
                    }
                }
                Text(settings.claudeIsValid
                     ? "Uses your own Claude login and installed plugins. If replies say \"Not logged in\", run claude in Terminal and use /login."
                     : "No executable at this path.")
                    .font(.caption)
                    .foregroundStyle(settings.claudeIsValid ? Color.secondary : Color.red)
            }

            Section("Company folder") {
                HStack {
                    Text(settings.workspacePath.isEmpty ? "Not chosen" : settings.workspacePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(settings.workspacePath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { model.chooseWorkspace() }
                }
                Text("Agents run with this folder as their working directory. It should contain (or be inside a folder that contains) ai-team/. Existing conversations keep the folder they started in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                Picker("Permission mode", selection: $settings.permissionMode) {
                    ForEach(AppSettings.permissionModes, id: \.id) { mode in
                        Text(mode.label).tag(mode.id)
                    }
                }
                if let mode = AppSettings.permissionModes.first(where: { $0.id == settings.permissionMode }) {
                    Text(mode.help).font(.caption)
                }
                Text("Agents run headless (claude -p), so nobody can answer a permission prompt. Tools that need approval are denied unless the workspace's .claude/settings.json allows them or you choose a more permissive mode. Bypassing permissions is not offered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Messages") {
                Toggle("Show agent tool steps above replies", isOn: $settings.showToolSteps)
                Text("Off: replies show only the answer, with a short \"Working… (n steps)\" while the agent works. On: each step (\"🔧 Read …\") is listed above the reply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                HStack {
                    Text("Conversations are stored only on this Mac.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") {
                        let dir = model.store.directory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}
