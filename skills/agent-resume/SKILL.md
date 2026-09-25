---
name: agent-resume
description: Resume a Claude Code or Codex session later, from outside it. Use to get a status message when a long job finishes, or to wake a session after a delay ("in 3 hours, look at new PRs") even if the session has closed by then.
---

# Agent resume

`agent-resume` sends a message into a session when a trigger fires. The
trigger runs as a `systemd-run --user` unit, so it outlives your turn and your
process, and logout too if lingering is on (`loginctl enable-linger`), but not
a reboot. `scripts/link-skills.sh` puts it on
PATH; it also lives at `bin/agent-resume` in this skill.

```bash
# Status update when a job finishes: the command runs inside the unit.
agent-resume codex --message "address any errors" -- make test

# Status update when a process you already started exits, e.g. a background
# Bash job that returned a PID and an output file.
agent-resume claude --pid 4242 --log /tmp/job.log --message "job finished, check the log"

# Timed resume; the session may be closed by then.
agent-resume claude --time 3h --message "resume and look at new PRs on the repo"

agent-resume list
agent-resume cancel <trigger-id>
```

For a command trigger (a command after `--`), the completion message is your
`--message` plus the exit status, the last 40 log lines, and the log path
under `~/.local/state/agent-resume/`. The command gets your environment and
working directory. `--time` takes a systemd time span (`90min`, `3h`, `2d`).
`--dry-run` prints the systemd and delivery commands without running
anything.

A `--pid` process is not the trigger's child, so its exit status cannot be
read: the message says only that it ended, plus the last 40 lines of `--log`.
If the log's last line is `exit=N`, the message reports status N, so launch
jobs you may watch this way as `cmd; echo exit=$? >> log` and pass the PID of
the shell that runs the `echo`.

## Session IDs

The session ID defaults to your own: Claude Code exports
`CLAUDE_CODE_SESSION_ID` and Codex exports `CODEX_THREAD_ID` to the shell.
Pass another ID as the second argument to message a different session.

The message reaches a live session directly and resumes a closed one with the
permissions it last ran under. When no permissions are recorded, it resumes in
auto-approve mode (`--permission-mode auto` for Claude, `--approve-for-me` for
Codex), which still runs an automatic safety check on actions.

## Claude prerequisite

A bypass-permissions Claude session holds messages from agent-resume for
approval unless `~/.claude/settings.json` has `"crossSessionInbound":
"accept"`. `scripts/link-skills.sh` offers to set it, and `agent-resume`
warns when a Claude trigger is scheduled without it.
