import Foundation

/// One headless `claude -p` invocation.
struct RunRequest: Sendable {
    var claudePath: String
    var prompt: String
    var agent: String?
    var resumeSessionID: String?
    var workingDirectory: URL
    var permissionMode: String = "default"
    /// Extra instructions added to the system prompt (group-chat rules).
    var appendSystemPrompt: String?
    /// Model override (the speaker router uses a small, fast model).
    var model: String?
    /// Built-in tools to allow; `""` disables all tools. nil = Claude Code's default set.
    var tools: String?
    /// false = don't save this run as a session (one-off calls such as the router).
    var persistSession = true

    var arguments: [String] {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--verbose",                       // required for stream-json with -p
            "--include-partial-messages",      // token-level text deltas
            "--permission-mode", permissionMode,
            "--permission-prompts", "none",    // nobody can answer prompts headless: deny, never hang
        ]
        if let agent { args += ["--agent", agent] }
        if let resumeSessionID { args += ["--resume", resumeSessionID] }
        if let appendSystemPrompt, !appendSystemPrompt.isEmpty { args += ["--append-system-prompt", appendSystemPrompt] }
        if let model { args += ["--model", model] }
        if let tools { args += ["--tools", tools] }
        if !persistSession { args.append("--no-session-persistence") }
        args += ["--", prompt]                 // `--` so a message starting with "-" is not an option
        return args
    }
}

/// Runs the `claude` CLI and streams parsed events. Cancelling the consuming task stops the process.
enum ClaudeRunner {
    static func run(_ request: RunRequest) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: request.claudePath)
            process.arguments = request.arguments
            process.currentDirectoryURL = request.workingDirectory
            process.environment = childEnvironment(claudePath: request.claudePath)
            process.standardInput = FileHandle.nullDevice

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let box = ProcessBox(process)
            let stderrBuffer = DataBuffer()
            let stderrHandle = stderr.fileHandleForReading
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty { stderrBuffer.append(data) }
            }

            do {
                try process.run()
            } catch {
                stderrHandle.readabilityHandler = nil
                continuation.finish(throwing: RunnerError.launchFailed(request.claudePath, error.localizedDescription))
                return
            }

            let stdoutHandle = stdout.fileHandleForReading
            let reader = Task {
                var parser = StreamParser()
                do {
                    for try await line in stdoutHandle.bytes.lines {
                        for event in parser.parse(line: line) { continuation.yield(event) }
                    }
                } catch {
                    // Pipe closed early; the exit code and stderr below explain why.
                }
                let code = await box.waitForExit()
                stderrHandle.readabilityHandler = nil
                stderrBuffer.append(stderrHandle.readDataToEndOfFile())
                continuation.yield(.exited(code: code, stderr: stderrBuffer.string))
                continuation.finish()
            }

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    box.terminate()
                    reader.cancel()
                }
            }
        }
    }

    /// The app's environment, cleaned of variables a parent Claude Code session may have set
    /// (they would make the child CLI run in a host-managed mode), with common tool paths on PATH.
    static func childEnvironment(claudePath: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let launchedFromClaudeCode = env["CLAUDECODE"] != nil
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK_") {
            env.removeValue(forKey: key)
        }
        if launchedFromClaudeCode { env.removeValue(forKey: "ANTHROPIC_BASE_URL") }

        let claudeDir = URL(fileURLWithPath: claudePath).deletingLastPathComponent().path
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in [claudeDir, "/opt/homebrew/bin", "/usr/local/bin"] where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }
}

enum RunnerError: LocalizedError {
    case launchFailed(String, String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(path, reason):
            "Could not start claude at \(path): \(reason). Check the path in Settings."
        }
    }
}

/// Wraps a `Process` so it can be terminated and awaited from any thread.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(_ process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] p in self?.didExit(p.terminationStatus) }
    }

    private func didExit(_ code: Int32) {
        lock.lock()
        exitCode = code
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(returning: code) }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let code = exitCode {
                lock.unlock()
                continuation.resume(returning: code)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// SIGTERM, then SIGKILL if the CLI has not exited after 3 seconds.
    func terminate() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.process.isRunning == true { kill(pid, SIGKILL) }
        }
    }
}

private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
