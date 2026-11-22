import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let conversationID: UUID
    @State private var draft = ""
    @State private var composerHeight: CGFloat = 20

    var body: some View {
        if let conversation = model.store.conversation(conversationID) {
            VStack(spacing: 0) {
                header(conversation)
                Divider()
                messages(conversation)
                Divider()
                composer
            }
        }
    }

    private func header(_ conversation: Conversation) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title).font(.headline)
                HStack(spacing: 6) {
                    ForEach(conversation.participants, id: \.self) { id in
                        let agent = model.agent(id)
                        Label(agent.title, systemImage: "circle.fill")
                            .font(.caption)
                            .labelStyle(AgentChipStyle(color: agent.color))
                            .help(agent.description)
                    }
                }
            }
            Spacer()
            if let path = conversation.workspacePath {
                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(path)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func messages(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.messages.isEmpty {
                        Text(conversation.isGroup
                             ? "Each message goes to every agent in turn; later agents see earlier replies."
                             : "Say hello to \(model.agent(conversation.participants.first ?? "").title).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(conversation.messages) { message in
                        MessageBubble(message: message)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conversation.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conversation.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: conversation.messages.last?.activity.count) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var composer: some View {
        let running = model.isRunning(conversationID)
        return HStack(alignment: .bottom, spacing: 8) {
            ComposerTextView(text: $draft, height: $composerHeight, onSubmit: send)
                .frame(height: composerHeight)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Message  ·  Enter to send, Shift+Enter for a new line")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                            .allowsHitTesting(false)
                    }
                }
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            if running {
                Button(role: .cancel) { model.stop(conversationID) } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop the running reply (⌘.)")
            } else {
                Button(action: send) {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func send() {
        guard !model.isRunning(conversationID) else { return }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = draft
        draft = ""
        model.send(text, in: conversationID)
    }
}

struct MessageBubble: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            }
        case .notice:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .agent:
            agentBubble
        }
    }

    private var agentBubble: some View {
        let agent = model.agent(message.agentID ?? "")
        return HStack(alignment: .top, spacing: 8) {
            AgentAvatar(agent: agent)
            VStack(alignment: .leading, spacing: 6) {
                Text(agent.title).font(.caption.bold()).foregroundStyle(agent.color)

                if !message.activity.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(message.activity.enumerated()), id: \.offset) { _, line in
                            Text(line).lineLimit(1)
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }

                if !message.text.isEmpty {
                    Text(markdown(message.text))
                        .textSelection(.enabled)
                }

                if message.isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(message.text.isEmpty ? "Thinking…" : "Writing…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if message.wasStopped {
                    Text("Stopped").font(.caption).foregroundStyle(.secondary)
                }
                if let error = message.error, !error.isEmpty {
                    Text(error)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(agent.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 40)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct AgentChipStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(color).imageScale(.small)
            configuration.title
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }
}
