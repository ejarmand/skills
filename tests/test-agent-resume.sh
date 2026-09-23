#!/usr/bin/env bash
# Hermetic tests for skills/agent-resume/bin/agent-resume. A temporary HOME
# holds fixture transcripts, rollouts and session registry entries; fake
# systemd-run, systemctl, claude and codex on PATH record their calls. The fake
# systemd-run runs the unit's command at once instead of scheduling it, from
# $HOME as a user unit does, records the command's exit status in
# $CALLS/fire.status, and exits 0 like the real one.
set -u -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
CLI="$REPO/skills/agent-resume/bin/agent-resume"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-agent-resume.XXXXXX")" || exit 1
server_pid=
trap '[ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; rm -rf "$TMP"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }
check() { # check <description> <command...>
  local what="$1"; shift
  if "$@"; then pass "$what"; else fail "$what"; fi
}

FAKE_BIN="$TMP/bin"
CALLS="$TMP/calls"
FAKE_HOME="$TMP/home"
WS="$TMP/workspace"
mkdir -p "$FAKE_BIN" "$CALLS" "$FAKE_HOME" "$WS" || exit 1

# Each fake records its argv (one per line), its cwd, and its last argument.
for name in claude codex systemctl; do
  cat > "$FAKE_BIN/$name" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$CALLS/$name"
pwd > "\$CALLS/$name.cwd"
printf '%s' "\${@: -1}" > "\$CALLS/$name.last"
if [ "$name" = codex ] && [ "\$1" = exec ]; then
  [ -n "\${CODEX_EXEC_OUTPUT:-}" ] && echo "\$CODEX_EXEC_OUTPUT" >&2
  exit "\${CODEX_EXEC_EXIT:-0}"
fi
if [ "$name" = systemctl ] && [ "\$2" = list-units ]; then
  printf '%s\n' "\${FAKE_UNITS:-}"
fi
exit 0
FAKE
done
cat > "$FAKE_BIN/systemd-run" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS/systemd-run"
[ "${FAKE_SYSTEMD_EXEC:-1}" = 1 ] || exit 0
log=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --property=StandardOutput=append:*) log="${1#--property=StandardOutput=append:}" ;;
    --) shift; break ;;
  esac
  shift
