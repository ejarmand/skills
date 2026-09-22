I read the v1.18.27 source and the bundled docs, and ran `--help` on the installed binary. No sessions were started. Your impression is mostly wrong for OpenCode. It has a real "wake me when this finishes" mechanism, but only for background subagents, not for shell commands. It has no timer tool at all. The strongest trigger primitive is the HTTP API plus plugins.

Base URL for citations: `https://github.com/anomalyco/opencode/blob/v1.18.27/` (abbreviated as `…/` below).

## 1. Background shell

- **The bash tool can't run anything in the background.** Its only parameters are `command`, `timeout` and `workdir` (`…/packages/opencode/src/tool/shell/prompt.ts` ~L15-23). The tool list has no PTY or job tool (`…/packages/opencode/src/tool/registry.ts` ~L231-248).
- **Timeouts:** the default is 120000 ms (`…/packages/opencode/src/tool/shell.ts` ~L347). You can change it with `OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS` (`…/packages/opencode/src/effect/runtime-flags.ts` ~L53). The model can pass any positive `timeout` and I found no maximum. When the timeout or an abort fires, the whole process group gets SIGTERM, then SIGKILL 3 s later (`shell.ts` ~L540-557).
- **Using `&` yourself:** commands spawn `detached: true` in their own process group on POSIX (`shell.ts` ~L303-309). The tool's exit-code signal resolves on Node's `close` event (`…/packages/core/src/cross-spawn-spawner.ts` ~L276-283). A backgrounded child that keeps the stdout pipe open will therefore block the tool until the timeout, and then its group is killed. With output redirected (`nohup cmd >log 2>&1 &`) and the shell exiting 0, the cleanup does not kill the group (`cross-spawn-spawner.ts` ~L381-390), so the child should survive the turn and probably survive OpenCode exiting too. After that the model can only check by polling (log files, `ps`). Nothing re-invokes it when the process exits.
- **PTY API:** the server has `/pty` routes: `GET /pty/shells`, `GET /pty`, `POST /pty`, `GET/PUT/DELETE /pty/:id`, `POST …/connect-token`, and a websocket `connect` (`…/packages/opencode/src/server/routes/instance/httpapi/groups/pty.ts` ~L17-144). It publishes `pty.created`, `pty.updated`, `pty.exited {id, exitCode}` and `pty.deleted` events (`…/packages/schema/src/pty.ts` ~L34-37). This is for the terminal pane in the UI. The model has no tool for it. A third-party plugin, `opencode-pty`, adds one (`…/packages/web/src/content/docs/ecosystem.mdx` ~L31).
- **The one real notification mechanism is background subagents.** The `task` tool accepts `background: true`, gated by `OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS` or `OPENCODE_EXPERIMENTAL` (`…/packages/opencode/src/tool/task.ts` ~L58-61, ~L97-101). When the job finishes, OpenCode calls `ops.prompt` on the parent session with a synthetic text part ("Background task completed/failed: …"). That re-invokes the parent model (`task.ts` ~L227-265). The model is told "DO NOT sleep, poll…" (~L31-35). `POST /experimental/session/:sessionID/background` moves running synchronous subagents to the background (`…/groups/experimental.ts` ~L100, ~L235). Jobs are held in memory only (`…/packages/core/src/background-job.ts`). Cancelling the session cancels its jobs (`…/packages/opencode/src/session/run-state.ts`, `cancelBackgroundJobs`).

## 2. Timers

There's no sleep, wait, schedule or cron tool, config key or server feature. A search of core, opencode, schema and plugin sources turned up only internal Effect `Schedule` uses. The docs list only third-party options: `opencode-scheduler` (launchd/systemd cron) and `opencode-background-agents` (`ecosystem.mdx` ~L45, ~L49).

## 3. Server API

Routes are defined in `…/packages/opencode/src/server/routes/instance/httpapi/groups/session.ts` ~L77-103 and ~L316-368, and documented in `…/packages/web/src/content/docs/server.mdx` ~L175-180.

