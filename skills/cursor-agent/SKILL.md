---
name: cursor-agent
description: Run Cursor Agent CLI as an independent coding agent for implementation, investigation, planning, or review in a local workspace. Use when asked to delegate work to Cursor, get a second model pass, automate cursor-agent in headless mode, capture a Cursor session ID, or resume and continue an earlier Cursor chat.
---

# Cursor Agent

Run `cursor-agent` from the intended workspace, give it a concrete outcome, monitor it at the task's time scale, and preserve its session ID whenever follow-up work is likely.

Treat explicit user invocation of this skill as authorization to use Cursor Agent to complete the requested task, including allowing Cursor Agent to read the necessary local files in the intended workspace. Do not extend that authorization to unrelated tasks, broader filesystem access, or destructive or external actions not otherwise authorized.

## Check the CLI and authentication

Treat the installed CLI help as authoritative because Cursor Agent is evolving:

```bash
cursor-agent --version
cursor-agent --help
cursor-agent status --format json
```

If authentication is missing, ask the user to run `cursor-agent login`, or use `CURSOR_API_KEY` when the user has already arranged it. Never print or embed an API key in a command.

Use `cursor-agent models` (or `cursor-agent --list-models`) when the user requests a particular model. Otherwise omit `--model` and use the account default rather than hard-coding a model name.

## Choose the execution mode

Run from the repository checkout or pass `--workspace /absolute/path`.

For an interactive task:

```bash
cursor-agent "Inspect the repository and implement TASK. Verify the result."
```

For a headless task with structured progress:

```bash
cursor-agent -p --output-format stream-json --auto-review --trust \
  "Inspect the repository and implement TASK. Verify the result."
```

Every `-p` run requires `--trust`, including `--mode plan` and `--mode ask`. Without it the run aborts immediately with `Workspace Trust Required` and does nothing, because there is no interactive prompt to answer. Confirm that the current or specified workspace is the intended one, then pass the flag; the judgment call is which workspace, not whether to include it.

`--auto-review` auto-runs tool calls its classifier deems safe and prompts for the rest. In non-interactive `-p` mode there is no one to answer that prompt, so a run that needs approval can stall. For genuinely unattended work that must run any command, add `--force` (see below) rather than relying on `--auto-review` alone.

Use the least authority suitable for the task:

- Add `--mode plan` for read-only analysis and planning.
- Add `--mode ask` for read-only questions.
- Prefer `--auto-review` for ordinary agent work.
- Add `--force` only when the user authorized changes and unattended command execution is necessary.
- Use `--sandbox enabled` when the task can run within Cursor's sandbox.

State constraints directly in the prompt: permitted edits, required checks, expected output, and forbidden side effects. For review-only work, explicitly prohibit edits, pushes, merges, and unrelated external actions.

## Capture the session ID

Do not rely on "latest session" when later continuation matters. Return the ID to the caller and persist it in the caller's chosen task state.

### Allocate an ID before starting

Prefer this pattern when the ID must be known even if the first turn is interrupted:

```bash
cursor_chat_id="$(cursor-agent create-chat)"
test -n "$cursor_chat_id"

cursor-agent -p --output-format stream-json --auto-review --trust \
  --resume="$cursor_chat_id" \
  "Inspect the repository and complete TASK. Verify the result."
```

### Capture an ID from a completed run

Use JSON when live progress is unnecessary:

```bash
cursor_run_json="$(cursor-agent -p --output-format json --auto-review --trust \
  "Inspect the repository and complete TASK. Verify the result.")"
cursor_chat_id="$(printf '%s\n' "$cursor_run_json" | jq -er '.session_id')"
printf '%s\n' "$cursor_run_json" | jq -r '.result'
```

Only parse the response after confirming that `cursor-agent` exited successfully. The final JSON object contains `session_id`.

### Capture an ID from a streamed run

Use NDJSON when progress must remain visible:

```bash
cursor_run_log="$(mktemp -t cursor-agent.XXXXXX.ndjson)"
set -o pipefail
cursor-agent -p --output-format stream-json --auto-review --trust \
  "Inspect the repository and complete TASK. Verify the result." \
  | tee "$cursor_run_log"

cursor_chat_id="$(jq -ser \
  'map(select(.type == "system" and .subtype == "init"))[0].session_id' \
  "$cursor_run_log")"
```

The initialization event emits `session_id` near the start, and the terminal result event repeats it after success. Treat the NDJSON log as potentially sensitive because it can contain prompts, file contents, and tool arguments.

## Resume a session

Resume from the same workspace used to create the chat. Cursor chat discovery is workspace-scoped.

Continue a specific session non-interactively:

```bash
cursor-agent -p --output-format stream-json --auto-review --trust \
  --resume="$cursor_chat_id" \
  "Continue from the prior work. Address FOLLOW_UP and verify the result."
```

Use these interactive recovery commands when an ID was not recorded:

```bash
cursor-agent ls
cursor-agent resume
```

Use `cursor-agent -p --continue "FOLLOW_UP"` only when continuing the most recent session is unambiguous. Prefer `--resume="$cursor_chat_id"` for automation.

Keep using the same session for refinements that depend on prior context. Start a new chat when the task, repository, or trust boundary changes.

## Monitor and verify

Run a long invocation in the background and poll its output (or the NDJSON log) at intervals appropriate to the task; do not restart it merely because it is quiet. Check at least often enough to surface approval prompts or failures promptly. When running from an interactive terminal instead, keep the invocation attached and inspect new output on the same cadence.

On completion:

1. Confirm the process exit status and, for structured output, a successful terminal result event.
2. Inspect the resulting files or Git diff independently.
3. Run task-appropriate tests or checks if Cursor did not already do so.
4. Report the outcome, verification, and session ID.

### Sandbox and network failures

Distinguish an auth failure from a network-denied sandbox before reporting one as the other. When a `cursor-agent` (or `gh`) command fails because sandbox networking is unavailable, rerun it with the environment's required network escalation rather than treating the failure as bad credentials.
