import AppKit
import Foundation
import Observation

enum SidebarSelection: Hashable {
    case agent(String)
    case conversation(UUID)
}

/// App state plus the chat logic: one-to-one replies and sequential group rounds.
@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let store = ConversationStore()
    private(set) var agents: [Agent] = []
    var selection: SidebarSelection?
    var showingNewGroup = false
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        reloadAgents()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    // MARK: - Agents & conversations

    func reloadAgents() {
        agents = AgentCatalog.discover()
    }

    func agent(_ id: String) -> Agent {
        agents.first { $0.id == id } ?? .placeholder(id: id)
    }

    func isRunning(_ conversationID: UUID) -> Bool {
        runningTasks[conversationID] != nil
    }

    /// Opens the most recent one-to-one chat with an agent, or starts one.
    func openDirectChat(with agentID: String) {
        if let existing = store.sorted.first(where: { $0.participants == [agentID] }) {
            selection = .conversation(existing.id)
            return
        }
        let conversation = Conversation(
            title: agent(agentID).title,
            participants: [agentID],
            workspacePath: settings.workspacePath.isEmpty ? nil : settings.workspacePath
        )
        store.add(conversation)
        selection = .conversation(conversation.id)
    }

    func createGroup(agentIDs: [String], title: String) {
        let name = title.trimmingCharacters(in: .whitespaces)
        let conversation = Conversation(
            title: name.isEmpty ? agentIDs.map { agent($0).name.capitalized }.joined(separator: ", ") : name,
            participants: agentIDs,
            workspacePath: settings.workspacePath.isEmpty ? nil : settings.workspacePath
        )
        store.add(conversation)
        selection = .conversation(conversation.id)
    }

    func deleteConversation(_ id: UUID) {
        stop(id)
        store.delete(id)
        if selection == .conversation(id) { selection = nil }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose your company folder (the one that contains ai-team/)."
        if panel.runModal() == .OK, let url = panel.url {
            settings.workspacePath = url.path
        }
    }

    // MARK: - Sending

    func send(_ rawText: String, in conversationID: UUID) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning(conversationID),
              var conversation = store.conversation(conversationID) else { return }

        store.update(conversationID) { $0.messages.append(.user(text)) }

        if conversation.workspacePath == nil, !settings.workspacePath.isEmpty {
            conversation.workspacePath = settings.workspacePath
            store.update(conversationID) { $0.workspacePath = self.settings.workspacePath }
        }
        guard let workspace = conversation.workspacePath else {
            store.update(conversationID) { $0.messages.append(.notice("Choose your company folder first (Settings or the banner above).")) }
            return
        }
        guard settings.claudeIsValid else {
            store.update(conversationID) { $0.messages.append(.notice("The claude CLI was not found. Set its path in Settings.")) }
            return
        }

        runningTasks[conversationID] = Task {
            await runRound(conversationID: conversationID, userText: text, workspace: URL(fileURLWithPath: workspace))
            runningTasks[conversationID] = nil
        }
    }

    func stop(_ conversationID: UUID) {
        runningTasks[conversationID]?.cancel()
    }

    func stopAll() {
        runningTasks.values.forEach { $0.cancel() }
    }

    /// Sends the message to each participant in turn. In a group, each agent also sees
    /// the other agents' replies since its own last turn.
    private func runRound(conversationID: UUID, userText: String, workspace: URL) async {
        guard let participants = store.conversation(conversationID)?.participants else { return }

        for agentID in participants {
            guard !Task.isCancelled, let conversation = store.conversation(conversationID) else { return }

            let prompt = conversation.isGroup
                ? groupPrompt(userText: userText, for: agentID, in: conversation)
                : userText
            let reply = Message(kind: .agent, agentID: agentID, isStreaming: true)
            store.update(conversationID) { $0.messages.append(reply) }

            let request = RunRequest(
                claudePath: settings.claudePath,
                prompt: prompt,
                agent: agentID,
                resumeSessionID: conversation.sessionIDs[agentID],
                workingDirectory: workspace,
                permissionMode: settings.permissionMode
            )
            await run(request, conversationID: conversationID, messageID: reply.id, agentID: agentID)
        }
    }

    private func run(_ request: RunRequest, conversationID: UUID, messageID: UUID, agentID: String) async {
        func edit(persist: Bool = false, _ change: @escaping (inout Message) -> Void) {
            store.update(conversationID, persist: persist) { conversation in
                if let i = conversation.messages.firstIndex(where: { $0.id == messageID }) {
                    change(&conversation.messages[i])
                }
            }
        }

        var resultError: String?
        var exitCode: Int32 = 0
        var stderr = ""
        do {
            for try await event in ClaudeRunner.run(request) {
                switch event {
                case .session(let id):
                    store.update(conversationID) { $0.sessionIDs[agentID] = id }
                case .text(let chunk):
                    edit { $0.text += chunk }
                case .tool(let summary):
                    edit { $0.activity.append(summary) }
                case let .result(text, isError):
                    if isError { resultError = text ?? "The agent reported an error." }
                case let .exited(code, output):
                    exitCode = code
                    stderr = output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch {
            resultError = error.localizedDescription
        }

        if Task.isCancelled {
            edit(persist: true) { $0.isStreaming = false; $0.wasStopped = true }
            return
        }

        var errorLines = [resultError].compactMap { $0 }
        if exitCode != 0 {
            if !stderr.isEmpty {
                errorLines.append(stderr)
            } else if resultError == nil {
                errorLines.append("claude exited with code \(exitCode).")
            }
            // An unknown session (e.g. deleted transcripts) would fail forever; start fresh next time.
            if request.resumeSessionID != nil, stderr.localizedCaseInsensitiveContains("no conversation found") {
                store.update(conversationID) { $0.sessionIDs[agentID] = nil }
                errorLines.append("The saved session was not found; your next message starts a new session.")
            }
        }
        let errorText = errorLines.isEmpty ? nil : errorLines.joined(separator: "\n")
        let duplicatedText = resultError
        edit(persist: true) { message in
            message.isStreaming = false
            message.error = errorText
            // Errors like "Not logged in" arrive as assistant text too; show them once.
            if let duplicatedText, message.text == duplicatedText { message.text = "" }
        }
    }

    private func groupPrompt(userText: String, for agentID: String, in conversation: Conversation) -> String {
        let me = agent(agentID)
        let others = conversation.participants.filter { $0 != agentID }.map { agent($0) }

        // Replies by other agents since this agent last spoke (or ever, on its first turn).
        let lastOwnIndex = conversation.messages.lastIndex { $0.kind == .agent && $0.agentID == agentID }
        let start = lastOwnIndex.map { conversation.messages.index(after: $0) } ?? conversation.messages.startIndex
        let earlier = conversation.messages[start...].filter {
            $0.kind == .agent && $0.agentID != agentID && !$0.text.isEmpty
        }

        var prompt = """
        [Group chat in HPAIF Messenger. You are \(me.name) (\(me.id)). \
        Also in this chat: the founder and \(others.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")). \
        Agents reply one after another.]

        Founder's message:
        \(userText)
        """
        if !earlier.isEmpty {
            prompt += "\n\nReplies from your colleagues since your last turn:\n"
            for message in earlier {
                prompt += "\n[\(agent(message.agentID ?? "").name)]: \(message.text)\n"
            }
            prompt += "\nBuild on these replies where useful; don't repeat what was already said."
        }
        return prompt
    }
}