- `POST /session/:id/message` takes `{messageID?, model?, agent?, noReply?, format?, system?, variant?, parts}` and blocks until the reply is done.
- `POST /session/:id/prompt_async` takes the same body, returns 204 right away, and forks the prompt (`…/handlers/session.ts` ~L311-329). If it fails, a `session.error` event is published.
- `POST /session/:id/command` takes `{command, arguments, agent?, model?, …}`.
- `POST /session/:id/shell` takes `{agent, command, model?}`.

**When the session is busy:**
- **`message`, `prompt_async`, `command`:** these are neither queued separately nor rejected. The user message is written to the database immediately (`…/packages/opencode/src/session/prompt.ts` ~L1052-1071), and `loop` joins the run already in progress (`…/packages/opencode/src/effect/runner.ts` ~L117-137). The loop re-reads messages every step. It only exits when the last assistant message's `parentID` equals the last user message's id (`prompt.ts` ~L1110-1118). So the new message gets answered at the next step boundary, in the same run. v1.17.9 stopped wrapping these follow-up messages in a steering reminder (release notes).
- **`shell`, revert and deleting a message:** these return a `SessionBusyError` (`runner.ts` `startShell` ~L139-150; `run-state.ts` `assertNotBusy`).

**v2 API:** it is mounted unconditionally (`…/httpapi/server.ts` ~L177, ~L281). `POST /api/session/:sessionID/prompt` takes `{id?, prompt, delivery?: "steer"|"queue", resume?}` (`…/packages/protocol/src/groups/session.ts` ~L205-223). It stores the input durably. A `steer` input is delivered at the next step and a `queue` input starts the next turn (`…/packages/core/src/session/input.ts` ~L245-290; `…/packages/core/src/session/runner/llm.ts` ~L187-196). The TUI doesn't call it, and I couldn't tell whether it drives the same sessions the TUI shows.

**Events:** `GET /event` is a server-sent events stream per directory. Its first event is `server.connected`. There is also `GET /global/event` (`…/handlers/event.ts`; `server.mdx` ~L95, ~L279). The session events are `session.status {sessionID, status: idle|busy|retry}` and the deprecated `session.idle {sessionID}` (`…/packages/schema/src/session-status-event.ts`; published in `…/session/status.ts` ~L39-47). `GET /session/status` returns a snapshot. The built-in `run` client listens for the idle event but also polls status, because "some transports can miss status events" (`…/cli/cmd/run/stream.transport.ts` ~L10-13). A watcher should do the same.

## 4. `opencode run --session` / `--attach`

- Without `--attach`, `run` starts its own server inside the process, with no HTTP listener. It uses an SDK client whose `fetch` calls `Server.Default().app.fetch` (`…/packages/opencode/src/cli/cmd/run.ts` ~L129-131, ~L947-960). `run --port` is declared (~L208) but never used.
- With `--attach <url>`, the SDK points at the remote server (`run.ts` ~L346-353, ~L943-946), so the message goes into that server's runner. That's confirmed from code.
- **Same session open in a TUI in another process:**
  - Both processes use one SQLite file, `<data>/opencode.db`, in WAL mode with `busy_timeout=5000` (`…/packages/core/src/database/database.ts` ~L26-31, ~L43-55).
  - The busy lock is an in-memory map per process (`run-state.ts`), so the two processes could run agent loops on the same session at once.
  - Events go through an in-process `EventEmitter` (`…/packages/opencode/src/bus/global.ts`; `…/packages/opencode/src/event-v2-bridge.ts`). I found nothing that carries them between processes, so the TUI would likely not see the new messages live.

## 5. Plugins and hooks

