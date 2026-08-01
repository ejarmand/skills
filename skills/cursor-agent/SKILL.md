---
name: cursor-agent
description: Run Cursor Agent CLI as an independent coding agent for implementation, investigation, planning, or review in a local workspace. Use when asked to delegate work to Cursor, automate cursor-agent in headless mode, capture a Cursor session ID, or resume and continue an earlier Cursor chat.
---

# Cursor Agent

Run `cursor-agent` from the intended workspace, give it a concrete outcome, monitor it at the task's time scale, and preserve its session ID whenever follow-up work is likely.

## Check the CLI and authentication

Treat the installed CLI help as authoritative because Cursor Agent is evolving:

```bash
cursor-agent --version
cursor-agent --help
cursor-agent status --format json
```

If authentication is missing, ask the user to run `cursor-agent login`, or use `CURSOR_API_KEY` when the user has already arranged it. Never print or embed an API key in a command.

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

The initialization event emits `session_id` near the start, and the terminal result event repeats it after success.

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

## Monitor and verify

Run a long invocation in the background and poll the NDJSON log often enough to surface approval prompts promptly.

On completion:

1. Confirm the process exit status and, for structured output, a successful terminal result event.
2. Inspect the resulting files or Git diff independently.
3. Run task-appropriate tests or checks if Cursor did not already do so.
4. Report the outcome, verification, and session ID.

A `cursor-agent` or `gh` failure with transport errors naming the URL is the sandbox denying network, not bad credentials (`/cross-provider-agent` doctrine); rerun with the environment's required network escalation.

## Profiled dispatch: github-pr-reviewer

Cursor takes permission and sandbox policy only from configuration files, so profiled dispatch runs through the skill's transactional runner, which stages the profile for exactly one invocation and restores the workspace byte-for-byte:

```bash
/absolute/path/to/cursor-agent/scripts/run-profiled.sh \
  --workspace /absolute/path/to/workspace \
  --profile github-pr-reviewer \
  -- -p --output-format json --trust "REVIEW_TASK"
```

The runner stages the profile under an isolated `CURSOR_CONFIG_DIR` and workspace `.cursor/` snapshot, supervises the child, and restores everything byte-for-byte (mechanics in the script header). Setup failure prevents launch; cleanup failure is failure even when the child succeeded; a workspace lock rejects concurrent runners, so parallel dispatches need separate workspaces; after an untrappable crash, the next invocation recovers the stale transaction.

Run profiled dispatches with plain `-p --trust` (deny-unless-allowed) and never `--force`, so the profile's allowlist is the whole command surface. The profile pairs multi-word `Shell(...)` allows — live-verified but undocumented — with a `sandbox.json` GitHub-only network allowlist as defense in depth.
