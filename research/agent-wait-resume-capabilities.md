# Agent wait, background-job, and resume capabilities

> Research note, 2026-09-22 UTC, for
> [issue #46](https://github.com/ejarmand/skills/issues/46) ("Timed
> awaken/command based resume"). Question: what native wait, background-job,
> resume and scheduled-wakeup features do Claude Code, Codex, Cursor Agent and
> OpenCode have, and where would a tool that sends a message into an agent's
> current session on an outside trigger ("job exited 2, address any errors",
> "in 3 hours, look at new PRs") still add something?
>
> Versions: Claude Code 2.1.280 (docs at code.claude.com and the CHANGELOG,
> both fetched 2026-09-22, plus `claude --help` and the installed binary),
> codex-cli 0.156.0 (source at tag `rust-v0.156.0`), cursor-agent
> 2026.09.15-d2fe57e (installed bundle, docs and changelog), OpenCode v1.18.27
> (source at tag). The Codex, Cursor and OpenCode sections condense
> `raw/codex-report.md`, `raw/codex-unified-exec-report.md`,
> `raw/cursor-report.md` and `raw/opencode-report.md`, which carry the full
> citations. No agent sessions were started for this
> note; everything is from docs, source or bundle reads unless marked
> otherwise.

## Summary

The impression that native tools are basic and mostly timer-based holds for
Codex, half-holds for Cursor and OpenCode, and is wrong for Claude Code.

1. **Claude Code already does most of what issue #46 asks, inside a live
   process.** Background Bash, Monitor and `asyncRewake` hooks wake the model
   when a job exits or prints something. `CronCreate` and `/loop` give
   session-scoped timers (1 min to 7 days). Each session binds an inbox socket
   (`CLAUDE_CODE_MESSAGING_SOCKET`) that a script can post to; a message
   starts a turn when the session is idle and lands between tool calls when
   it is busy. Channels do the same for MCP servers.
2. **Codex has the reverse profile.** Its wait tools are in-turn only:
   `clock.sleep` blocks the current turn and background shells must be
   polled; a process exit never wakes the model. But `codex queue --thread
   <id> --message <text>` is a native, durable, cross-process injection path
   that starts a turn when the thread is idle and loaded somewhere.
3. **Cursor wakes itself on background-shell exit or a regex match on its
   output**, which the impression misses. It has no timer tool, the wake queue
   is in memory, and there is no supported way for an outside process to
   message a running local chat. Its scheduling and event triggers are
   cloud-only.
4. **OpenCode has no timer and no background shell**, but background
   subagents wake the parent, and the HTTP API (`prompt_async`) plus plugins
   are the strongest injection primitives of the four. The catch: the default
   TUI opens no port, so an outside caller needs `--port` or a plugin.
5. **What no CLI provides:** triggers that outlive the agent process and
   then resume the right session, a timer that fires into a session that
   isn't loaded, and one addressing scheme across CLIs. That is the gap a
   resume tool fills.

## 1. Claude Code

Claude Code has the most native coverage of the four. It has event-driven
wake-ups for background work, in-session timers, and a documented way for an
outside script to post a message into a live session.

### Background jobs and completion notification

- **Background Bash.** The Bash tool takes `run_in_background: true`, returns
  a task ID and an output file path, and keeps the command running across
  turns. A foreground command that hits its timeout (120 s default, 10 min
  ceiling) is moved to the background instead of killed, unless it starts
  with `sleep`
  ([tools reference, background commands](https://code.claude.com/docs/en/tools-reference#background-commands)).
- **Completion is push.** The 2.1.280 Bash tool description says the command
  "keeps running across turns and re-invokes you when it exits". The
  changelog refers to "background tasks that already notify on completion"
  (2.1.140) and to headless/SDK sessions "making a separate model call for
  every background task that finished", fixed in 2.1.274 so queued
  completions are answered by one call
  ([CHANGELOG](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md)).
- **Monitor.** Runs a script, or opens a WebSocket, and feeds each output line
  to Claude as an event mid-conversation, without polling. Every watch has a
  deadline: 5 min default, 30 min max, 10 min in `-p`. At the deadline Claude
  gets one notice so it can re-arm
  ([Monitor tool](https://code.claude.com/docs/en/tools-reference#monitor-tool)).
  Since 2.1.274 a script's final output and its exit arrive as one
  notification. The no-timeout `persistent` option was removed in 2.1.271.
  Plugins can declare monitors that start automatically.
- **Async hooks with rewake.** A command hook with `asyncRewake: true` runs in
  the background and "wakes Claude on exit code 2"; its stderr is shown to
  Claude as a system reminder. Plain `async: true` hooks deliver their output
  on the next turn and don't wake anything
  ([hooks reference](https://code.claude.com/docs/en/hooks#configure-an-async-hook)).
- **Idle notice from another session.** `SendMessage` with `notify_when_idle`
  subscribes to one notice when another local session next goes idle or
  exits. If the asking session is idle, the notice starts a new turn. It
  expires after 12 hours
  ([cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging#get-a-notice-when-another-session-goes-idle)).

### Timers

- **`/loop` and the cron tools.** `CronCreate`, `CronList` and `CronDelete`
  schedule recurring or one-shot prompts in the current session. A 5-field
  cron expression, one-minute granularity, up to 50 tasks, local time zone.
  Natural language works ("in 45 minutes, check whether the integration
  tests passed"). `/loop 5m <prompt>` runs on a fixed interval; `/loop
  <prompt>` lets Claude pick a delay between 1 min and 1 h each iteration via
  the `ScheduleWakeup` tool
  ([scheduled tasks](https://code.claude.com/docs/en/scheduled-tasks)). Added
  in 2.1.71.
- **Firing rules.** The scheduler checks every second and fires a due prompt
  only between turns: "If Claude is busy when a task comes due, the prompt
  waits until the current turn ends." Recurring tasks get up to 30 min of
  deterministic jitter and expire after 7 days. Missed fires are not caught
  up; one fire happens when the session goes idle.
- **Lifetime.** "Tasks only fire while Claude Code is running and idle."
  `--resume` / `--continue` restores unexpired `CronCreate` tasks, but not a
  self-paced `/loop`, and "Background Bash and monitor tasks are never
  restored on resume" (same page, Limitations).
- **Durable scheduling is separate.** Cloud routines (`/schedule`, the
  `RemoteTrigger` tool) run on a schedule, an API POST or GitHub events, 1 h
  minimum interval, and each run "creates a new session"
  ([routines](https://code.claude.com/docs/en/routines)). Desktop scheduled
  tasks run locally while the desktop app is open and also start "a fresh
  session" per run
  ([desktop scheduled tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks)).
  Neither resumes an existing CLI session.

### What survives turn end and process exit

- **Turn end.** Background Bash from the main conversation or a background
  subagent keeps running after a final response. A foreground subagent's
  commands stop when it returns (tools reference).
- **`-p` exit.** Background Bash is terminated about 5 s after the final
  result. `-p` stays open for background subagents and workflows (10 min idle
  ceiling, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`) and for an armed Monitor
  until it fires or times out
  ([headless, background tasks at exit](https://code.claude.com/docs/en/headless#background-tasks-at-exit)).
- **Background sessions (`claude --bg`, `claude agents`).** A supervisor
  process hosts each session as its own process, detached from any terminal.
  A working session keeps running; an idle, unattached one is stopped after
  about an hour unless pinned, and resumes when you attach or reply. When a
  session's process stops or restarts, its background shell commands,
  workflows and background subagents carry over to the next process; monitors
  do not
  ([agent view, supervisor](https://code.claude.com/docs/en/agent-view#the-supervisor-process)).
  Backgrounding a session carries `/loop` tasks with it (scheduled tasks,
  Limitations).

### Injecting a message from outside

- **Inbox socket (the direct answer to issue #46).** Every session with
  cross-session messaging on, including `claude -p` but not `--bare`, binds a
  per-session Unix socket. Its path is exported to hooks and Bash as
  `CLAUDE_CODE_MESSAGING_SOCKET`, with a per-session
  `CLAUDE_CODE_MESSAGING_TOKEN`. The docs name this section as the place to
  read "when you want a script or hook to post into a session". Delivery: "The
  receiving Claude reads the message between tool calls during an active
  turn ... When the receiving session is idle, Claude Code starts a new turn
  with the message"
  ([cross-session messaging, inbox socket](https://code.claude.com/docs/en/cross-session-messaging#the-sessions-inbox-socket)).
  - The docs give only the optional auth line,
    `{"type":"auth","token":"<token>"}`. The message line format comes from
    a debug hint in the 2.1.280 binary:
    `{"type":"user","message":{"role":"user","content":"hello"}}`, piped
    through `socat - UNIX-CONNECT:<socket>`. Not tested here.
  - Connections that send no complete line within 30 s are closed (2.1.243),
    so a watcher should capture output first and connect after.
  - Inbound controls apply. Messages the session verifies came from its own
    child processes (a hook or Bash command posting back) are delivered by
    default; on Linux this is verified by process evidence even after the
    child exits. A foreign poster is treated as a peer: delivered to a session
    that prompts for permissions, held for approval in a
    `bypassPermissions` session unless `crossSessionInbound: "accept"` is
    set. A peer message can't approve prompts or run slash commands.
  - Available since 2.1.224 on macOS/Linux, every provider since 2.1.248.
- **Channels (research preview).** An MCP server started with `--channels`
  (or `--dangerously-load-development-channels` for custom ones) emits
  `notifications/claude/channel` and the event lands in the running session.
  The reference ships a webhook receiver example. Requires claude.ai or
  Console auth, not Bedrock/Vertex/Foundry, and org enablement on
  Team/Enterprise
  ([channels](https://code.claude.com/docs/en/channels),
  [channels reference](https://code.claude.com/docs/en/channels-reference)).
  Added in 2.1.80.
- **Background-session replies.** A reply sent from `claude agents` to a
  stopped session wakes it; an undeliverable reply is saved and sent as the
  next prompt when the process restarts (agent view, peek and reply). From
  the shell, `claude --resume <id> --bg "<prompt>"` continues that session in
  place under the same ID when nothing is running it, and starts an announced
  copy when something is (agent view; `claude --help`, 2.1.257).
- **`claude -p --resume <id>` against a live session.** No lock. "If you
  resume the same session in two terminals without forking, messages from
  both interleave into one transcript"
  ([sessions](https://code.claude.com/docs/en/sessions)). The live process
  does not load the other process's turn into its context (inferred; not
  tested), so this is not an injection path.
- **Agent SDK.** In streaming input mode the host program keeps a
  long-lived query and can push queued messages or interrupt at any time
  ([streaming input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode)).
  That only helps when the SDK host owns the session.
- **Remote Control** drives a local session from claude.ai or the mobile app
  ([remote control](https://code.claude.com/docs/en/remote-control)). It is
  a human steering path, not a script API.

### Hooks

- Stop and SubagentStop can return `decision: "block"` with a `reason`, or
  `hookSpecificOutput.additionalContext`, to keep the turn going, capped at 8
  consecutive continuations. Their input includes `background_tasks` and
  `session_crons` (2.1.145), so a hook can tell "done" from "paused waiting on
  background work or a wakeup"
  ([hooks, Stop](https://code.claude.com/docs/en/hooks#stop)).
- `FileChanged` fires when a watched file changes on disk, but has no
  decision control and only shows stderr to the user. `Notification` fires on
  `idle_prompt` and permission prompts, outbound only.
- `asyncRewake` (above) is the one hook form that wakes the model on its own.

## 2. Codex

Source links are shortened: `B` =
`https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs`. Full citations
are in `raw/codex-report.md`; `raw/codex-unified-exec-report.md` traces the
background-shell path in more detail and agrees with it.

### Background jobs and completion notification

- **Background shell (unified_exec).** `exec_command` returns output, or a
  session ID if the command is still running after `yield_time_ms` (250 ms to
  30 s, default 10 s). `write_stdin` with empty `chars` polls, waiting up to
  `background_terminal_max_timeout` (default 5 min)
  (`B/core/src/tools/handlers/shell_spec.rs` ~L24-150;
  `B/core/src/unified_exec/process_manager.rs` ~L1015-1024).
- **No wake on exit.** `spawn_exit_watcher` sends an `ExecCommandEnd` event to
  clients when the process exits. The event does not enter model history and
  does not start a turn (`B/core/src/unified_exec/async_watcher.rs`
  ~L163-247). If the thread is idle, the model learns of the exit only when it
  next polls.
- **Limits.** Soft cap of 64 processes with LRU pruning, 1 MiB output buffer,
  no wall-clock timeout (`process_manager.rs` ~L1725-1790). TUI `/ps`,
  `/stop`, `/clean`; app-server `thread/backgroundTerminals/*`.

### Timers

- **`clock.sleep{duration_ms}`**, 1 ms to 12 h, blocks inside the current turn
  and ends early on steer input (`B/core/src/tools/handlers/sleep.rs` ~L28,
  ~L110-150). It is registered only when the model catalog lists `clock` or a
  feature flag forces it; in the local models cache only the gpt-6-* models
  list it (`B/core/src/tools/spec_plan.rs` ~L1176-1192). It cannot wake an
  idle thread.
- **Not timers:** `current_time_reminder` adds the time to context;
  `goals` auto-continues an active goal when the thread goes idle
  (`B/ext/goal/src/extension.rs` ~L180-192); `wait_agent` waits on subagents
  only, up to 1 h.
- **Scheduled automations** live in the ChatGPT desktop app and on the web,
  not the CLI: "Codex CLI doesn't provide the Scheduled management
  interface" ([automations](https://learn.chatgpt.com/docs/automations?surface=app)).

### What survives turn end and process exit

- **Turn end:** background processes survive, by design
  (`process_manager.rs` ~L598; tests in `B/core/tests/suite/unified_exec.rs`
  ~L2848, ~L2949).
- **Process exit:** `shutdown_session_runtime` calls
  `terminate_all_processes()` (`B/core/src/session/handlers.rs` ~L285-303).
  `codex exec` and a TUI with an embedded server take their processes down
  with them. On the shared daemon a thread unloads after
  `thread_unload_delay_secs` (default 60) with no subscribers and no activity;
  that unload probably goes through the same shutdown (not traced).

### Injecting a message from outside

- **`codex queue --thread <id|name> --message <text>`** (0.149.0) sends
  `thread/queue/add` through the running daemon, or an embedded app-server if
  none is running. The message is stored in SQLite (`~/.codex/queue_1.sqlite`).
  Every app-server with a local thread store, including the TUI's and
  `exec`'s in-process servers, runs the queue service, which checks SQLite
  every 10 s for writes from other processes (`B/ext/queue/src/service.rs`
  ~L89-245). Delivery by thread state:
  - idle: `start_turn_if_idle` starts a turn with `turn_trigger:"queue"`
    (service.rs ~L392-470);
  - running: waits for the turn to finish, then `on_thread_idle` dispatches;
    nothing is steered in mid-turn;
  - last turn interrupted: the queue pauses until a later idle with cause
    `Completed` (service.rs ~L549-566);
  - not loaded anywhere: persists until some process resumes the thread.
- **App-server protocol.** `turn/start` steers into an active turn if one is
  running; `turn/steer`, `turn/interrupt`, `thread/queue/{add,list,...}`
  (experimental), and `thread/inject_items` (appends history, starts no turn).
  Notifications include `turn/completed`, `thread/status/changed` and
  `item/completed` (`B/app-server-protocol/src/protocol/common.rs`
  ~L559-758). Multiple clients can subscribe to one daemon thread.
- **`codex exec resume <id>` against a live thread** conflicts: resume takes
  an exclusive writer lock and fails with "thread <id> already has an active
  writer" (`B/rollout/src/writer_lock.rs` ~L42-75;
  `B/thread-store/src/local/mod.rs` ~L332-345). The TUI falls back to
  read-only viewing. So `exec resume` works only on a thread nobody holds.

### Hooks

- Stop with `decision:"block"` plus `reason` continues the same turn
  (`B/core/src/session/turn.rs` ~L646-680;
  [hooks docs](https://learn.chatgpt.com/docs/hooks)).
- `"async": true` command hooks drain their output only at the next sampling
  or next turn; "Finishing a background hook doesn't start a new turn."
  (`B/core/src/hook_runtime.rs` ~L767-800).
- Legacy `notify` runs a program on `agent-turn-complete`, outbound only.
- There is no Notification event and no hook that fires on outside events.

## 3. Cursor Agent

Paths are relative to
`V=~/.local/share/cursor-agent/versions/2026.09.15-d2fe57e/`, the installed
bundle. Full citations are in `raw/cursor-report.md`.

### Background jobs and completion notification

- **Background shell.** The shell tool takes `is_background`,
  `timeout_behavior` (`CANCEL` or `BACKGROUND`) and `output_notification`;
  `ForceBackgroundShell` and `WRITE_SHELL_STDIN` exist. An `await` tool
  (`task_id`, `block_until_ms?`, `regex?`) blocks for a result. Background
  subagents use Task `run_in_background` and `SubagentAwaitArgs`. Output goes
  to `~/.cursor/projects/<ws>/terminals/<shellId>.txt` (`V/index.js`,
  protobuf schema strings).
- **Wake without polling.** When a background shell exits, the CLI queues a
  `task_finished` completion. With `output_notification{pattern, reason,
  debounce, notification_limit}`, each regex match on output queues a
  `task_progress` notice (debounce at least 5 s). The CLI then runs a
  `backgroundTaskCompletionAction` as a new turn
  (`V/index.js` around `enqueueShellCompletion`; `V/7021.index.js`).
- **Interactive TUI:** completions are injected only when idle: no turn
  running and no queued user messages. If the last turn was user-aborted,
  pending completions are dropped (`V/7021.index.js` ~offset 884400).
- **`-p` mode:** the process stays alive after the final turn while
  background work runs; each completion becomes another turn and stream-json
  emits `{"type":"system","subtype":"task_notification",...}`. Hidden flags:
  `--background-shell-timeout <s>` and `--single-turn`
  (`V/7021.index.js` ~offset 564000).

### Timers

- **None locally.** No sleep, schedule or cron tool (`V/index.js`, `ToolCall`
  oneof). A background `sleep 10800; gh pr list` should act as a timer via
  the completion wake, but only while the process lives (inferred, not
  tested).
- **Goal continuation** (`create_goal`, `goalContinuationAction`) is behind
  `agent_goal_continuation`, default false and forced off for local agents.
- **Cloud only:** subscriptions ("wakes when something happens", "cloud
  agents only, for now", [changelog 08-19-26](https://cursor.com/changelog/08-19-26))
  and automations with cron, webhook and GitHub/GitLab triggers
  ([automations](https://cursor.com/docs/cloud-agent/automations)). From the
  CLI, reachable through the `/automate` skill or an `&`-prefixed handoff to
  the cloud.

### What survives turn end and process exit

- Background shells survive turn end within the process.
- On `-p` exit or SIGINT, `backgroundWorkRegistry.abortAllWork()` kills
  background work. The wake queue is in memory, so nothing carries over to a
  later `--resume` (`V/7021.index.js` ~offsets 550552, 566188).
- `persist` runs the agent in a Cursor-managed tmux session
  (`tmux -L cursor-agent`), which keeps the process, and so the wake queue,
  alive after the terminal closes. Linux and macOS only.

### Injecting a message from outside

- **No supported local API.** `persist` has only `list`, `attach` and `stop`;
  no send subcommand. `tmux -L cursor-agent send-keys` into a persist session
  would type into the TUI; unsupported and untested.
- **`-p --resume <chatId> "msg"`** appends to the same chat
  (`~/.cursor/chats/<ws-hash>/<chatId>/store.db`, WAL). It refuses a chat
  bound to a live persist session. For two ordinary processes on one chat no
  lock was found.
- **ACP.** Hidden `agent acp` runs a JSON-RPC-over-stdio ACP server with new,
  load and list sessions. The client that owns the process can send prompts
  whenever it wants. This is the cleanest supported path, but it requires the
  tool to own the agent process.
- **Cloud Agents API.** `POST /v1/agents/{id}/runs` for a follow-up run,
  `409 agent_busy` while a run is active
  ([endpoints](https://cursor.com/docs/cloud-agent/api/endpoints)). Applies to
  cloud agents, including ones executing on a local My Machines worker, not to
  plain `cursor-agent` chats.

### Hooks

- `stop` and `subagentStop` can return `followup_message`, submitted as the
  next user message, default limit 5 per script (`loop_limit`)
  ([hooks](https://cursor.com/docs/agent/hooks)). Confirmed in the
  interactive TUI ("Stop hook returned followup_message, queueing",
  `V/7021.index.js`); unknown in `-p`.
- `sessionStart`, `beforeSubmitPrompt` and `subagentStop` can add context.
  All hooks fire on the agent's own lifecycle; none fires on outside events.
  A stop hook that reads an inbox file works only at turn end.

## 4. OpenCode

Links are shortened: `…/` =
`https://github.com/anomalyco/opencode/blob/v1.18.27/`. Full citations are in
`raw/opencode-report.md`.

### Background jobs and completion notification

- **No background shell.** The bash tool takes only `command`, `timeout` and
  `workdir` (`…/packages/opencode/src/tool/shell/prompt.ts` ~L15-23); default
  timeout 120 s, no maximum found. On timeout or abort the process group gets
  SIGTERM, then SIGKILL. A `nohup cmd >log 2>&1 &` child should survive the
  call, but nothing re-invokes the model when it exits (inferred from
  `…/packages/core/src/cross-spawn-spawner.ts`).
- **Background subagents do wake the parent.** The `task` tool accepts
  `background: true` behind `OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS` (or
  `OPENCODE_EXPERIMENTAL`). On completion, OpenCode calls `ops.prompt` on the
  parent session with a synthetic "Background task completed/failed" part,
  which starts a turn. The model is told "DO NOT sleep, poll"
  (`…/packages/opencode/src/tool/task.ts` ~L25-60, ~L97-101, ~L227-265). Jobs
  are held in memory only.
- **PTY API.** The server has `/pty` routes and publishes
  `pty.exited {id, exitCode}`, but the model has no tool for it; it backs the
  UI terminal pane.

### Timers

None. No sleep, wait, schedule or cron tool, config key or server feature.
The docs list third-party plugins (`opencode-scheduler`,
`opencode-background-agents`) (`…/packages/web/src/content/docs/ecosystem.mdx`
~L45, ~L49).

### What survives turn end and process exit

Background subagent jobs live in the owning process's memory and are
cancelled with the session. Nothing is durable across a restart.

### Injecting a message from outside

- **HTTP API.** `POST /session/:id/prompt_async` returns 204 at once and
  forks the prompt; `POST /session/:id/message` blocks until the reply
  (`…/packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts`
  ~L311-329). If the session is busy, the user message is written
  immediately and the running loop answers it at the next step boundary, in
  the same run (`…/packages/opencode/src/session/prompt.ts` ~L1052-1118).
  `shell`, revert and delete return `SessionBusyError`. `GET /event` (SSE)
  publishes `session.status` and `session.idle`; the built-in client also
  polls `GET /session/status` because events can be missed.
- **v2 API** `POST /api/session/:id/prompt` takes `delivery: "steer"|"queue"`
  and stores input durably. The TUI doesn't use it; whether it drives the
  sessions the TUI shows is unknown.
- **The TUI does not listen by default.** It talks to its worker at
  `http://opencode.internal` and opens a real port only with `--port`,
  `--hostname` or `--mdns` (`…/packages/opencode/src/cli/cmd/tui.ts`
  ~L233-250). `server.port` in config does not change this. No port file
  exists.
- **`opencode run --attach <url> --session <id>`** sends into that server's
  runner. Without `--attach`, `run` starts its own in-process server on the
  shared SQLite database; a TUI in another process would not see the new
  messages live and the two could run loops on one session at once
  (inferred).
- **Plugins.** A plugin receives an SDK `client` wired to its own process's
  server and an `event` hook that sees `session.idle`. A plugin can set a
  timer or watch a child process and call `client.session.promptAsync(...)`
  in the owning process, so the TUI shows the turn live (inferred, untested;
  `…/packages/plugin/src/index.ts` ~L56-65, ~L224-334).

### Hooks

Plugin hooks (`event`, `chat.message`, `tool.execute.before/after`,
`experimental.compaction.autocontinue` and others) are in-process
callbacks, not shell hooks. None fires on outside events, but a plugin is
ordinary code and can create its own triggers, which makes it the
in-process injection route.

## Comparison

| | Claude Code | Codex | Cursor Agent | OpenCode |
| --- | --- | --- | --- | --- |
| Background jobs | Bash `run_in_background`, auto-background on timeout; Monitor; background subagents | `exec_command` sessions, polled with `write_stdin` | Shell `is_background`, `ForceBackgroundShell`; background subagents | None for shell; `task background:true` subagents (experimental flag) |
| Completion notification | Push: exit re-invokes the model; Monitor per-line events; `asyncRewake` hook | None to the model; `ExecCommandEnd` event to clients only | Push: exit or regex match starts a turn when idle | Push for background subagents only |
| Timers | `CronCreate`/`/loop`/`ScheduleWakeup`, 1 min granularity, 7-day expiry, idle-only firing; cloud routines and Desktop tasks start new sessions | `clock.sleep` up to 12 h, in-turn, model-gated | None locally; cloud subscriptions and automations | None |
| Survives turn end | Yes (bg Bash, Monitor, cron) | Yes (processes) | Yes (within process) | Subagent jobs yes; shell no |
| Survives process exit | Only in `--bg` sessions (shells, subagents carry over; monitors don't); cron restored on `--resume`; `-p` kills bg Bash after ~5 s | No; daemon keeps threads loaded while subscribed | No; `persist` (tmux) keeps the process alive | No |
| External injection | Inbox socket; channels (preview); `claude --resume <id> --bg "msg"` for a stopped session; SDK streaming input | `codex queue`; app-server `turn/start`, `turn/steer`, `thread/queue/*` | None supported locally; ACP if you own the process; tmux `send-keys` into `persist` (untested); cloud API | `POST /session/:id/prompt_async` (needs a listening server); `run --attach`; plugin `client.session.promptAsync` |
| Busy-session behavior | Socket message read between tool calls; cron waits for turn end | Queue waits for turn end; paused after an interrupt | Completions wait for idle; dropped after user abort | Joins the running loop at the next step |
| Hooks that can continue or wake | Stop/SubagentStop block or `additionalContext`; `asyncRewake` wakes on exit 2; `FileChanged` (no decision control) | Stop `decision:"block"`; async hooks drain next turn only | `stop`/`subagentStop` `followup_message` (TUI confirmed, `-p` unknown) | Plugin `event` hook sees `session.idle`; plugins can prompt |

## Gaps and injection paths

### What a resume tool would have to fill

1. **Triggers that outlive the agent process.** Every native wake-up lives in
   the process that owns the session: Claude's background Bash and Monitor
   (except in `--bg` sessions), Cursor's in-memory wake queue, OpenCode's
   background jobs, Codex's unified_exec processes. When the process exits,
   the trigger is gone. The tool needs its own watcher process.
2. **Timers that fire into a session that isn't running.** Claude's cron
   fires only while the session runs and is idle, with jitter up to 30 min on
   recurring tasks. Codex and OpenCode have no out-of-turn timer; Cursor has
   none locally. The cloud schedulers (Claude routines, Cursor automations,
   ChatGPT automations) start new sessions rather than resuming the local one.
3. **Watching things the agent didn't start.** Native notification covers
   jobs the agent launched. A PR, a CI run or a job started elsewhere needs
   an outside watcher on every CLI except Claude with Monitor or a channel,
   and Monitor caps each watch at 30 min.
4. **Addressing.** Each CLI names the target differently: a socket path
   (Claude), a thread UUID or name (Codex), a chat ID or ACP session
   (Cursor), a server URL plus session ID (OpenCode). The tool has to capture
   this at arm time.
5. **Busy and interrupted sessions.** Semantics differ: Claude steers the
   message in between tool calls, OpenCode joins the running loop, Codex
   queues until the turn ends and pauses after an interrupt, Cursor drops
   completions after a user abort. The tool should decide per CLI whether to
   deliver, queue or retry.
6. **Fallback when the session is not live.** The tool needs a resume path
   for a stopped session, and must avoid forking or racing a live one (Claude
   and Cursor `-p --resume` do not lock; Codex `exec resume` refuses a live
   thread).

### Most promising injection path per CLI

- **Claude Code.** Post to the session's inbox socket. A watcher launched
  from inside the session inherits `CLAUDE_CODE_MESSAGING_SOCKET` and
  `CLAUDE_CODE_MESSAGING_TOKEN` and should count as an own child, delivered
  without approval by default. Send the auth line anyway: whether a
  detached, reparented watcher still passes the Linux process-evidence check
  is untested. Unverified posters are delivered to a session that prompts
  for permissions and held in a `bypassPermissions` session unless
  `crossSessionInbound` is `accept`. For a timer or watcher that must
  outlive the terminal, run the session as a `--bg` session. If the session
  has stopped, `claude --resume <id> --bg "<message>"` continues it in place.
  For a pure in-session "in 3 hours" prompt, `CronCreate` already works.
- **Codex.** `codex queue --thread <id> --message "<text>"`. It is durable,
  works across processes, and delivers when the thread is idle (up to about
  10 s latency). The tool supplies only the trigger. If the thread is not
  loaded anywhere, the message waits for the next resume, so the tool may
  also run `codex exec resume <id>` when no writer holds the lock.
- **Cursor Agent.** Inside a live session, launch the trigger as a background
  shell (`<wait-for-condition>; echo done`) so its exit wakes the agent;
  keep the process alive with `persist`. From outside there is no supported
  live path. If the tool owns the process, drive it over ACP. Otherwise use
  `-p --resume <chatId> "<message>"` only when no other process has the chat
  open.
- **OpenCode.** Run the TUI with `--port <n>` (or `opencode serve` and attach
  the TUI to it) and `POST /session/<id>/prompt_async`, watching `GET /event`
  and `GET /session/status` for idle. For no open port, ship a small plugin
  that arms timers or process watchers and calls
  `client.session.promptAsync` in-process.

## Verification and open items

Spot-checks against source for this note, all passed:

- Codex: the queue service polls SQLite every 10 s, starts queued turns with
  `turn_trigger:"queue"`, and skips dispatch after an interrupted idle
  (`B/ext/queue/src/service.rs` ~L96, ~L392-441, ~L551). The exit watcher
  only emits `ExecCommandEnd` (`async_watcher.rs` ~L163-247). `clock.sleep`
  max is 12 h and returns "Sleep interrupted by new input."
  (`sleep.rs` ~L28, ~L150). The "active writer" error string is in
  `B/rollout/src/writer_lock.rs` ~L70, not `live_writer.rs` as one citation
  in the raw report suggests; the claim holds.
- OpenCode: `task.ts` `inject` calls `ops.prompt` with a synthetic
  "Background task completed/failed" part; the shell tool schema has only
  `command`, `timeout`, `workdir`; `promptAsync` forks the prompt and returns
  204; the TUI uses `http://opencode.internal` unless `--port`, `--hostname`
  or `--mdns` is passed.
- Cursor: the 2026.09.15 bundle contains `backgroundTaskCompletionAction`
  injection gated on no running turn and no queued messages, the
  "last turn was user-aborted" drop, the stop-hook `followup_message` queue
  log line, and the persist-session refusal on `-p --resume`.
- `codex queue --help` on the installed 0.156.0 matches
  `--thread <THREAD> --message <TEXT>`.

Unverified:

- Claude Code inbox socket message format (`{"type":"user",...}`) is from a
  binary debug string, not the docs; no message was posted.
- That `claude -p --resume` into a live session is invisible to the live
  process's context (docs say only that transcripts interleave).
- Codex: daemon thread-unload killing background processes; runtime
  behavior of `codex queue`; whether gpt-5.6 models lack `clock.sleep`.
- Cursor: stop-hook `followup_message` in `-p`; concurrent `--resume` of one
  chat; `tmux send-keys` into `persist`; background `sleep N` as a timer.
- OpenCode: `nohup` children outliving the tool and OpenCode; TUI plus
  `run --session` in separate processes; v2 `steer`/`queue` on TUI sessions;
  a plugin timer calling `promptAsync`.
