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
    /// Short line shown in a group chat while the app decides who speaks.
    var phase: [UUID: String] = [:]
    /// Most agent replies to one founder message (agents can @mention each other).
    static let maxAgentTurnsPerMessage = 4
    /// Where Claude Code keeps installed plugins (each agent's RULES.md, skills, templates).
    static let pluginCacheDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude/plugins/cache").path

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

    func send(_ rawText: String, files: [URL] = [], in conversationID: UUID) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !files.isEmpty, !isRunning(conversationID),
              var conversation = store.conversation(conversationID) else { return }

        let imported = store.importAttachments(files, to: conversationID)
        let message = Message.user(text, attachments: imported.attachments)
        store.update(conversationID) { $0.messages.append(message) }
        if !imported.failed.isEmpty {
            store.update(conversationID) {
                $0.messages.append(.notice("Could not attach: \(imported.failed.joined(separator: ", "))"))
            }
        }
        guard !text.isEmpty || !imported.attachments.isEmpty else { return }
        let promptText = message.promptText

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
            await runRound(conversationID: conversationID, userText: promptText, workspace: URL(fileURLWithPath: workspace))
            runningTasks[conversationID] = nil
        }
    }

    func stop(_ conversationID: UUID) {
        runningTasks[conversationID]?.cancel()
    }

    func stopAll() {
        runningTasks.values.forEach { $0.cancel() }
    }

    /// One-to-one: the agent answers. Group: only the members the message concerns answer
    /// (explicit @mentions, else a quick router call); a member may PASS (hidden), and a member
    /// can @mention a colleague, who then gets a turn — at most `maxAgentTurnsPerMessage` turns.
    private func runRound(conversationID: UUID, userText: String, workspace: URL) async {
        guard let conversation = store.conversation(conversationID),
              let first = conversation.participants.first else { return }
        guard conversation.isGroup else {
            let reply = await runTurn(agentID: first, prompt: userText, systemPrompt: directRules(for: first),
                                      conversationID: conversationID, workspace: workspace)
            if let reply {
                let colleagues = agents.map(\.id).filter { $0 != first && agent($0).marketplace == agent(first).marketplace }
                let addressed = mentions(in: reply.text, of: colleagues, excluding: first)
                if !addressed.isEmpty {
                    var notice = Message.notice("\(agent(first).title) needs input from \(addressed.map { agent($0).title }.joined(separator: " and ")).")
                    notice.inviteAgentIDs = addressed
                    notice.invitedBy = first
                    store.update(conversationID) { $0.messages.append(notice) }
                }
            }
            return
        }

        var queue = await chooseSpeakers(for: userText, in: conversation)
        var askedBy: [String: String] = [:]   // agent id -> name of the colleague who @mentioned it
        // One hop only: members chosen for the founder's message may @mention a colleague, who
        // answers once in the chat; that answer does not start another round (no discussion
        // without the founder).
        var depth: [String: Int] = Dictionary(uniqueKeysWithValues: queue.map { ($0, 0) })
        var waiting: [String] = []
        var turns = 0
        while !queue.isEmpty, turns < Self.maxAgentTurnsPerMessage, !Task.isCancelled {
            let agentID = queue.removeFirst()
            guard let current = store.conversation(conversationID) else { return }
            turns += 1
            let reply = await runTurn(
                agentID: agentID,
                prompt: groupPrompt(for: agentID, in: current, askedBy: askedBy[agentID]),
                systemPrompt: groupRules(for: agentID, in: current),
                conversationID: conversationID,
                workspace: workspace
            )
            defer { markSeen(agentID, in: conversationID) }
            guard let reply, !Task.isCancelled else { continue }
            if Self.isPass(reply.text) {
                store.update(conversationID) { $0.messages.removeAll { $0.id == reply.id } }
                continue
            }
            askedBy[agentID] = nil
            let myDepth = depth[agentID] ?? 0
            for mentioned in mentions(in: reply.text, of: current.participants, excluding: agentID)
            where !queue.contains(mentioned) {
                if myDepth == 0 {
                    queue.append(mentioned)
                    depth[mentioned] = 1
                    askedBy[mentioned] = agent(agentID).name
                } else if !waiting.contains(mentioned) {
                    waiting.append(mentioned)
                }
            }
        }
        let pending = (queue + waiting).filter { !$0.isEmpty }
        if !pending.isEmpty, !Task.isCancelled {
            let names = pending.map { "@" + agent($0).name }.joined(separator: ", ")
            store.update(conversationID) {
                $0.messages.append(.notice("\(names) was asked something. Reply when you want them to answer."))
            }
        }
    }

    /// Adds colleagues an agent addressed in a one-to-one chat to that conversation (the founder
    /// clicked the button), then lets each answer once, visibly. The chat becomes a group chat.
    func invite(_ agentIDs: [String], fromNotice noticeID: UUID, in conversationID: UUID) {
        guard !isRunning(conversationID), let conversation = store.conversation(conversationID),
              let workspace = conversation.workspacePath else { return }
        let asker = conversation.messages.first { $0.id == noticeID }?.invitedBy
        let newcomers = agentIDs.filter { !conversation.participants.contains($0) }
        store.update(conversationID) { conv in
            let wasAutoTitle = conv.title == self.agent(conv.participants.first ?? "").title
            conv.participants += newcomers
            if wasAutoTitle { conv.title = conv.participants.map { self.agent($0).name.capitalized }.joined(separator: ", ") }
            if let i = conv.messages.firstIndex(where: { $0.id == noticeID }) {
                conv.messages[i].inviteAgentIDs = nil
                conv.messages[i].text += " Added to this chat."
            }
        }
        runningTasks[conversationID] = Task {
            for agentID in newcomers where !Task.isCancelled {
                guard let current = store.conversation(conversationID) else { break }
                let reply = await runTurn(
                    agentID: agentID,
                    prompt: groupPrompt(for: agentID, in: current, askedBy: asker.map { agent($0).name }),
                    systemPrompt: groupRules(for: agentID, in: current),
                    conversationID: conversationID,
                    workspace: URL(fileURLWithPath: workspace)
                )
                markSeen(agentID, in: conversationID)
                if let reply, Self.isPass(reply.text) {
                    store.update(conversationID) { $0.messages.removeAll { $0.id == reply.id } }
                }
            }
            runningTasks[conversationID] = nil
        }
    }

    /// Marks messages as seen by the founder (they were on screen while the app was active).
    func markRead(_ ids: Set<UUID>, in conversationID: UUID) {
        guard let conversation = store.conversation(conversationID),
              conversation.messages.contains(where: { ids.contains($0.id) && $0.isRead == false }) else { return }
        store.update(conversationID) { conv in
            for i in conv.messages.indices where ids.contains(conv.messages[i].id) && conv.messages[i].isRead == false {
                conv.messages[i].isRead = true
            }
        }
    }

    /// Runs one agent reply and returns its message id and final text (nil if it failed).
    private func runTurn(agentID: String, prompt: String, systemPrompt: String?,
                         conversationID: UUID, workspace: URL) async -> (id: UUID, text: String)? {
        guard let conversation = store.conversation(conversationID) else { return nil }
        var reply = Message(kind: .agent, agentID: agentID, isStreaming: true)
        reply.isRead = false
        store.update(conversationID) { $0.messages.append(reply) }
        try? FileManager.default.createDirectory(at: ConversationStore.attachmentsRoot, withIntermediateDirectories: true)
        let request = RunRequest(
            claudePath: settings.claudePath,
            prompt: prompt,
            agent: agentID,
            resumeSessionID: conversation.sessionIDs[agentID],
            workingDirectory: workspace,
            permissionMode: settings.permissionMode,
            appendSystemPrompt: systemPrompt,
            // Agents read their own rules from the plugin cache, outside the company folder.
            additionalDirectories: [Self.pluginCacheDirectory, ConversationStore.attachmentsRoot.path],
            // No hidden agent-to-agent calls: colleagues talk only in the chat the founder sees.
            disallowedTools: ["Agent", "Task"]
        )
        await run(request, conversationID: conversationID, messageID: reply.id, agentID: agentID)
        guard let message = store.conversation(conversationID)?.messages.first(where: { $0.id == reply.id }),
              message.error == nil, !message.wasStopped else { return nil }
        return (reply.id, message.text)
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
                    edit { $0.text += chunk; $0.status = "typing" }
                case .tool(let summary):
                    edit { $0.activity.append(summary) }
                case .status(let status):
                    edit { $0.status = status }
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
            edit(persist: true) { $0.isStreaming = false; $0.wasStopped = true; $0.status = nil }
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
            message.status = nil
            message.error = errorText
            // Errors like "Not logged in" arrive as assistant text too; show them once.
            if let duplicatedText, message.text == duplicatedText { message.text = "" }
        }
    }

    // MARK: - Group chat

    /// Rules every agent follows in a group chat (added to its system prompt).
    private func groupRules(for agentID: String, in conversation: Conversation) -> String {
        let me = agent(agentID)
        let others = conversation.participants.filter { $0 != agentID }
            .map { "\(agent($0).title) (@\(agent($0).name))" }.joined(separator: ", ")
        return """
        You are \(me.title) (@\(me.name)) in a group chat in HPAIF Messenger with the founder and your \
        AI Team colleagues: \(others). Everyone sees every message. Group-chat rules (they override your \
        default answer format here):
        1. Speak only when you add something new and important from your own area. If you have nothing \
        to add, reply with exactly: PASS
        2. Never repeat, summarise or agree with what a colleague already said. No openers such as \
        "Thanks", "Understood", "I agree", "Got it".
        3. Talk to colleagues only here, where the founder reads it, never through the founder and \
        never through hidden channels (no Agent tool or subagents to reach colleagues). Don't write \
        "ask the lawyer" or "check this with the accountant": write @name and your question; that \
        colleague answers once in this chat. Ask once, then leave the next step to the founder: no \
        back-and-forth discussion among yourselves.
        4. Ask the founder only questions from your own area: at most two, the most important first.
        5. Be brief: a few lines unless the content truly needs more. Keep warnings (UNVERIFIED, \
        escalation), numbers, dates and decisions the founder must make.
        6. If you asked the founder something earlier that is still unanswered and still matters, \
        repeat it briefly at the end under "Still open:". Only your own questions; drop them once \
        answered or no longer relevant. A missed question alone is reason enough to speak.
        7. Attached files are listed with their paths; read the ones relevant to your area.
        """
    }

    /// Instructions for a one-to-one chat: consult installed colleagues yourself, never send
    /// the founder to them.
    private func directRules(for agentID: String) -> String {
        let me = agent(agentID)
        let colleagues = agents.filter { $0.id != agentID && $0.marketplace == me.marketplace }
        let list = colleagues.isEmpty ? "none installed" : colleagues.map { "@\($0.name)" }.joined(separator: ", ")
        return """
        You are \(me.title) in a one-to-one chat with the founder in HPAIF Messenger. Colleagues the \
        founder can bring into this chat: \(list). Never contact colleagues through hidden channels \
        (no Agent tool or subagents): the founder must see every exchange. Never tell the founder to \
        ask or check with a colleague either. Answer your own part; if a colleague's input is needed, \
        end with one line per colleague: "For @name: <the exact question>". The founder can then add \
        them to this chat with one click. If you asked the founder something earlier that is still \
        unanswered and still matters, repeat it briefly at the end under "Still open:". Attached files \
        are listed with their paths; read them with the Read tool.
        """
    }

    /// Everything said since this agent's previous turn (founder and colleagues), so an agent
    /// that was skipped still has the full picture.
    private func groupPrompt(for agentID: String, in conversation: Conversation, askedBy: String?) -> String {
        let messages = conversation.messages
        var start = messages.startIndex
        if let seen = conversation.lastSeenMessageID?[agentID],
           let i = messages.firstIndex(where: { $0.id == seen }) {
            start = messages.index(after: i)
        } else if let lastOwn = messages.lastIndex(where: { $0.kind == .agent && $0.agentID == agentID }) {
            start = messages.index(after: lastOwn)
        } else {
            start = max(messages.startIndex, messages.endIndex - 20)
        }
        let lines = messages[start...].compactMap { message -> String? in
            guard !message.promptText.isEmpty, !message.isStreaming, message.agentID != agentID else { return nil }
            switch message.kind {
            case .user: return "[founder]: \(message.promptText)"
            case .agent: return "[@\(agent(message.agentID ?? "").name)]: \(message.text)"
            case .notice: return nil
            }
        }
        var prompt = "New in the group chat since your last turn:\n\n" + lines.joined(separator: "\n\n")
        if let askedBy {
            prompt += "\n\n@\(askedBy) addressed you (@\(agent(agentID).name)) above. Answer them directly."
        }
        prompt += "\n\nYour turn. Follow the group-chat rules (reply PASS if you have nothing new)."
        return prompt
    }

    /// Who answers a founder message: explicit @mentions, else a small fast model picks the
    /// members the message concerns. Falls back to everyone if that fails.
    private func chooseSpeakers(for userText: String, in conversation: Conversation) async -> [String] {
        let all = conversation.participants
        let mentioned = mentions(in: userText, of: all, excluding: nil)
        if !mentioned.isEmpty { return mentioned }

        phase[conversation.id] = "Choosing who should answer…"
        defer { phase[conversation.id] = nil }
        let roster = all.map { "- \(agent($0).name): \(agent($0).description.prefix(240))" }.joined(separator: "\n")
        let recent = conversation.messages.dropLast().suffix(6)
            .filter { $0.kind != .notice && !$0.text.isEmpty }
            .map { "[\($0.kind == .user ? "founder" : agent($0.agentID ?? "").name)]: \($0.text.prefix(500))" }
            .joined(separator: "\n")
        let prompt = """
        You route messages in a founder's group chat with AI team members. Pick only the members whose \
        area the founder's newest message clearly concerns: usually one, more only if it truly needs each. \
        Also pick a member whose question to the founder in the recent conversation is still unanswered, \
        and a member a colleague asked something (@name) that they have not answered yet.

        Members:
        \(roster)

        Recent conversation:
        \(recent.isEmpty ? "(none)" : recent)

        Founder's newest message:
        \(userText)

        Reply with only the member names, comma-separated, nothing else.
        """
        let request = RunRequest(
            claudePath: settings.claudePath, prompt: prompt, agent: nil, resumeSessionID: nil,
            workingDirectory: FileManager.default.temporaryDirectory, permissionMode: "default",
            model: "haiku", tools: "", persistSession: false
        )
        var text = ""
        do {
            for try await event in ClaudeRunner.run(request) {
                if case .text(let chunk) = event { text += chunk }
            }
        } catch {
            return all
        }
        let answer = text.lowercased()
        let picked = all.filter { answer.contains(agent($0).name.lowercased()) }
        return picked.isEmpty ? all : picked
    }

    /// Agent ids @mentioned in `text` (by short name, e.g. @lawyer, or plugin, e.g. @ai-lawyer), in order.
    private func mentions(in text: String, of participants: [String], excluding: String?) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "@([A-Za-z][A-Za-z0-9_-]*)") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var found: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let token = text[r].lowercased()
            if let id = participants.first(where: {
                agent($0).name.lowercased() == token || agent($0).plugin.lowercased() == token
            }), id != excluding, !found.contains(id) {
                found.append(id)
            }
        }
        return found
    }

    private func markSeen(_ agentID: String, in conversationID: UUID) {
        store.update(conversationID) { conversation in
            guard let last = conversation.messages.last?.id else { return }
            var seen = conversation.lastSeenMessageID ?? [:]
            seen[agentID] = last
            conversation.lastSeenMessageID = seen
        }
    }

    /// True when an agent chose to stay silent ("PASS", possibly with punctuation or markdown).
    nonisolated static func isPass(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_`.!\"'"))
            .uppercased()
        return cleaned == "PASS"
    }
}
