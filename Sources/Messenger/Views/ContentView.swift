import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                WorkspaceBanner()
                if case .conversation(let id) = model.selection, model.store.conversation(id) != nil {
                    ChatView(conversationID: id)
                        .id(id)
                } else {
                    ContentUnavailableView(
                        "HPAIF Messenger",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Pick an agent to chat one-to-one, or start a group chat.")
                    )
                }
            }
        }
        .sheet(isPresented: $model.showingNewGroup) {
            NewGroupSheet()
        }
        .onChange(of: model.selection) { _, selection in
            if case .agent(let agentID) = selection {
                model.openDirectChat(with: agentID)
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: Conversation?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Agents") {
                if model.agents.isEmpty {
                    Text("No agents found. Install AI Team plugins in Claude Code, then refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.agents) { agent in
                    AgentRow(agent: agent)
                        .tag(SidebarSelection.agent(agent.id))
                }
                Button {
                    model.showingNewGroup = true
                } label: {
                    Label("New group chat", systemImage: "person.3")
                }
                .buttonStyle(.borderless)
                .disabled(model.agents.count < 2)
            }

            Section("Conversations") {
                ForEach(model.store.sorted) { conversation in
                    ConversationRow(conversation: conversation)
                        .tag(SidebarSelection.conversation(conversation.id))
                        .contextMenu {
                            Button("Delete…", role: .destructive) { pendingDelete = conversation }
                        }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { model.reloadAgents() } label: {
                    Label("Refresh agents", systemImage: "arrow.clockwise")
                }
                .help("Re-read installed plugins")
            }
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete?.id { model.deleteConversation(id) }
            }
        } message: {
            Text("The conversation is removed from HPAIF Messenger. Claude Code's own session transcripts are kept.")
        }
    }
}

struct AgentRow: View {
    let agent: Agent

    var body: some View {
        HStack(spacing: 8) {
            AgentAvatar(agent: agent)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.title).fontWeight(.medium)
                Text(agent.id).font(.caption).foregroundStyle(.secondary)
            }
        }
        .help(agent.description)
    }
}

struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: conversation.isGroup ? "person.3.fill" : "person.fill")
                .foregroundStyle(conversation.isGroup ? Color.secondary : model.agent(conversation.participants.first ?? "").color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(conversation.title).lineLimit(1)
                    if model.isRunning(conversation.id) {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(conversation.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct AgentAvatar: View {
    let agent: Agent

    var body: some View {
        Text(String(agent.name.prefix(1)).uppercased())
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(agent.color, in: Circle())
    }
}

/// Warns when no company folder is chosen, it has no `ai-team/`, or `claude` is missing.
struct WorkspaceBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings
        if !settings.claudeIsValid {
            banner("The claude CLI was not found. Install Claude Code or set its path in Settings.", button: nil)
        } else if let url = settings.workspaceURL {
            if Workspace.aiTeamRoot(from: url) == nil {
                banner("No ai-team/ workspace in \(url.lastPathComponent) or its parent folders. The agents will offer to run their setup.",
                       button: "Change folder…")
            }
        } else {
            banner("Choose your company folder (the one with the ai-team/ workspace) so the agents can work in it.",
                   button: "Choose folder…")
        }
    }

    private func banner(_ text: String, button: String?) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            if let button {
                Button(button) { model.chooseWorkspace() }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}

extension Agent {
    var color: Color {
        switch colorName?.lowercased() {
        case "blue": .blue
        case "green": .green
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "purple": .purple
        case "pink": .pink
        case "cyan", "teal": .teal
        case "indigo": .indigo
        case "brown": .brown
        default:
            // Stable fallback (String.hashValue changes between launches).
            [Color.blue, .green, .purple, .orange, .pink, .teal, .indigo][Int(id.unicodeScalars.reduce(0) { ($0 &* 31 &+ $1.value) % 7 })]
        }
    }
}