done
cd "$HOME" || exit 1
"$@" >> "$log" 2>&1
echo "$?" > "$CALLS/fire.status"
exit 0
FAKE
chmod +x "$FAKE_BIN"/* || exit 1

ar() { # ar <command...>: run in $AR_CWD (default $WS) with the fake HOME and PATH
  (cd "${AR_CWD:-$WS}" && env -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u CODEX_HOME \
    HOME="$FAKE_HOME" PATH="$FAKE_BIN:$PATH" CALLS="$CALLS" "$@")
}
reset_calls() { rm -f "$CALLS"/*; }
called() { [ -f "$CALLS/$1" ] && grep -Fq -- "$2" "$CALLS/$1"; }
not_called() { [ ! -f "$CALLS/$1" ]; }
contains() { [[ "$1" == *"$2"* ]]; }

SID=11111111-2222-3333-4444-555555555555

# --- argument parsing and session-ID defaulting ------------------------------
out="$(ar "$CLI" claude --time 3h --message hi 2>&1)"
check "claude without a session names CLAUDE_CODE_SESSION_ID" \
  grep -Fq 'CLAUDE_CODE_SESSION_ID is not set' <<< "$out"
out="$(ar "$CLI" codex --time 3h --message hi 2>&1)"
check "codex without a session names CODEX_THREAD_ID" \
  grep -Fq 'CODEX_THREAD_ID is not set' <<< "$out"
! ar "$CLI" codex "$SID" --message hi --dry-run >/dev/null 2>&1 \
  && pass "neither --time nor a command is refused" || fail "missing trigger accepted"
! ar "$CLI" codex "$SID" --time 1h --message hi --dry-run -- true >/dev/null 2>&1 \
  && pass "--time plus a command is refused" || fail "both triggers accepted"
! ar "$CLI" codex "$SID" --time 1h --dry-run >/dev/null 2>&1 \
  && pass "--message is required" || fail "missing --message accepted"
! ar "$CLI" list -- true >/dev/null 2>&1 \
  && pass "list refuses a command" || fail "list accepted a command"

reset_calls
out="$(ar env CODEX_THREAD_ID="$SID" "$CLI" codex --time 90min --message 'look at PRs' --dry-run 2>&1)"
check "session defaults from CODEX_THREAD_ID" grep -Fq "resume $SID" <<< "$out"
out="$(ar env CLAUDE_CODE_SESSION_ID="$SID" "$CLI" claude --time 3h --message 'look at PRs' --dry-run 2>&1)"
check "session defaults from CLAUDE_CODE_SESSION_ID" grep -Fq -- "--resume $SID" <<< "$out"

# --- dry-run output ----------------------------------------------------------
out="$(ar "$CLI" claude "$SID" --time 3h --message 'look at PRs' --dry-run 2>&1)"
check "timer dry-run prints a systemd-run --user timer" \
  grep -Eq "^systemd-run --user --unit=agent-resume-[0-9a-f]{8} .*--on-active=3h -- .*_fire agent-resume-" <<< "$out"
check "dry-run does not pin the unit's working directory" \
  bash -c '! grep -Fq -- --working-directory <<< "$1"' _ "$out"
check "dry-run logs to the state directory" \
  grep -Fq -- "StandardOutput=append:$FAKE_HOME/.local/state/agent-resume/agent-resume-" <<< "$out"
check "claude dry-run reports no live socket" grep -Fq "no live socket for $SID" <<< "$out"
check "claude dry-run shows the --bg resume fallback" \
  grep -Fq "claude --resume $SID --bg --permission-mode auto -- 'look at PRs'" <<< "$out"
check "claude trigger warns about crossSessionInbound" grep -Fq 'crossSessionInbound is not "accept"' <<< "$out"
check "dry-run runs nothing" not_called systemd-run
check "dry-run writes no state" test ! -e "$FAKE_HOME/.local/state"

out="$(ar "$CLI" codex "$SID" --message 'address any errors' --dry-run -- make test 2>&1)"
check "command dry-run has no timer" bash -c '! grep -Fq -- --on-active <<< "$1"' _ "$out"
check "codex dry-run shows exec resume" grep -Fq "codex exec --skip-git-repo-check" <<< "$out"
check "codex dry-run shows the queue fallback" \
  grep -Fq "codex queue --thread $SID '--message=address any errors" <<< "$out"
check "command dry-run shows the completion message shape" \
  grep -Fq 'agent-resume: `make test` exited with status <status>.' <<< "$out"
check "codex trigger does not warn about crossSessionInbound" \
  bash -c '! grep -Fq crossSessionInbound <<< "$1"' _ "$out"

mkdir -p "$FAKE_HOME/.claude" || exit 1
echo '{"crossSessionInbound": "accept"}' > "$FAKE_HOME/.claude/settings.json"
out="$(ar "$CLI" claude "$SID" --time 3h --message x --dry-run 2>&1)"
check "no warning once crossSessionInbound is accept" \
  bash -c '! grep -Fq crossSessionInbound <<< "$1"' _ "$out"
echo '["crossSessionInbound"]' > "$FAKE_HOME/.claude/settings.json"
out="$(ar "$CLI" claude "$SID" --time 3h --message x --dry-run 2>&1)"
check "a non-object settings file warns instead of failing" \
  grep -Fq 'crossSessionInbound is not "accept"' <<< "$out"
echo '{"crossSessionInbound": "accept"}' > "$FAKE_HOME/.claude/settings.json"

# --- permission replay -------------------------------------------------------
transcript() { # transcript <mode-json-or-empty>
  mkdir -p "$FAKE_HOME/.claude/projects/-ws" || exit 1
  local mode=""
  [ -n "$1" ] && mode=",\"permissionMode\":\"$1\""
  printf '{"type":"user","cwd":"%s","sessionId":"%s"%s}\n{"type":"assistant","cwd":"%s"}\n' \
    "$WS" "$SID" "$mode" "$WS" > "$FAKE_HOME/.claude/projects/-ws/$SID.jsonl"
}
claude_plan() { ar "$CLI" claude "$SID" --time 1h --message m --dry-run 2>/dev/null | grep '^fallback:'; }

transcript bypassPermissions
check "bypassPermissions replays --dangerously-skip-permissions" \
  grep -Fq -- "--bg --dangerously-skip-permissions -- m" <<< "$(claude_plan)"
transcript acceptEdits
check "acceptEdits replays --permission-mode acceptEdits" \
  grep -Fq -- "--bg --permission-mode acceptEdits -- m" <<< "$(claude_plan)"
check "claude resume runs in the transcript cwd" grep -Fq "(cd $WS && claude" <<< "$(claude_plan)"
transcript default
check "default mode adds no permission flag" grep -Fq -- "--bg -- m)" <<< "$(claude_plan)"
transcript ""
check "transcript without a mode falls back to auto mode" \
  grep -Fq -- "--bg --permission-mode auto -- m" <<< "$(claude_plan)"
transcript bypassPermissions
printf '%s\n' '{"permissionMode":["plan"],"cwd":{"dir":"/"}}' \
  >> "$FAKE_HOME/.claude/projects/-ws/$SID.jsonl"
check "mistyped last transcript fields fall back to auto mode and no cwd" \
  grep -Fq -- "(cd . && claude --resume $SID --bg --permission-mode auto -- m)" <<< "$(claude_plan)"

rollout() { # rollout <approval-json> <sandbox-json> [codex-home]
  local day="${3:-$FAKE_HOME/.codex}/sessions/2026/09/22"
  mkdir -p "$day" || exit 1
  printf '%s\n' \
    "{\"type\":\"session_meta\",\"payload\":{\"id\":\"$SID\"}}" \
    "{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"/first\",\"approval_policy\":\"untrusted\",\"sandbox_policy\":{\"type\":\"read-only\"}}}" \
    "{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"$WS\",\"approval_policy\":$1,\"sandbox_policy\":$2}}" \
    > "$day/rollout-2026-09-22T00-00-00-$SID.jsonl"
}
codex_plan() { ar "$CLI" codex "$SID" --time 1h --message m --dry-run 2>/dev/null | grep '^deliver:'; }

rollout '"never"' '{"type":"danger-full-access"}'
check "never + danger-full-access replays the bypass flag" \
  grep -Fq -- "--skip-git-repo-check --dangerously-bypass-approvals-and-sandbox resume $SID -- m" <<< "$(codex_plan)"
rollout '"on-request"' '{"type":"workspace-write","network_access":true}'
check "last turn_context replays -s and approval_policy" \
  grep -Fq -- "-s workspace-write -c 'approval_policy=\"on-request\"' -c sandbox_workspace_write.network_access=true resume" <<< "$(codex_plan)"
check "codex resume runs in the turn_context cwd" grep -Fq "(cd $WS && codex" <<< "$(codex_plan)"
rollout '"never"' '{"type":"read-only"}'
check "never + read-only keeps the sandbox" \
  grep -Fq -- "-s read-only -c 'approval_policy=\"never\"' resume" <<< "$(codex_plan)"
rollout '{"granular":{}}' '{"type":"read-only"}'
check "unreadable approval policy falls back to --approve-for-me" \
  grep -Fq -- "--skip-git-repo-check --approve-for-me resume" <<< "$(codex_plan)"
rollout '"on-request"' '{"type":"external-sandbox"}'
check "unknown sandbox type falls back to --approve-for-me" \
  grep -Fq -- "--skip-git-repo-check --approve-for-me resume" <<< "$(codex_plan)"
rollout '"on-request"' '{"type":["read-only"]}'
check "a non-string sandbox type falls back to --approve-for-me" \
  grep -Fq -- "--skip-git-repo-check --approve-for-me resume" <<< "$(codex_plan)"
rollout '"never"' '{"type":"read-only"}'
printf '%s\n' '{"type":"turn_context","payload":{"cwd":["x"],"approval_policy":"never","sandbox_policy":{"type":"read-only"}}}' \
  >> "$FAKE_HOME/.codex/sessions/2026/09/22/rollout-2026-09-22T00-00-00-$SID.jsonl"
check "a non-string turn_context cwd is not replayed" \
  grep -Fq -- "(cd . && codex exec --skip-git-repo-check -s read-only" <<< "$(codex_plan)"
rm -rf "$FAKE_HOME/.codex"
check "missing rollout falls back to --approve-for-me" \
  grep -Fq -- "--skip-git-repo-check --approve-for-me resume" <<< "$(codex_plan)"

# --- completion message and codex adapter ------------------------------------
STATE="$FAKE_HOME/.local/state/agent-resume"
reset_calls
unit="$(ar env AGENT_RESUME_TEST_VAR=forwarded "$CLI" codex "$SID" --message 'address any errors' \
  -- sh -c 'pwd; echo "var=$AGENT_RESUME_TEST_VAR"; seq 1 50; exit 3' 2>&1)"
check "scheduling prints the trigger ID" grep -Eqx 'agent-resume-[0-9a-f]{8}' <<< "$unit"
log="$STATE/$unit.log"
check "the command ran in the caller's cwd" grep -Fqx "$WS" "$log"
check "the command saw the caller's environment" grep -Fqx 'var=forwarded' "$log"
expected="address any errors

agent-resume: \`sh -c 'pwd; echo \"var=\$AGENT_RESUME_TEST_VAR\"; seq 1 50; exit 3'\` exited with status 3.
Log: $log
Last 40 log lines:
$(seq 11 50)"
check "completion message has status, log path and last 40 lines" \
  test "$(cat "$CALLS/codex.last")" = "$expected"
check "codex resume was tried first" called codex "exec --skip-git-repo-check --approve-for-me resume $SID"
check "codex queue is not used when resume succeeds" bash -c '! grep -q "^queue" "$1"' _ "$CALLS/codex"
check "the trigger's state file is removed after firing" test ! -e "$STATE/$unit.json"

reset_calls
ar env CODEX_EXEC_EXIT=1 CODEX_EXEC_OUTPUT="Error: thread $SID already has an active writer" \
  "$CLI" codex "$SID" --message 'queued' -- true >/dev/null 2>&1
check "an active writer falls back to codex queue" called codex "queue --thread $SID --message=queued"

reset_calls
unit="$(ar env CODEX_EXEC_EXIT=1 CODEX_EXEC_OUTPUT="Error: model overloaded" \
  "$CLI" codex "$SID" --message 'not queued' -- true 2>&1)"
check "other resume failures do not queue" bash -c '! grep -q "^queue" "$1"' _ "$CALLS/codex"
check "a failed delivery exits nonzero" test "$(cat "$CALLS/fire.status")" -ne 0
check "a failed delivery logs the error and the full message" \
  contains "$(cat "$STATE/$unit.log")" "agent-resume: delivery failed (exit status 1); \
the undelivered message follows:"$'\n'"$(cat "$CALLS/codex.last")"
check "a failed delivery still removes the state file" test ! -e "$STATE/$unit.json"

reset_calls
unit="$(ar "$CLI" codex "$SID" --time 1s --message 'timer text' 2>&1)"
check "a timer delivers the bare message" test "$(cat "$CALLS/codex.last")" = "timer text"
check "a timer passes --on-active" called systemd-run "--on-active=1s"

reset_calls
unit="$(ar "$CLI" codex "$SID" --message 'missing' -- /nonexistent/command 2>&1)"
check "a command that cannot start still delivers" \
  grep -Fq '`/nonexistent/command` could not start.' "$CALLS/codex.last"

# An argument can hold no NUL byte and at most 128 KiB, and the tail is one.
reset_calls
ar "$CLI" codex "$SID" --message 'binary' -- printf 'a\0b\n' >/dev/null 2>&1
check "a NUL byte in the log tail still delivers" called codex "resume $SID -- binary"
reset_calls
ar "$CLI" codex "$SID" --message 'long lines' -- printf '%300000s\n' x >/dev/null 2>&1
check "a log tail too long for one argument still delivers" called codex "resume $SID -- long lines"

# A PATH with python3, bash and the fake systemd-run, a non-executable codex, and
# no claude. It must not reach the real binaries, so it holds nothing else.
NOBIN="$TMP/nobin"
mkdir -p "$NOBIN" || exit 1
ln -s "$(command -v python3)" "$NOBIN/python3" && ln -s "$(command -v bash)" "$NOBIN/bash" \
  && ln -s "$FAKE_BIN/systemd-run" "$NOBIN/systemd-run" && printf '#!/bin/sh\n' > "$NOBIN/codex" || exit 1
reset_calls
unit="$(ar env PATH="$NOBIN" "$CLI" codex "$SID" --time 1s --message 'no codex' 2>&1)"
check "an unexecutable codex exits nonzero" test "$(cat "$CALLS/fire.status")" -ne 0
check "an unexecutable codex logs the error and the message" \
  contains "$(cat "$STATE/$unit.log")" "agent-resume: delivery failed (PermissionError: [Errno 13] \
Permission denied: 'codex'); the undelivered message follows:"$'\n'"no codex"
check "an unexecutable codex still removes the state file" test ! -e "$STATE/$unit.json"

# A directory where a file should be is unreadable even to root.
mkdir -p "$FAKE_HOME/.codex/sessions/2026/09/22/rollout-2026-09-22T00-00-00-$SID.jsonl" || exit 1
reset_calls
unit="$(ar "$CLI" codex "$SID" --time 1s --message 'still here' 2>&1)"
check "an unreadable rollout still delivers with --approve-for-me" \
  called codex "--approve-for-me resume $SID -- still here"
check "an unreadable rollout is logged" grep -Fq 'unreadable rollout' "$STATE/$unit.log"
rm -rf "$FAKE_HOME/.codex"

rollout_path="$FAKE_HOME/.codex/sessions/2026/09/22/rollout-2026-09-22T00-00-00-$SID.jsonl"
mkdir -p "$(dirname "$rollout_path")" || exit 1
printf '%s\n' '["turn_context"]' > "$rollout_path"
reset_calls
ar "$CLI" codex "$SID" --time 1s --message 'non-object' >/dev/null 2>&1
check "a non-object rollout record still delivers with --approve-for-me" \
  called codex "--approve-for-me resume $SID -- non-object"
rm -rf "$FAKE_HOME/.codex"

# Codex keeps rollouts under $CODEX_HOME when it is set. When the trigger fires,
# that is the caller's CODEX_HOME saved with the trigger, not the unit's own.
codex_home="$TMP/codex-home"
rollout '"on-request"' '{"type":"workspace-write"}' "$codex_home"
out="$(ar env CODEX_HOME="$codex_home" "$CLI" codex "$SID" --time 1h --message m --dry-run 2>/dev/null)"
check "dry-run finds a rollout under CODEX_HOME" \
  grep -Fq -- "-s workspace-write -c 'approval_policy=\"on-request\"' resume" <<< "$out"
reset_calls
unit="$(ar env CODEX_HOME="$codex_home" FAKE_SYSTEMD_EXEC=0 \
  "$CLI" codex "$SID" --time 1s --message 'custom home' 2>&1)"
AR_CWD="$FAKE_HOME" ar "$CLI" _fire "$unit" >> "$STATE/$unit.log" 2>&1
check "firing finds the rollout under the caller's saved CODEX_HOME" \
  called codex "-s workspace-write -c approval_policy=\"on-request\" resume $SID -- custom home"
rm -rf "$codex_home"

# The scheduling directory can vanish before the trigger fires, e.g. a removed
# worktree. The unit does not run there, so the message still goes out.
gone="$TMP/gone"
mkdir "$gone" || exit 1
reset_calls
unit="$(AR_CWD="$gone" ar env FAKE_SYSTEMD_EXEC=0 "$CLI" codex "$SID" --message 'dir gone' -- true 2>&1)"
rmdir "$gone" || exit 1
AR_CWD="$FAKE_HOME" ar "$CLI" _fire "$unit" >> "$STATE/$unit.log" 2>&1
status=$?
check "a trigger whose cwd vanished still fires cleanly" test "$status" -eq 0
check "a command whose cwd vanished reports it could not start" \
  grep -Fq '`true` could not start.' "$CALLS/codex.last"
check "the vanished cwd is named in the message" grep -Fq "$gone" "$CALLS/codex.last"

reset_calls
ar "$CLI" codex "$SID" --time 1s --message='-x marks the spot' >/dev/null 2>&1
check "codex resume passes a leading-dash message after --" \
  called codex "resume $SID -- -x marks the spot"
reset_calls
ar env CODEX_EXEC_EXIT=1 CODEX_EXEC_OUTPUT="Error: thread $SID already has an active writer" \
  "$CLI" codex "$SID" --time 1s --message='--help me' >/dev/null 2>&1
check "codex queue passes a leading-dash message as --message=" \
  called codex "queue --thread $SID --message=--help me"

# --- claude adapter ----------------------------------------------------------
reset_calls
transcript bypassPermissions
ar env CLAUDE_CODE_SESSION_ID=caller "$CLI" claude "$SID" --time 1s --message 'wake up' >/dev/null 2>&1
check "no live session resumes with --bg" \
  called claude "--resume $SID --bg --dangerously-skip-permissions -- wake up"
check "claude resume runs in the transcript cwd" test "$(cat "$CALLS/claude.cwd")" = "$WS"

reset_calls
ar "$CLI" claude "$SID" --time 1s --message='--look at PRs' >/dev/null 2>&1
check "claude resume passes a leading-dash message after --" \
  called claude "--resume $SID --bg --dangerously-skip-permissions -- --look at PRs"

transcript_path="$FAKE_HOME/.claude/projects/-ws/$SID.jsonl"
printf '%s\n' '["permissionMode"]' '["cwd"]' > "$transcript_path"
reset_calls
ar "$CLI" claude "$SID" --time 1s --message 'non-object' >/dev/null 2>&1
check "a non-object transcript record still resumes in auto mode" \
  called claude "--resume $SID --bg --permission-mode auto -- non-object"

reset_calls
unit="$(ar env PATH="$NOBIN" "$CLI" claude "$SID" --time 1s --message 'no claude' 2>&1)"
check "a missing claude exits nonzero" test "$(cat "$CALLS/fire.status")" -ne 0
check "a missing claude logs the error and the message" \
  contains "$(cat "$STATE/$unit.log")" "agent-resume: delivery failed (FileNotFoundError: [Errno 2] \
No such file or directory: 'claude'); the undelivered message follows:"$'\n'"no claude"
check "a missing claude still removes the state file" test ! -e "$STATE/$unit.json"

rm -f "$transcript_path" && mkdir "$transcript_path" || exit 1
reset_calls
unit="$(ar "$CLI" claude "$SID" --time 1s --message 'still here' 2>&1)"
check "an unreadable transcript still resumes in auto mode" \
  called claude "--resume $SID --bg --permission-mode auto -- still here"
check "an unreadable transcript is logged" grep -Fq 'unreadable transcript' "$STATE/$unit.log"

sessions="$FAKE_HOME/.claude/sessions"
mkdir -p "$sessions" || exit 1
SOCK="$TMP/inbox.sock"
# serve <read|reset>: a one-connection inbox registered for $SID. "read" records
# everything until EOF and closes, like Claude Code's inbox. "reset" closes after
# one byte with the rest unread, which resets the poster's connection.
serve() {
  rm -f "$SOCK" "$TMP/received"
  python3 - "$SOCK" "$TMP/received" "$1" <<'PY' &
import socket, sys
socket.setdefaulttimeout(10)  # a poster that never connects fails the test, not hangs it
server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1]); server.listen(1)
conn, _ = server.accept()
if sys.argv[3] == "reset":
    conn.recv(1)
    sys.exit()
data = b""
while chunk := conn.recv(4096):
    data += chunk
open(sys.argv[2], "wb").write(data)
PY
  server_pid=$!
  for _ in $(seq 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
  printf '{"pid":%s,"sessionId":"%s","messagingSocketPath":"%s","status":"idle"}\n' \
    "$server_pid" "$SID" "$SOCK" > "$sessions/$server_pid.json"
  key="$sessions/$server_pid.$(printf %s "$SOCK" | sha256sum | cut -d' ' -f1).key"
}
fire_claude() { # fire_claude <message>: fire a 1s timer at once; prints its log path
  local unit
  unit="$(ar "$CLI" claude "$SID" --time 1s --message "$1" 2>&1)"
  printf '%s' "$STATE/$unit.log"
}
USER_LINE='{"type": "user", "message": {"role": "user", "content": "job done"}}'

serve read
echo '{"peerToken":"0123456789abcdef0123456789abcdef"}' > "$key"
# A stale entry for a dead process and an unreadable entry must be ignored.
printf '{"pid":999999999,"sessionId":"%s","messagingSocketPath":"/nonexistent.sock"}\n' \
  "$SID" > "$sessions/999999999.json"
mkdir -p "$sessions/1.json" || exit 1
# Malformed entries for $SID, named to sort before the live one, must be skipped
# too: a non-object, a missing or non-integer pid, a non-string socket path.
echo '["not an object"]' > "$sessions/0a.json"
printf '{"sessionId":"%s","messagingSocketPath":"%s"}\n' "$SID" "$SOCK" > "$sessions/0b.json"
printf '{"pid":"%s","sessionId":"%s","messagingSocketPath":"%s"}\n' "$$" "$SID" "$SOCK" \
  > "$sessions/0c.json"
printf '{"pid":%s,"sessionId":"%s","messagingSocketPath":["%s"]}\n' "$$" "$SID" "$SOCK" \
  > "$sessions/0d.json"
out="$(ar "$CLI" claude "$SID" --time 1s --message x --dry-run 2>&1)"
check "claude dry-run finds the live socket" grep -Fq "deliver: post to live socket $SOCK" <<< "$out"
reset_calls
log="$(fire_claude 'job done')"
wait "$server_pid"; server_pid=
check "live session gets the auth line then the user message" \
  test "$(cat "$TMP/received")" = '{"type": "auth", "token": "0123456789abcdef0123456789abcdef"}'$'\n'"$USER_LINE"
check "a live post is logged" grep -Fqx "agent-resume: posted to $SOCK" "$log"
check "a live session is not also resumed" not_called claude
check "malformed registry entries do not fail the trigger" test "$(cat "$CALLS/fire.status")" -eq 0
check "the live socket is tried before the unreadable transcript is read" \
  bash -c '! grep -Fq "unreadable transcript" "$1"' _ "$log"
rmdir "$transcript_path" || exit 1
transcript bypassPermissions

serve read
reset_calls
log="$(fire_claude 'job done')"
wait "$server_pid"; server_pid=
check "a missing peer token posts without the auth line" test "$(cat "$TMP/received")" = "$USER_LINE"
check "a missing peer token is logged" grep -Fq "no readable peer token for $SOCK" "$log"
check "a post without a token is not also resumed" not_called claude

serve read
mkdir "$key" || exit 1
reset_calls
log="$(fire_claude 'job done')"
wait "$server_pid"; server_pid=
check "an unreadable key file posts without the auth line" test "$(cat "$TMP/received")" = "$USER_LINE"
check "an unreadable key file does not resume" not_called claude

serve read
echo '{"peerToken":5}' > "$key"
reset_calls
log="$(fire_claude 'job done')"
wait "$server_pid"; server_pid=
check "a non-string peer token posts without the auth line" test "$(cat "$TMP/received")" = "$USER_LINE"

serve reset
reset_calls
log="$(fire_claude 'job done')"
wait "$server_pid"; server_pid=
check "a reset post to a live session exits nonzero" test "$(cat "$CALLS/fire.status")" -ne 0
check "a reset post is logged as undelivered" grep -Fq "not resuming the live session $SID" "$log"
check "a reset post does not start a copy with --resume" not_called claude

reset_calls
ar "$CLI" claude "$SID" --time 1s --message 'socket gone' >/dev/null 2>&1
check "a dead process falls back to --bg resume" \
  called claude "--resume $SID --bg --dangerously-skip-permissions -- socket gone"

rm -rf "$sessions"/*.json
printf '{"pid":%s,"sessionId":"%s","messagingSocketPath":"%s"}\n' "$$" "$SID" "$TMP/none.sock" \
  > "$sessions/$$.json"
reset_calls
unit="$(ar "$CLI" claude "$SID" --time 1s --message 'nobody listening' 2>&1)"
check "a live pid with no listening inbox falls back to --bg resume" \
  called claude "--resume $SID --bg --dangerously-skip-permissions -- nobody listening"
check "the missing inbox is logged" grep -Fq "no inbox is listening" "$STATE/$unit.log"

# --- list and cancel ---------------------------------------------------------
reset_calls
unit="$(ar env FAKE_SYSTEMD_EXEC=0 "$CLI" codex "$SID" --time 3h --message 'later' 2>&1)"
check "a scheduled trigger keeps its state file" test -f "$STATE/$unit.json"
check "the state file is private" test "$(stat -c %a "$STATE/$unit.json")" = 600
out="$(ar env FAKE_UNITS="$unit.timer loaded active waiting agent-resume codex $SID" "$CLI" list 2>&1)"
check "list shows the waiting trigger" \
  grep -Eq "^$unit	waiting	codex $SID	after 3h .*	later$" <<< "$out"
ar "$CLI" cancel "$unit" >/dev/null 2>&1
check "cancel stops the trigger's units" called systemctl "--user stop $unit.*"
check "cancel removes the state file" test ! -e "$STATE/$unit.json"
! ar "$CLI" cancel 'agent-resume-*' >/dev/null 2>&1 \
  && pass "cancel refuses a non-trigger ID" || fail "cancel accepted a glob"

if [ "$failures" -ne 0 ]; then
  echo "$failures agent-resume test(s) failed" >&2
  exit 1
fi
echo "all agent-resume tests passed"