- **Hooks** (`…/packages/plugin/src/index.ts` ~L224-334):
  - `event`, which receives all bus events, including `session.idle` and `session.status`
  - `chat.message`, `chat.params`, `chat.headers`
  - `permission.ask`
  - `command.execute.before`
  - `tool.execute.before` and `tool.execute.after`
  - `shell.env`
  - `tool.definition`
  - `experimental.chat.messages.transform`, `experimental.chat.system.transform`, `experimental.session.compacting`, `experimental.compaction.autocontinue`, `experimental.text.complete`
  - `tool`, `auth`, `provider`, `config`, `dispose`
- **Plugin input** is `{client, project, directory, worktree, serverUrl, $, experimental_workspace}` (~L56-65). `client` is a full SDK client wired to the same process's server: `Server.url` if one is listening, otherwise in-process fetch (`…/packages/opencode/src/plugin/index.ts` ~L145-150).
- **So a plugin can act as a trigger.** For example, it can call `setTimeout`, then `client.session.promptAsync({path:{id}, body:{parts:[…]}})`, or watch a child process and prompt on exit. Because it runs in the owning process, it shares the busy/join behaviour and the TUI sees the messages live. That's inferred from the code.
- **Examples:** the docs' only `event` example sends an OS notification on `session.idle` (`…/packages/web/src/content/docs/plugins.mdx` ~L222-233). There's no official example of a plugin prompting on a timer. `task.ts` `inject` is the in-tree precedent for injecting a message and waking the model.

## 6. Does the TUI run a reachable server?

- **By default, no.** The TUI talks to its worker over RPC with `http://opencode.internal`. It only listens on a real port if you pass `--port`, `--hostname` or `--mdns` (`…/packages/opencode/src/cli/cmd/tui.ts` ~L234-250; `…/packages/opencode/src/cli/tui/worker.ts` ~L54-57). The config key `server.port` does not make it listen, because the TUI resolves network options with `resolveNetworkOptionsNoConfig(args)` and no config.
- **`--port 0` (the default)** tries 4096 first, then a random port (`…/packages/opencode/src/server/server.ts` ~L117-121). The docs say "When you start the TUI it randomly assigns a port" (`server.mdx` ~L66), which doesn't match the code.
- **Discovering the port:** I found no port file. The options are:
  - Pass `--port N` yourself.
  - Use `--mdns`, which advertises `opencode-<port>` as `_http` under `opencode.local` (`…/packages/opencode/src/server/mdns.ts` ~L12-19).
  - Scan the process table.
- **Auth:** the server uses `OPENCODE_SERVER_PASSWORD` / `OPENCODE_SERVER_USERNAME` (`…/packages/opencode/src/server/auth.ts`).
- **Driving the TUI directly:** `/tui/append-prompt` and `/tui/submit-prompt` can type into and submit the TUI prompt (`server.mdx` ~L253-263).

## 7. Relevant releases (GitHub releases API, queried 2026-09-22)

- v1.14.49/50: busy-session errors returned over HTTP for prompt and shell work.
- v1.14.51: experimental background subagents added.
- v1.15.11: "background agents now push updates without polling"; the shell tool now advertises the configured timeout to the model.
- v1.16.2: running subagents can be sent to the background.
- v1.17.9: follow-up messages no longer wrapped in a steering reminder.
- v1.17.12: "Wake embedded session execution after new prompts."
- v1.3.4 and v1.2.16: queued follow-ups in the app.
- Nothing relevant in v1.18.28 through v1.18.32.
- There's no CHANGELOG file in the repo.

## Unverified

- Whether a `nohup … &` child actually outlives the tool call and OpenCode's exit (inferred from spawner code, not run).
- What happens when a TUI and `run --session` hit the same session from separate processes: concurrent loops and no live update in the TUI (inferred, not tested).
- Whether the v2 `/api/session/:id/prompt` with `steer`/`queue` works on sessions the default TUI shows.
- The plugin timer calling `promptAsync`: plausible from code, not tested.
- The docs URLs were read from the repo's `.mdx` at the tag, not fetched live from opencode.ai today.
