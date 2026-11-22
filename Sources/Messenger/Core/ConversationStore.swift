import Foundation
import Observation

/// Keeps conversations in memory and saves each one as JSON in
/// `~/Library/Application Support/HPAIF Messenger/conversations/<id>.json`.
@MainActor
@Observable
final class ConversationStore {
    private(set) var conversations: [Conversation] = []
    let directory: URL

    nonisolated static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "HPAIF Messenger", directoryHint: .isDirectory)
            .appending(path: "conversations", directoryHint: .isDirectory)
    }

    /// Copies of attached files: `.../HPAIF Messenger/attachments/<conversation id>/`.
    nonisolated static var attachmentsRoot: URL {
        defaultDirectory.deletingLastPathComponent()
            .appending(path: "attachments", directoryHint: .isDirectory)
    }

    init(directory: URL = ConversationStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    var sorted: [Conversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    func add(_ conversation: Conversation) {
        conversations.append(conversation)
        save(conversation)
    }

    /// Changes a conversation in place. Pass `persist: false` for high-frequency updates
    /// (streamed text) and save once the reply is complete.
    func update(_ id: UUID, persist: Bool = true, _ change: (inout Conversation) -> Void) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
        if persist {
            conversations[index].updatedAt = Date()
            save(conversations[index])
        }
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: fileURL(for: id))
        try? FileManager.default.removeItem(at: Self.attachmentsRoot.appending(path: id.uuidString))
    }

    /// Copies files into this conversation's attachments folder (never moves the originals).
    /// A name that already exists gets a number: `invoice 2.pdf`.
    func importAttachments(_ urls: [URL], to conversationID: UUID) -> (attachments: [Attachment], failed: [String]) {
        let fm = FileManager.default
        let folder = Self.attachmentsRoot.appending(path: conversationID.uuidString, directoryHint: .isDirectory)
        var attachments: [Attachment] = []
        var failed: [String] = []
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return ([], urls.map(\.lastPathComponent))
        }
        for url in urls {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var target = folder.appending(path: url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            do {
                try fm.copyItem(at: url, to: target)
                let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value
                attachments.append(Attachment(name: target.lastPathComponent, path: target.path, size: size))
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        return (attachments, failed)
    }

    // MARK: - Files

    private func fileURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    private func load() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        conversations = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Conversation.self, from: Data(contentsOf: $0)) }
            .map(Self.closeInterruptedReplies)
    }

    private func save(_ conversation: Conversation) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(conversation).write(to: fileURL(for: conversation.id), options: .atomic)
        } catch {
            NSLog("HPAIF Messenger: could not save conversation: \(error)")
        }
    }

    /// A reply that was streaming when the app quit can never finish.
    private static func closeInterruptedReplies(_ conversation: Conversation) -> Conversation {
        var copy = conversation
        for index in copy.messages.indices where copy.messages[index].isStreaming {
            copy.messages[index].isStreaming = false
            copy.messages[index].wasStopped = true
        }
        return copy
    }
}
