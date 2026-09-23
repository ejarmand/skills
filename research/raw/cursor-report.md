I checked the installed bundle, ran the `--help` output, looked at `~/.cursor`, and read the docs and changelog (fetched 2026-09-22). No model sessions were started. Your impression is only half right for Cursor. It has no sleep or schedule tool on the local side, but it does have a real event-driven wake-up: when a background shell or subagent finishes (or its output matches a regex), the CLI starts a new turn in the same chat by itself. What it lacks is any official way for an outside process to put a message into a running local session. The only local route is typing into the tmux pane `persist` creates, which isn't an API.

Paths below are relative to `V=~/.local/share/cursor-agent/versions/2026.09.15-d2fe57e/`.

## 1. Background shell

- **Starting in the background.** The shell tool's arguments include `is_background`, `timeout_behavior` (`CANCEL` or `BACKGROUND`) and `output_notification`. A `ForceBackgroundShell` call exists for moving a running command to the background. Background reasons are `TIMEOUT` or `USER_REQUEST`. There is also a `WRITE_SHELL_STDIN` tool (`WriteShellStdinArgs|1 shell_id|2 chars`). (`index.js`, protobuf schema strings)
- **Checking later.** There is an `await` tool: `AwaitArgs|1 task_id|2 block_until_ms?|3 regex?`. It returns either complete (`exit_code`, `output_file_path`, `wake_reason`) or still running. The UI treats a missing `block_until_ms` as 30000 ms (`V/7021.index.js`, `await-tool-ui`). Background subagents are separate: the Task tool takes `run_in_background`, and subagents are awaited with `SubagentAwaitArgs|agent_id|timeout_ms`. Output goes to `~/.cursor/projects/<ws>/terminals/<shellId>.txt` (`index.js`).
- **Wake-up without polling.** The CLI keeps an in-memory queue of pending wake-ups:
  - When a background shell exits, it queues a completion with reason `task_finished` and status success, error or aborted.
  - If the model set `output_notification{pattern, reason, debounce, notification_limit}`, each regex match queues a `task_progress` notification. Debounce is at least 5 s, and a "Notification limit reached" message is sent when the limit is hit.
  - The CLI then injects a `backgroundTaskCompletionAction`, which runs as a new turn marked `BACKGROUND_TASK_COMPLETION`. (`index.js`, around `enqueueShellCompletion`; `V/7021.index.js`)
- **Interactive TUI.** The CLI injects completions only when it is idle: no turn running and no queued user messages. If the last turn was aborted by the user, pending completions are dropped (the code logs "Dropping … completion(s): last turn was user-aborted"). (`V/7021.index.js`, around offset 885000)
- **`-p` mode.** After the final turn, the process stays alive while background work is running. Each completion becomes another turn, and stream-json prints `{"type":"system","subtype":"task_notification",task_id,status,title,…}`. Two hidden flags control this:
  - `--background-shell-timeout <s>` aborts leftover background shells and emits `background_shell_timeout`. Waits on subagents stay unbounded.
  - `--single-turn` skips the wait entirely.
  
  (`index.js` hidden options; `V/7021.index.js` around offset 562000)
- **When the CLI exits.** On `-p` exit or SIGINT, `backgroundWorkRegistry.abortAllWork()` kills background work. The wake-up queue lives in memory only, so nothing carries over to a later `--resume`. (`V/7021.index.js` around offsets 550552 and 566188)

## 2. Timers

