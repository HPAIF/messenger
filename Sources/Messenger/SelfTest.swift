import Foundation

/// `swift run Messenger --selftest`: checks agent discovery, the stream-json parser on canned
/// output, and makes one tiny real `claude -p` call in a temporary folder.
enum SelfTest {
    static func runBlocking() -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached {
            box.value = await run()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private final class ResultBox: @unchecked Sendable { var value: Int32 = 1 }

    static func run() async -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ label: String) {
            print(ok ? "  PASS  \(label)" : "  FAIL  \(label)")
            if !ok { failures += 1 }
        }

        print("HPAIF Messenger self-test")

        // 1. Agent discovery
        print("\n[1] Agent discovery")
        let agents = AgentCatalog.discover()
        for agent in agents {
            print("  - \(agent.id)  \"\(agent.title)\"  [\(agent.marketplace)]  \(agent.description.prefix(60))…")
        }
        check(!agents.isEmpty, "found \(agents.count) agent(s) in installed plugins")

        // 2. Parser on canned stream-json (partial deltas + full message + tool + result)
        print("\n[2] Stream-json parser (canned events)")
        let canned = [
            #"{"type":"system","subtype":"init","session_id":"11111111-2222-3333-4444-555555555555"}"#,
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1"}},"session_id":"11111111-2222-3333-4444-555555555555"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"po"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ng"}}}"#,
            #"{"type":"assistant","message":{"id":"msg_1","content":[{"type":"text","text":"pong"}]}}"#,
            #"{"type":"assistant","message":{"id":"msg_2","content":[{"type":"tool_use","name":"Read","input":{"file_path":"ai-team/team.md"}}]}}"#,
            #"{"type":"assistant","message":{"id":"msg_3","content":[{"type":"text","text":"done"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"11111111-2222-3333-4444-555555555555"}"#,
        ]
        var parser = StreamParser()
        let events = canned.flatMap { parser.parse(line: $0) }
        let text = events.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
        let tools = events.compactMap { if case .tool(let t) = $0 { t } else { nil } }
        check(text == "pong\n\ndone", "text streamed once, separated per message (got \(text.debugDescription))")
        check(tools == ["🔧 Read ai-team/team.md"], "tool summary (got \(tools))")
        check(parser.sessionID == "11111111-2222-3333-4444-555555555555", "session id captured")
        check(events.contains(.result(text: "done", isError: false)), "result event")

        // 3. One tiny real call, no agent, in a temporary folder
        print("\n[3] Real call: claude -p \"Reply with exactly: pong\" (no agent, temp folder)")
        guard let claude = ClaudeLocator.detect() else {
            check(false, "claude CLI found")
            return finish(failures)
        }
        print("  claude: \(claude)")
        let temp = FileManager.default.temporaryDirectory
            .appending(path: "hpaif-messenger-selftest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let request = RunRequest(claudePath: claude, prompt: "Reply with exactly: pong", workingDirectory: temp)
        var reply = ""
        var sessionID: String?
        var resultError: String?
        var exitCode: Int32 = -1
        var stderr = ""
        do {
            for try await event in ClaudeRunner.run(request) {
                switch event {
                case .session(let id): sessionID = id
                case .text(let t): reply += t
                case .tool: break
                case let .result(text, isError): if isError { resultError = text }
                case let .exited(code, err): exitCode = code; stderr = err
                }
            }
        } catch {
            resultError = error.localizedDescription
        }
        print("  reply: \(reply.debugDescription)")
        print("  session id: \(sessionID ?? "nil"), exit code: \(exitCode)")
        if let resultError { print("  result error: \(resultError)") }
        if !stderr.isEmpty { print("  stderr: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        check(sessionID != nil, "session id extracted")
        check(reply.lowercased().contains("pong") && resultError == nil, "reply contains \"pong\"")
        if resultError?.localizedCaseInsensitiveContains("not logged in") == true {
            print("  hint: the claude CLI is not logged in. Run `claude` in Terminal and use /login, then retry.")
        }
        return finish(failures)
    }

    private static func finish(_ failures: Int) -> Int32 {
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }
}
