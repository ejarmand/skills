The evidence mostly supports your impression, with one exception. Codex 0.156.0 has no timer or background-process trigger that starts a new turn in a session. It does have an external-message path that starts one: `codex queue` / `thread/queue/add`. It is a durable SQLite queue that whichever Codex process has the thread loaded checks about every 10 seconds, and it only delivers when the thread is idle. Everything below comes from the source at the tag. The only docs page I fetched, besides the automations and hooks pages cited in 2 and 6, was the CLI command reference, which has nothing on `codex queue`, the daemon or `codex agents`.

Links are shortened: `B` = `https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs`.

## 1. Background shell jobs (unified_exec)
- **Tools:** `exec_command{cmd, workdir, tty, yield_time_ms (250–30000, default 10000), max_output_tokens, shell?, login?}` returns output, or a session ID if the command is still running. `write_stdin{session_id, chars, yield_time_ms, max_output_tokens}`; empty `chars` means "poll". Empty polls wait 5,000 ms up to `background_terminal_max_timeout` (default 300,000 ms, i.e. 5 min). (B/core/src/tools/handlers/shell_spec.rs ~L24-150; B/core/src/unified_exec/mod.rs ~L73-82; B/core/src/unified_exec/process_manager.rs ~L1015-1024; B/config/src/config_toml.rs ~L331)
- **Polling only, no wake-up:** a poll returns early when the process exits (B/core/src/unified_exec/process_manager.rs ~L1576-1660). On exit, `spawn_exit_watcher` sends an `ExecCommandEnd` event to clients (B/core/src/unified_exec/async_watcher.rs ~L163-247). That event does not go into model history and does not start a turn. I found no code that injects an exit notice into the model's context. If the thread is idle when the process exits, the model learns of it only when it next polls.
- **Turn end:** processes survive. The process is stored "so interrupting the turn cannot drop the last Arc and terminate the background process" (process_manager.rs ~L598). Tests: `unified_exec_keeps_long_running_session_after_turn_end` and `unified_exec_interrupt_preserves_long_running_session` (B/core/tests/suite/unified_exec.rs ~L2848, ~L2949).
- **Session shutdown:** `shutdown_session_runtime` calls `terminate_all_processes()` (B/core/src/session/handlers.rs ~L285-303). `codex exec` always uses an in-process app-server and shuts it down on exit (B/exec/src/lib.rs ~L973, ~L1123-1129, ~L1305), so its processes die with it (inferred from the shutdown path). The same applies to TUI exit with an embedded server. On the daemon, a thread unloads after `thread_unload_delay_secs` (default 60) with no subscribers and no activity (config_toml.rs ~L334). I infer, but did not trace, that unloading goes through the same shutdown.
- **Limits:** soft cap `MAX_UNIFIED_EXEC_PROCESSES = 64`. Pruning is least-recently-used: exited processes go first, and the 8 most recent are protected (process_manager.rs ~L1725-1790). Output buffer is 1 MiB. There is no wall-clock timeout on background processes.
- **User controls:** TUI `/ps` ("list background terminals") and `/stop` or `/clean` (B/tui/src/slash_command.rs ~L74-128). App-server: `thread/backgroundTerminals/{list,terminate,clean}` (B/app-server-protocol/src/protocol/common.rs ~L746-758).

## 2. Timers and related features
- **`sleep_tool` is the tool `clock.sleep{duration_ms}`,** 1 ms to 12 h (`MAX_SLEEP_DURATION_MS`). It blocks inside the current turn. It "ends early when new input arrives for the active turn" (a steer) and returns "Sleep interrupted by new input." (B/core/src/tools/handlers/sleep.rs ~L28, ~L51, ~L110-150)
  - It only exists during a turn and cannot wake an idle thread.
  - It is registered only if the model catalog lists `clock` in `experimental_supported_tools`, or if `current_time_reminder.sleep_tool=true`, or with `features.sleep_tool.mode="always_on"` (B/core/src/tools/spec_plan.rs ~L1176-1192).
  - In the local `~/.codex/models_cache.json`, only the gpt-6-astra/sol/luna models list `clock`. The gpt-5.6-* models do not, so they don't get the tool by default.