- **Local CLI.** There is no sleep, schedule, cron or wake-up tool. The list of tools the agent can call has nothing timer-like (`index.js`, `ToolCall` oneof). A timer is possible only indirectly: the agent can run `sleep 10800; gh pr list` as a background shell, and its completion wakes the agent (inferred from §1, not tested). That works only as long as the process stays alive.
- **Goal continuation.** A goal feature (`create_goal` / `update_goal` tools, `goalContinuationAction`) exists, but it is behind the flag `agent_goal_continuation`. The flag defaults to false and is forced off for local agents (`!e.localAgent&&…`). (`index.js`, `V/7021.index.js`)
- **Cloud only.**
  - Subscriptions (announced 2026-08-19): "Cursor Agent subscribes to an event source … and wakes when something happens." "Subscriptions are available for cloud agents only, for now." The example given is "@cursor check back in an hour" (https://cursor.com/changelog/08-19-26).
  - Automations: cron triggers ("enter a cron expression"), webhook triggers (a private URL plus an API key) and GitHub/GitLab triggers. They can be created "with the /automate skill from a local agent session", but they run as cloud agents (https://cursor.com/docs/cloud-agent/automations). The bundle's trigger types include `CRON` and `WEBHOOK` (`index.js`, `PlatformTriggerType`).
  - From the CLI, the only way in is the `/automate` skill or handing the chat to the cloud with an `&` prefix (https://cursor.com/docs/cli/overview).

## 3. Resume

- **Commands.** `--resume [chatId]`, `--continue` (documented as an alias for `--resume=-1`), `resume` (latest chat), `ls` (a picker) and `create-chat` (returns a new ID) (`--help`; https://cursor.com/docs/cli/reference/parameters). There is also a hidden `--new-session-id <uuid>` (`index.js`).
- **Storage.** Each chat is a SQLite database at `~/.cursor/chats/<workspace-hash>/<chatId>/store.db`. `--resume` opens that same file and continues the chat in place, so `-p --resume <id> "msg"` adds to the same chat (`V/7021.index.js` around offset 743093). The database runs with `journal_mode=WAL` and `busy_timeout=5000` (`V/4723.index.js`).
- **Locking.** The only chat-level guard I found is for `persist` sessions. They write binding files to `/tmp/cursor-agent-persist-<uid>/bindings/<chatId>.json`. If the chat is bound to a live persist session, `-p --resume` exits with "Chat X is still running in persistent session S… stop it before a headless resume". Interactive resume instead offers "Take over this session and disconnect the other client? [y/N]" (`V/7021.index.js` around offset 15172; `index.js` `persistent-session.ts`). For two ordinary processes on the same chat I found no lock (see Unverified).

## 4. `persist`

- `persist [prompt]`, `persist list`, `persist attach <session>` and `persist stop <session>` are the only subcommands. `list` printed "No Cursor-managed persistent sessions." The command has no send or input subcommand, and `persist attach --help` treats `--help` as a session name.
- It is built on tmux: `tmux -u -L cursor-agent -f /dev/null new-session -d …` with `TMUX_TMPDIR=/tmp`. The server name can be changed with `CURSOR_AGENT_TMUX_SERVER_NAME`. Sessions are tagged with `@cursor_managed` and `@cursor_chat_id`. Exit status goes to `/tmp/cursor-agent-persist-<uid>/completions/…`. It works only on Linux and macOS and "Persistence requires tmux." (`index.js`, `./src/persistence/persistent-session.ts`)
- So an outside process could type into a session with `TMUX_TMPDIR=/tmp tmux -L cursor-agent send-keys -t <session> "…" Enter`. This is unsupported and I did not test it.

## 5. `worker` and the Cloud Agents API

- The current API has `POST /v1/agents/{id}/runs` for "follow-up run on existing agent". It returns `409 agent_busy` while a run is active, so it queues nothing mid-run. `GET …/runs/{runId}/stream` streams events over SSE. The docs list no local or CLI session endpoints and no scheduling endpoints (https://cursor.com/docs/cloud-agent/api/endpoints). The legacy `/v0/agents/{id}/followup` URL I tried returned 404.
- `agent worker start` (My Machines) keeps the agent loop in Cursor's cloud and runs tool calls on your machine (https://cursor.com/docs/cloud-agent/self-hosted-guides/my-machines). A cloud agent on a My Machines worker is therefore the only setup that gets API follow-ups, subscriptions and automations while still running locally. None of this applies to plain `cursor-agent` chats.

## 6. Hooks

- **Events.** `sessionStart`, `sessionEnd`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `subagentStart`, `subagentStop`, `beforeShellExecution`, `afterShellExecution`, `beforeMCPExecution`, `afterMCPExecution`, `beforeReadFile`, `afterFileEdit`, `beforeSubmitPrompt`, `preCompact`, `stop`, `afterAgentResponse`, `afterAgentThought`, plus the editor-only `beforeTabFileRead`, `afterTabFileEdit` and `workspaceOpen` (`index.js` hooks enum; https://cursor.com/docs/agent/hooks).
- **`stop` / `subagentStop`.** Output `followup_message` is "automatically submit[ted] as the next user message". The hook receives `loop_count` (starts at 0). The default limit is "5 auto follow-ups per script", set with `loop_limit` (docs). In the bundle, `B=5` is the default and `loop_limit: null` means no limit. Hooks imported from Claude Code's format get `loop_limit:null`. The default hook timeout is 60 s (`index.js`, `../hooks/dist`).
- **CLI support.**
  - Interactive TUI: confirmed. The stop hook's `followup_message` is pushed onto the queued-message list (debug log: "Stop hook returned followup_message, queueing") (`V/7021.index.js` around offset 901300).
  - `-p` mode: the stop hook only runs if the server asks the CLI to run it (a server-issued `ExecuteHookRequest.stop`), so I can't say whether follow-ups work there (see Unverified).
  - A forum bug from 2026-05-20 (CLI 2026.05.16) reports stop-hook follow-ups stuck in the queue after waiting on background tasks. Staff could not reproduce it (https://forum.cursor.com/t/stop-hook-followups-fail-to-land-after-waiting-for-background-tasks/161164).
- **Other injection points.** `sessionStart`, `beforeSubmitPrompt` and `subagentStop` can return `additional_context`. None of the hooks fire on outside events; they all fire on the agent's own lifecycle. The practical pattern is a stop hook that checks an inbox file and returns `followup_message`, but it only runs when a turn ends.

## 7. `agent` vs `cursor-agent`, ACP

- `~/.local/bin/agent` and `~/.local/bin/cursor-agent` are both symlinks to the same binary.
- There is a hidden `agent acp` command: "Start the Cursor Agent as an ACP (Agent Client Protocol) server" (`index.js`), speaking JSON-RPC over stdio. It supports new, load and list sessions (`unstable_listSessions`). It stores `~/.cursor/acp-sessions/<id>/meta.json`, and there are 2,298 of those here, so some client on this machine is using ACP. It also drains background completions inside a prompt (`V/1699.index.js`, `subagent-completion-drain.ts`).
- ACP is the cleanest supported way to push a message into a live local session, because the client that owns the process can send a prompt whenever it wants. That still has to go through the owning process.
- Other hidden commands: `worker-server`, `local-worker`. `~/.cursor/projects/<ws>/worker.sock` is a per-workspace local worker socket, not a message inbox.

## Unverified

- Whether `followup_message` from a stop hook is honoured in `-p` mode.
- What happens when two non-persist processes `--resume` the same chat at once. I found no lock; my guess is last writer wins in the shared `store.db`. Your cursor-agent `SKILL.md` says "a workspace lock rejects concurrent runners", which I did not re-check.
- Using `tmux send-keys` to inject into `persist` sessions.
- A background `sleep N` working as a timer that wakes the agent.
- The exact default and upper bound for `block_until_ms`.
- Whether any server-side flag turns on goal continuation or subscriptions for local CLI sessions.

I wrote one throwaway helper, `/tmp/ctx.py`, for grepping the bundle; the system `grep` is ugrep and rejected long context patterns. Nothing in the repo was changed.
