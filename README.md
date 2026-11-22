# HPAIF Messenger

A native macOS app for chatting with your **AI Team** agents (the Claude Code plugins from the
[`ai-team`](https://github.com/HPAIF/ai-team) marketplace, such as `ai-lawyer:lawyer` and
`ai-accountant:accountant`), one-to-one or in a group conversation, instead of using the Claude
desktop app.

> **This is an MVP (0.1.0).** It covers the basics: discovering agents, one-to-one and group
> chats, streaming replies, and local history. See the [roadmap](#roadmap) for what's next.

## Features

- **Agents sidebar:** every agent from your installed Claude Code plugins (AI Team agents first),
  with its title and description.
- **One-to-one chat:** replies stream in as they're written. Tool use shows as short lines
  (`🔧 Read ai-team/lawyer/journal.md`). Each agent keeps its context across messages, and you can
  stop a reply at any time (⌘.).
- **Group chat:** pick two or more agents. Members speak only when they have something to add:
  - write `@lawyer` (any member's short name) to ask specific members;
  - otherwise a quick, cheap check (a small model, no tools, not saved) picks the members your
    message concerns, falling back to everyone if it fails;
  - a member with nothing new replies `PASS`, which the app hides;
  - everything is visible: agents never call each other through hidden channels (the Agent tool is
    blocked for agent runs), and never ask you to relay ("ask the lawyer");
  - an agent that needs a colleague writes `@accountant …`; that colleague answers once in the chat
    (one hop: no discussion among agents without you; at most 4 agent replies per message);
  - in a one-to-one chat the agent ends with `For @lawyer: <question>`, and the app offers an
    "Add Lawyer to this chat" button: one click turns the chat into a group and the lawyer answers;
  - group rules (no repeating, no "I agree" openers, brief answers) are added to each agent's system
    prompt, and each agent sees everything said since its last turn, including your messages.
- **Agent rules:** each run can read the plugin cache (`--add-dir ~/.claude/plugins/cache`), so agents
  follow their own RULES.md even in headless mode.
- **Attachments:** click the paperclip or drop files on the chat. Files are copied into
  `~/Library/Application Support/HPAIF Messenger/attachments/<conversation>/` (originals untouched),
  shown as chips on your message (click to open), and passed to the agents as paths they can read.
  You can send files without text.
- **Missed questions:** if an agent asked you something you didn't answer and it still matters, it
  repeats it briefly under "Still open:" in its next reply; in a group, that member gets a turn.
- **Scrolling like a messenger:** the chat follows new text only while you are at the bottom;
  scroll up and it stays where you are. A "↓ n" button shows unread replies below and jumps to the
  first one. Opening a chat starts at the first unread reply.
- **Unread counts:** a badge per conversation in the sidebar; replies count as read once they are
  on screen while the app is active. Zero shows nothing.
- **Live status:** while an agent works you see what it is doing ("Reading obligations.md",
  "Searching the web", "Using legal-research"), then "typing…" while it writes. Raw tool steps are
  hidden by default (Settings → Messages).
- **Company folder:** agents run in the folder you choose. The app warns you if there's no
  `ai-team/` workspace in it or in any parent folder.
- **Local history:** conversations are saved on your Mac and listed in the sidebar.

## Requirements

- macOS 14 (Sonoma) or later
- [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI installed **and logged in**:
  run `claude` in Terminal once and use `/login`. The app looks for `claude` in
  `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, and on your shell's `PATH`.
- AI Team plugins installed in Claude Code, for example:
  ```
  /plugin marketplace add HPAIF/ai-team
  /plugin install ai-lawyer@ai-team
  ```
- To build from source: Swift 6 toolchain (Xcode 16 or later, or the matching Command Line Tools)

## Build and run

```bash
swift run                      # build and start the app
swift run Messenger --selftest # check agent discovery, the parser, and one tiny real claude call
scripts/build-app.sh           # build dist/HPAIF Messenger.app (release, ad-hoc signed)
```

On first launch, choose your company folder (the one that contains `ai-team/`) in the banner or
in **Settings** (⌘,).

The self-test makes **one** real call (`claude -p "Reply with exactly: pong"`, no agent, in a
temporary folder), which uses your Claude subscription or API credits.

## How it works

HPAIF Messenger doesn't talk to any API itself. It drives the `claude` CLI in headless mode, using
**your own Claude login and your installed plugins**:

```
claude -p --output-format stream-json --verbose --include-partial-messages \
       --permission-mode <mode> --permission-prompts none \
       --agent <plugin:agent> [--resume <session-id>] -- "<your message>"
```

- The working directory is the conversation's company folder, so agents find `ai-team/` just as
  they would in a terminal.
- The app parses the stream-json events. Text deltas fill the reply bubble, `tool_use` blocks
  become activity lines, and the `session_id` is saved.
- Your next message to that agent in the same conversation adds `--resume <session-id>`, so the
  agent keeps its context. In a group, each agent has its own session.
- Stopping a reply terminates the CLI process.
- If a run fails (for example, not logged in or agent not installed), the CLI's error output is
  shown in the chat.

Code layout (`Sources/Messenger`):

| Path | What it does |
| --- | --- |
| `Models/` | `Agent`, `Conversation`, `Message` |
| `Core/AgentCatalog.swift` | plugin discovery from `~/.claude/plugins/installed_plugins.json` and `agents/*.md` frontmatter |
| `Core/ClaudeRunner.swift` | process launch, environment, cancellation |
| `Core/StreamParser.swift` | stream-json → events |
| `Core/ConversationStore.swift` | JSON persistence |
| `Core/AppModel.swift` | app state, one-to-one and group chat flow |
| `Views/` | SwiftUI views |
| `SelfTest.swift` | `--selftest` mode |

## Privacy

Conversations are stored **only on your Mac**, as JSON files in
`~/Library/Application Support/HPAIF Messenger/conversations/`. The app has no server, analytics,
or telemetry. Your messages go only to Claude through your own Claude Code CLI, under your own
account, exactly as if you typed them in a terminal. Claude Code also keeps its own session
transcripts in `~/.claude/projects/`, as usual.

## Permissions

Agents run headless (`claude -p`), so nobody is there to answer a permission prompt. The app passes
`--permission-prompts none`: **any tool call that would need your approval is denied**, unless:

- it's allowed by the workspace's `.claude/settings.json` (or your user settings). The AI Team
  plugins' `setup` skills offer to add sensible rules there, or
- you choose a more permissive mode in **Settings → Permissions**:

| Mode | Effect |
| --- | --- |
| `default` (the default) | Only pre-approved tools run; others are denied |
| `acceptEdits` | File edits are allowed too |
| `plan` | Read and plan only, no changes |
| `dontAsk` | Only pre-approved tools run; everything else is denied without asking |
| `auto` | Claude Code's classifier approves or denies each call |

`bypassPermissions` is deliberately **not** offered.

## Roadmap

- Agents talking to each other directly (agent-to-agent turns, not only founder-led rounds)
- Streaming tool approvals: approve or deny a tool call from the chat while the agent waits
- Notifications when a long reply finishes
- Attachments (drop contracts, invoices, and statements into a chat)
- An Agent SDK backend instead of driving the CLI
- A dashboard of the team's deadlines, obligations, and recent work from `ai-team/`

## License

[MIT](LICENSE)
