import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let conversationID: UUID
    @State private var draft = ""
    @State private var composerHeight: CGFloat = 20
    @State private var pendingFiles: [URL] = []
    @State private var dropTargeted = false

    var body: some View {
        if let conversation = model.store.conversation(conversationID) {
            VStack(spacing: 0) {
                header(conversation)
                Divider()
                messages(conversation)
                if let phase = model.phase[conversationID] {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(phase).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                Divider()
                composer(isGroup: conversation.isGroup)
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .overlay(Text("Drop files to attach").font(.headline).foregroundStyle(Color.accentColor))
                        .padding(8)
                        .allowsHitTesting(false)
                }
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
                             ? "Members answer only when your message concerns them. Write @name to ask one member directly; they can @mention each other too."
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
            .onChange(of: conversation.messages.last?.status) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingFiles.isEmpty
    }

    private func composer(isGroup: Bool) -> some View {
        let running = model.isRunning(conversationID)
        return VStack(alignment: .leading, spacing: 8) {
            if !pendingFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pendingFiles, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "doc")
                                Text(url.lastPathComponent).lineLimit(1)
                                Button {
                                    pendingFiles.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .help("Remove")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: chooseFiles) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .help("Attach files (or drop them on the chat)")
                .padding(.bottom, 8)

                ComposerTextView(text: $draft, height: $composerHeight, onSubmit: send)
                    .frame(height: composerHeight)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(isGroup ? "Message  ·  @name to ask one member  ·  Shift+Enter for a new line"
                                         : "Message  ·  Enter to send, Shift+Enter for a new line")
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
                    .disabled(!canSend)
                }
            }
        }
        .padding(12)
    }

    private func send() {
        guard !model.isRunning(conversationID), canSend else { return }
        let text = draft
        let files = pendingFiles
        draft = ""
        pendingFiles = []
        model.send(text, files: files, in: conversationID)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Choose files to attach. They are copied into the messenger; the originals stay where they are."
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    private func addFiles(_ urls: [URL]) {
        for url in urls where !pendingFiles.contains(url) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                pendingFiles.append(url)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in addFiles([url]) }
            }
        }
        return accepted
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
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.text.isEmpty {
                        Text(message.text)
                            .textSelection(.enabled)
                            .padding(10)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(message.attachments ?? []) { file in
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                        } label: {
                            Label(file.name, systemImage: "doc.fill")
                                .font(.callout)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Open \(file.name)")
                    }
                }
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

    /// Live status while a reply streams: the real step ("Reading notes.md"), or typing.
    private var statusLine: String {
        if let status = message.status { return status }
        return message.text.isEmpty ? "Thinking…" : "typing"
    }

    /// While an agent may be about to say PASS, don't flash the word.
    private var visibleText: String {
        guard message.isStreaming else { return message.text }
        let t = message.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return (!t.isEmpty && t.count <= 4 && "PASS".hasPrefix(t)) ? "" : message.text
    }

    private var agentBubble: some View {
        let agent = model.agent(message.agentID ?? "")
        return HStack(alignment: .top, spacing: 8) {
            AgentAvatar(agent: agent)
            VStack(alignment: .leading, spacing: 6) {
                Text(agent.title).font(.caption.bold()).foregroundStyle(agent.color)

                if model.settings.showToolSteps && !message.activity.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(message.activity.enumerated()), id: \.offset) { _, line in
                            Text(line).lineLimit(1)
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }

                if !visibleText.isEmpty {
                    Text(markdown(visibleText))
                        .textSelection(.enabled)
                }

                if message.isStreaming {
                    if statusLine == "typing" {
                        TypingIndicator()
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(statusLine)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
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

/// "typing" with three pulsing dots.
struct TypingIndicator: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 3) {
                Text("typing").font(.caption).foregroundStyle(.secondary)
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .frame(width: 4, height: 4)
                        .foregroundStyle(.secondary)
                        .opacity(i == step ? 1 : 0.3)
                }
            }
        }
    }
}