- **`current_time_reminder`** (under development): adds the current time to model context before inference, on an interval. It never starts a turn (B/features/src/feature_configs.rs ~L382-415).
- **`goals`** (stable): when the thread goes idle, `on_thread_idle` → `continue_if_idle` auto-continues an active goal. It is triggered by idle, not by a timer (B/ext/goal/src/extension.rs ~L180-192).
- **`send_message_to_user_async`** (under development): a model-to-user message that doesn't end the turn; "any reply arrives asynchronously as a new user message" (B/core/src/tools/handlers/send_message_to_user_async.rs ~L46). It is not an external trigger.
- **Other flags:**
  - `agent_message_board` (under development): shared discussion tools for a multi_agent_v2 tree only (B/core/src/agent_message_board.rs ~L33-47).
  - `deferred_executor`: "Allow turns to start while selected executors are still starting."
  - `prevent_idle_sleep`: keeps the OS awake during a turn.
  - `in_app_local_automation`: "Allow desktop apps to run local automations", a gate set by admin requirements with no code in the CLI.
  - Sources for all four: B/features/src/lib.rs ~L174, ~L209, ~L265, ~L366.
- **Multi-agent `wait_agent`:** waits on subagents only, up to 1 h (B/core/src/config/mod.rs ~L253-259; B/core/src/tools/handlers/multi_agents_spec.rs ~L273).
- **Scheduled automations** exist in the ChatGPT desktop app (minute/daily/weekly schedules, RRULE, and can "return to that chat on a schedule") and on web (plus Gmail/Slack/GitHub event triggers). The docs say "Codex CLI doesn't provide the Scheduled management interface", and local tasks need the app running (https://learn.chatgpt.com/docs/automations?surface=app, which developers.openai.com/codex/app/automations redirects to). The CLI has no cron or schedule.

## 3. `codex queue`, daemon, agents
- **Transport:** `codex queue` sends `thread/queue/add` through the running shared daemon if there is one, otherwise through an embedded app-server. It refuses `--no-daemon`. It also errors if config overrides force an embedded server while a daemon is running (B/tui/src/session_queue_commands.rs ~L27-55, ~L112-127; daemon choice in B/tui/src/session_archive_commands.rs ~L251-271).
- **Storage:** the message is persisted to a SQLite queue (`~/.codex/queue_1.sqlite` exists locally). Unloaded spawned subagents, ephemeral threads and archived threads are rejected (B/app-server/src/request_processors/thread_queue_processor.rs ~L78-96, ~L247-300).
- **Delivery:** every app-server with a local thread store installs the queue service, including the TUI's embedded server, `exec`'s in-process server and the daemon (B/app-server/src/message_processor.rs ~L300-330; B/app-server/src/extensions.rs ~L71). The service checks SQLite every 10 s for other-process writes (B/ext/queue/src/service.rs ~L89-245). Cases:
  - **Thread idle:** `start_turn_if_idle` starts a new turn with `turn_trigger:"queue"` (service.rs ~L405-470).
  - **Thread running:** nothing is steered in. The message waits for the turn to complete, then `on_thread_idle` dispatches it.
  - **Last turn was interrupted:** the queue pauses until a later idle event with cause "Completed" (service.rs ~L549-566; test `interrupted_turns_pause_queued_messages_but_failed_turns_drain_them`, B/ext/queue/tests/queue_service.rs ~L480).
  - **Thread loaded in a separate TUI or exec process:** that process picks the message up within about 10 s via SQLite. This matches 0.149.0 #39034 "Dispatch queued messages written by other processes".
  - **Not loaded anywhere:** the message persists and is dispatched when some process resumes the thread (resumed/created thread IDs are rescanned from revision 0).
- **`codex agents`:** browses sessions on the shared daemon (`--help`).
- **`daemon_auto_start`** (experimental, off by default): "Use the shared local server for new, resumed, and forked sessions" (B/features/src/lib.rs ~L938).
- **TUI routing:** the TUI uses the daemon socket whenever one is running, unless you pass `--no-daemon`, config overrides, or `--remote` (B/tui/src/lib.rs ~L968-997).
- **`codex remote-control`:** start/stop/pair for the daemon with remote control enabled.

## 4. App-server protocol
- **Methods:**
  - `thread/start`, `thread/resume` (attaches to an already-loaded or even running thread), `thread/fork`, `thread/unsubscribe`, `thread/loaded/list`.
  - `turn/start`: steers into the active turn if one is running (`start_or_steer_turn`) and accepts an optional `turnTrigger` (B/app-server/src/request_processors/turn_processor.rs ~L650-672; B/app-server-protocol/src/protocol/v2/turn.rs ~L176-179).
  - `turn/steer` (requires `expectedTurnId`), `turn/interrupt`.
  - `thread/queue/{add,list,update,delete,reorder,start}` (all experimental); `thread/inject_items` (raw Responses items appended to history, with no turn started).
  - `thread/shellCommand`, `thread/backgroundTerminals/*`.
  - Source: B/app-server-protocol/src/protocol/common.rs ~L559-758, ~L872, ~L1040-1058.
- **Notifications:** `turn/started`, `turn/completed`, `thread/status/changed`, `thread/queue/changed`, `item/started`, `item/completed` (the model's background command exit shows up as `item/completed` for commandExecution), `item/commandExecution/terminalInteraction`, `hook/started`, `hook/completed`. `process/exited` exists, but only for client-spawned `process/spawn` processes, not for the model's (common.rs ~L1911-1963; B/app-server/src/request_processors/process_exec_processor.rs ~L598).
- **Multiple clients:** yes. The daemon tracks subscribed connections per thread and unloads only when there are no subscribers (B/app-server/src/thread_state.rs ~L417, ~L586).

## 5. `codex exec resume` against a live session
It conflicts rather than forking or appending to the rollout. Resume takes an exclusive file lock at `~/.codex/thread-writer-locks/<id>.lock`. If another process holds it, the error is "thread <id> already has an active writer" (`ThreadStoreError::Conflict`) (B/rollout/src/writer_lock.rs ~L43-75; B/thread-store/src/local/live_writer.rs ~L40-46; B/thread-store/src/local/mod.rs ~L332-345). The TUI falls back to read-only viewing in that case (B/tui/src/app/startup.rs ~L499). `exec` has no such fallback; I infer it just errors. `exec` is always in-process and never routes through the daemon, so to inject into a live daemon thread you use `codex queue` or app-server methods.

## 6. Hooks
- **Events:** PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact, SessionStart, SessionEnd, UserPromptSubmit, SubagentStart, SubagentStop, Stop, Interrupt (B/protocol/src/protocol.rs ~L1579). There is no Notification event.
- **Stop can continue the turn:** `decision:"block"` plus a `reason` is recorded as a continuation prompt and the same turn continues, with `stop_hook_active=true` on the next Stop (B/core/src/session/turn.rs ~L646-680). The docs agree (https://learn.chatgpt.com/docs/hooks, redirected from developers.openai.com/codex/hooks).
- **Async hooks:** command hooks accept `"async": true` (except SessionEnd) (B/hooks/src/engine/discovery.rs ~L531). Their output is drained only at safe points: the next sampling in the active turn, or the start of the next turn (B/core/src/hook_runtime.rs ~L767-800). Docs: "Finishing a background hook doesn't start a new turn." Default hook timeout is 600 s, with no maximum except SessionEnd/Interrupt, which are capped at 3 s (discovery.rs ~L742-763).
- **Legacy `notify`:** runs a program with an `agent-turn-complete` JSON argument (`thread-id`, `turn-id`, `cwd`, `client`, `input-messages`, `last-assistant-message`) (B/hooks/src/legacy_notify.rs ~L13-40). It is outbound only.

## 7. Release notes
The repo's CHANGELOG.md only points to the GitHub releases page.
- 0.140.0: #26041 app-server background terminal APIs.
- 0.141.0: #28429 interruptible sleep tool.
- 0.143.0: `remote-control pair`.
- 0.146.0: #34969 sleep tool kept outside code mode.
- 0.149.0: `codex queue` (#39092); "Queued messages now wake idle sessions reliably" (#39034, #39385).
- 0.150.0: #40436 managed gate for in-app local automation.
- 0.152.0: #41210 clock tools from model metadata; #41243 sleep-tool gating.
- 0.153.0: TUI shows input sent to background terminals.
- 0.155.0: daemon update schedules; threads and active goals recover after daemon restart.
- 0.156.0: `/daemon`, `--no-daemon` (#46088), opt-in daemon auto-start (#46117), "Continue interrupted work after managed daemon restarts" (#45820).

## Verdict on your impression
- **Wait tools are mostly in-turn timers:** confirmed. `clock.sleep` blocks the current turn, and `write_stdin` polls are capped at 5 min by default. Neither wakes an idle thread, and a process exit never wakes the model.
- **External message injection exists natively:** `codex queue --thread <id> --message ...` works across processes. It only starts a turn when the thread is idle, not interrupted, and loaded somewhere, with up to about 10 s latency.
- **What your tool would add:** the trigger itself (a process-exit watcher or a timer) that calls `codex queue`. Codex has no CLI-side scheduler.

## Unverified
- That daemon thread-unload terminates unified-exec processes; I did not trace the unload path.
- That `codex exec resume` against a live thread errors rather than falling back; I did not check how exec handles the error.
- How the TUI renders a queue-started turn in a session that is attached but idle.
- End-to-end runtime behavior of `codex queue`; I read code and tests only and ran no sessions.
- That gpt-5.6 models lack `clock.sleep`; this rests only on the local models cache.
