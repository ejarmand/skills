#!/usr/bin/env bash
# Hermetic public-interface tests for the OpenCode profiled runner.
# Fake executables observe the launch envelope; no namespace, network, or
# authenticated provider session is used.
set -u -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
RUNNER="$REPO/skills/opencode-agent/scripts/run-profiled.sh"
PROFILE="$REPO/skills/opencode-agent/profiles/github-pr-reviewer/config.json"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-opencode-runner.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN" || exit 1

cat > "$FAKE_BIN/opencode" <<'FAKE'
#!/usr/bin/env bash
exit 99
FAKE

cat > "$FAKE_BIN/gh" <<'FAKE'
#!/usr/bin/env bash
exit 99
FAKE

cat > "$FAKE_BIN/bwrap" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  echo '  --disable-userns'
  exit 0
fi
printf '%s\n' "$@" > "$BWRAP_ARGS"
readlink /proc/$$/fd/0 > "$BWRAP_ARGS.stdin"
if [ -n "${FAKE_BWRAP_LOG:-}" ]; then
  state="$(printf '%s\n' "$@" | awk 'previous == "--bind" { print; exit } { previous=$0 }')"
  mkdir -p "$state/data/opencode/log" || exit 98
  printf '%s\n' "$FAKE_BWRAP_LOG" >> "$state/data/opencode/log/opencode.log"
fi
[ -z "${FAKE_BWRAP_EVENT:-}" ] || printf '%s\n' "$FAKE_BWRAP_EVENT"
if [ -n "${FAKE_BWRAP_SLOW_EVENT:-}" ]; then
  printf '%s' "${FAKE_BWRAP_SLOW_EVENT:0:10}"
  sleep 2.5
  printf '%s\n' "${FAKE_BWRAP_SLOW_EVENT:10}"
fi
if [ -n "${FAKE_BWRAP_STALL:-}" ]; then
  # A sleep named opencode stands in for the sandboxed process.
  "$FAKE_SANDBOXED" "${FAKE_BWRAP_STALL_SECONDS:-30}" <&0 &
  trap 'kill $!; exit 143' TERM
  wait
fi
exit "${FAKE_BWRAP_EXIT:-0}"
FAKE

chmod +x "$FAKE_BIN/opencode" "$FAKE_BIN/gh" "$FAKE_BIN/bwrap" || exit 1
mkdir -p "$TMP/sandboxed" && ln -s "$(command -v sleep)" "$TMP/sandboxed/opencode" || exit 1

WS="$TMP/workspace"
RUN_TMPDIR="$TMP/state"
FAKE_HOME="$TMP/home"
FAKE_DATA="$TMP/data"
mkdir -p "$WS" "$RUN_TMPDIR" "$FAKE_HOME/.config/gh" "$FAKE_DATA/opencode" || exit 1
touch "$FAKE_HOME/.config/gh/hosts.yml" "$FAKE_DATA/opencode/auth.json" || exit 1

run_runner() {
  env -u XDG_CONFIG_HOME -u GH_CONFIG_DIR \
    PATH="$FAKE_BIN:$PATH" TMPDIR="$RUN_TMPDIR" \
    HOME="$FAKE_HOME" XDG_DATA_HOME="$FAKE_DATA" \
    BWRAP_ARGS="$TMP/bwrap.args" FAKE_SANDBOXED="$TMP/sandboxed/opencode" \
    "$RUNNER" "$@"
}
config_arg() {
  awk 'previous == "OPENCODE_CONFIG_CONTENT" { print; exit } { previous=$0 }' "$TMP/bwrap.args"
}

# A profiled dispatch is one model, one prompt, and one disposable boundary.
rc=0
run_runner --workspace "$WS" --profile github-pr-reviewer \
  --model openrouter/example-model -- "review issue 18" || rc=$?
[ "$rc" -eq 0 ] || fail "dispatch exited $rc (want 0)"
[ -f "$TMP/bwrap.args" ] || { fail "bubblewrap was not invoked"; exit 1; }

grep -Fxq -- "--ro-bind" "$TMP/bwrap.args" \
  && pass "runner creates read-only binds" || fail "read-only bind missing"
grep -Fxq -- "$WS" "$TMP/bwrap.args" \
  && pass "runner binds the selected workspace" || fail "workspace bind missing"
grep -Fxq -- "OPENCODE_CONFIG_CONTENT" "$TMP/bwrap.args" \
  && pass "runner injects the named profile" || fail "profile config missing"
awk 'previous == "--unsetenv" && $0 == "OPENCODE_CONFIG" { found=1 } { previous=$0 } END { exit !found }' "$TMP/bwrap.args" \
  && pass "runner suppresses ambient custom config" || fail "ambient custom config remains enabled"
grep -Fxq -- "openrouter/example-model" "$TMP/bwrap.args" \
  && pass "runner selects the requested model" || fail "model missing"
grep -Fxq -- "review issue 18" "$TMP/bwrap.args" \
  && pass "runner forwards the prompt" || fail "prompt missing"
if grep -Fxq -- "--variant" "$TMP/bwrap.args"; then
  fail "runner adds a variant when none was requested"
else
  pass "runner leaves the model's default variant alone"
fi
[ "$(tail -n 2 "$TMP/bwrap.args" | head -n 1)" = -- ] \
  && pass "runner separates the prompt from OpenCode flags" || fail "prompt has no option boundary"
grep -Fxq -- "$FAKE_DATA/opencode/auth.json" "$TMP/bwrap.args" \
  && grep -Fxq -- "/state/data/opencode/auth.json" "$TMP/bwrap.args" \
  && pass "runner mounts stored provider credentials" || fail "provider credential mount missing"
grep -Fxq -- "$FAKE_HOME/.config/gh" "$TMP/bwrap.args" \
  && grep -Fxq -- "/state/config/gh" "$TMP/bwrap.args" \
  && pass "runner mounts stored gh authentication" || fail "gh authentication mount missing"
awk 'previous ~ /opencode-profile\..*\/state\/config\/opencode$/ && $0 == "/state/config/opencode" { found=1 } { previous=$0 } END { exit !found }' "$TMP/bwrap.args" \
  && pass "OpenCode config directory is read-only, so no per-run plugin install" \
  || fail "OpenCode config directory is writable"

state_root="$(awk 'previous == "--bind" && $0 ~ /opencode-profile\./ { print; exit } { previous=$0 }' "$TMP/bwrap.args")"
[ -n "$state_root" ] || fail "writable state bind missing"
[ -n "$state_root" ] && [ ! -e "$state_root" ] \
  && pass "disposable state removed after dispatch" || fail "state was not cleaned up: $state_root"
[ "$(config_arg | jq -c '.provider')" = '{"openrouter":{"options":{"headerTimeout":120000,"chunkTimeout":120000}}}' ] \
  && pass "selected provider gets default header and chunk timeouts" \
  || fail "default provider timeouts: $(config_arg | jq -c '.provider')"

# OpenCode reads a non-terminal stdin to its end before creating a session.
mkfifo "$TMP/stdin.fifo" && exec 3<> "$TMP/stdin.fifo" || exit 1
rm -f "$TMP/bwrap.args"
rc=0
run_runner --workspace "$WS" --profile github-pr-reviewer \
  --model openrouter/example-model -- "task" <&3 >/dev/null 2>&1 || rc=$?
exec 3>&-
[ "$rc" -eq 0 ] && [ "$(cat "$TMP/bwrap.args.stdin")" = /dev/null ] \
  && pass "sandbox stdin is /dev/null even when the runner's stdin is an open pipe" \
  || fail "sandbox stdin: rc=$rc stdin=$(cat "$TMP/bwrap.args.stdin")"

# The provider timeout follows the model's provider and the requested value.
rm -f "$TMP/bwrap.args"
run_runner --workspace "$WS" --profile github-pr-reviewer \
  --model opencode/example-model --provider-timeout 30 -- "task" >/dev/null 2>&1
[ "$(config_arg | jq -c '.provider')" = '{"opencode":{"options":{"headerTimeout":30000,"chunkTimeout":30000}}}' ] \
  && pass "provider timeout override reaches the selected provider" \
  || fail "provider timeout override: $(config_arg | jq -c '.provider')"

# Provider options the profile sets win over the runner's defaults.
mkdir -p "$TMP/skills" && cp -R "$REPO/skills/opencode-agent" "$TMP/skills/" || exit 1
custom_profile="$TMP/skills/opencode-agent/profiles/github-pr-reviewer/config.json"
jq '.provider.openrouter.options = {headerTimeout: 5000, baseURL: "http://127.0.0.1:9/v1"}' "$PROFILE" > "$custom_profile" || exit 1
rm -f "$TMP/bwrap.args"
RUNNER="$TMP/skills/opencode-agent/scripts/run-profiled.sh" run_runner --workspace "$WS" \
  --profile github-pr-reviewer --model openrouter/example-model -- "task" >/dev/null 2>&1
[ "$(config_arg | jq -c '.provider.openrouter.options')" = '{"headerTimeout":5000,"chunkTimeout":120000,"baseURL":"http://127.0.0.1:9/v1"}' ] \
  && pass "profile provider options win over runner timeouts" \
  || fail "profile provider options: $(config_arg | jq -c '.provider.openrouter.options')"

# The requested model variant reaches OpenCode as an argument, not prompt text.
rm -f "$TMP/bwrap.args"
rc=0
run_runner --workspace "$WS" --profile github-pr-reviewer \
  --model openrouter/example-model --variant high --agent reviewer -- "review issue 18" || rc=$?
[ "$rc" -eq 0 ] || fail "variant dispatch exited $rc (want 0)"
awk 'previous == "--agent" && $0 == "reviewer" { found=1 } { previous=$0 } END { exit !found }' "$TMP/bwrap.args" \
  && pass "runner forwards the selected agent alongside the variant" || fail "selected agent missing"
awk 'previous == "--variant" && $0 == "high" { found=1 } { previous=$0 } END { exit !found }' "$TMP/bwrap.args" \
  && pass "runner forwards the requested model variant" || fail "model variant missing"
[ "$(tail -n 2 "$TMP/bwrap.args" | head -n 1)" = -- ] \
  && pass "variant stays before the prompt boundary" || fail "variant reached the prompt"

rm -f "$TMP/bwrap.args"
rc=0
run_runner --workspace "$WS" --profile github-pr-reviewer \
  --model openrouter/example-model --variant "" -- "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && [ ! -f "$TMP/bwrap.args" ] \
  && pass "empty explicit variant is refused before launch" || fail "empty variant refusal: rc=$rc"

# OpenCode would silently replace a subagent with its default agent.
for bad_agent in spec build; do
  rm -f "$TMP/bwrap.args"
  rc=0
  run_runner --workspace "$WS" --profile github-pr-reviewer \
    --model openrouter/example-model --agent "$bad_agent" -- "task" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && [ ! -f "$TMP/bwrap.args" ] \
    && pass "non-primary agent $bad_agent is refused before launch" || fail "agent $bad_agent refusal: rc=$rc"
done

rm -f "$TMP/bwrap.args"
rc=0
run_runner --workspace "$WS" --profile github-pr-reviewer \
  --model openrouter/example-model --idle-timeout 0 -- "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && [ ! -f "$TMP/bwrap.args" ] \
  && pass "zero idle timeout is refused before launch" || fail "idle timeout refusal: rc=$rc"

# OpenCode events reach stdout unchanged.
out="$(FAKE_BWRAP_EVENT='{"type":"step_start"}' run_runner --workspace "$WS" \
  --profile github-pr-reviewer --model openrouter/example-model -- "task")"
[ "$out" = '{"type":"step_start"}' ] && pass "runner relays OpenCode events" || fail "events not relayed: $out"

# A line that arrives across several one-second wakes is reassembled intact.
out="$(FAKE_BWRAP_SLOW_EVENT='{"type":"text","part":{"text":" a \\ b "}}' run_runner --workspace "$WS" \
  --profile github-pr-reviewer --model openrouter/example-model -- "task")"
[ "$out" = '{"type":"text","part":{"text":" a \\ b "}}' ] \
  && pass "runner reassembles a slowly written event" || fail "slow event mangled: $out"

# A logged rate limit followed by silence stops the run instead of waiting out retry-after.
rate_limit_log='timestamp=2026-09-28T21:56:25.444Z level=ERROR run=ed6a999c message="stream error" providerID=openrouter modelID=z-ai/glm-5.3-flash session.id=ses_1 small=false agent=reviewer mode=primary error.error="AI_APICallError: Rate limit exceeded"'
rm -f "$TMP/bwrap.args"
rc=0
started=$SECONDS
err="$(FAKE_BWRAP_STALL=1 FAKE_BWRAP_LOG="$rate_limit_log" run_runner --workspace "$WS" \
  --profile github-pr-reviewer --model openrouter/example-model --rate-limit-grace 1 -- "task" 2>&1 >/dev/null)" || rc=$?
state_root="$(awk 'previous == "--bind" && $0 ~ /opencode-profile\./ { print; exit } { previous=$0 }' "$TMP/bwrap.args")"
[ "$rc" -eq 76 ] && [ $((SECONDS - started)) -lt 10 ] && grep -Fq -- "$rate_limit_log" <<< "$err" \
  && pass "rate-limited run exits 76 and shows the logged error" \
  || fail "rate-limited run: rc=$rc after $((SECONDS - started))s: $err"
[ -n "$state_root" ] && [ ! -e "$state_root" ] \
  && pass "rate-limited run state is removed" || fail "rate-limited run left state: $state_root"

# A rate-limit line without small=, and an overload, count the same way.
expect_limited() {
  rc=0
  FAKE_BWRAP_STALL=1 FAKE_BWRAP_LOG="$2" run_runner --workspace "$WS" \
    --profile github-pr-reviewer --model openrouter/example-model --rate-limit-grace 1 --idle-timeout 6 \
    -- "task" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 76 ] && pass "$1 exits 76" || fail "$1: rc=$rc"
}
expect_limited "rate limit without small=" "${rate_limit_log/ small=false/}"
expect_limited "provider overload" "${rate_limit_log/Rate limit exceeded/Service Unavailable (503): overloaded}"

# Events carry OpenCode's epoch-ms timestamps; the logged error is at ...585444.
event_before='{"type":"step_start","timestamp":1790632585400,"sessionID":"ses_1"}'
event_after='{"type":"step_start","timestamp":1790632585500,"sessionID":"ses_1"}'

# An event emitted before the error does not hide it, even when read before the
# runner scans the error. The fake writes the error, then the event, then goes
# silent, all within milliseconds of opening the event pipe. The runner scans
# the log only after a read returns, so it reads the event first.
rc=0
FAKE_BWRAP_STALL=1 FAKE_BWRAP_LOG="$rate_limit_log" FAKE_BWRAP_EVENT="$event_before" \
  run_runner --workspace "$WS" --profile github-pr-reviewer --model openrouter/example-model \
  --rate-limit-grace 1 --idle-timeout 6 -- "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 76 ] && pass "an error logged after an event read before the scan still counts" \
  || fail "event, then error, read in reverse: rc=$rc"

# An event emitted after the error, read before the scan, is progress: the
# error is dropped and the silence that follows is an idle stop, not 76.
rc=0
FAKE_BWRAP_STALL=1 FAKE_BWRAP_LOG="$rate_limit_log" FAKE_BWRAP_EVENT="$event_after" \
  run_runner --workspace "$WS" --profile github-pr-reviewer --model openrouter/example-model \
  --rate-limit-grace 1 --idle-timeout 3 -- "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] && pass "an event newer than the error clears it before it is scanned" \
  || fail "error, then newer event, then silence: rc=$rc"

# An event that completes after the error was scanned clears it only if it was
# emitted after the error. The event starts at once (so the error is scanned on
# the first one-second wake) and completes 2.5 s later, well inside the grace.
rc=0
FAKE_BWRAP_STALL=1 FAKE_BWRAP_STALL_SECONDS=4 FAKE_BWRAP_LOG="$rate_limit_log" \
  FAKE_BWRAP_SLOW_EVENT="$event_after" run_runner --workspace "$WS" \
  --profile github-pr-reviewer --model openrouter/example-model --rate-limit-grace 3 \
  -- "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && pass "an event after a scanned error keeps the run going" \
  || fail "error then progress: rc=$rc"
rc=0
FAKE_BWRAP_STALL=1 FAKE_BWRAP_LOG="$rate_limit_log" FAKE_BWRAP_SLOW_EVENT="$event_before" \
  run_runner --workspace "$WS" --profile github-pr-reviewer --model openrouter/example-model \
  --rate-limit-grace 3 --idle-timeout 8 -- "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 76 ] && pass "an older event read after a scanned error does not clear it" \
  || fail "older event after scanned error: rc=$rc"

# A rate-limited title request does not block the run, so it is not a stop reason.
rc=0
FAKE_BWRAP_STALL=1 FAKE_BWRAP_LOG="${rate_limit_log/small=false/small=true}" run_runner --workspace "$WS" \
  --profile github-pr-reviewer --model openrouter/example-model --rate-limit-grace 1 --idle-timeout 4 \
  -- "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] && pass "title rate limit falls through to the idle watchdog" || fail "title rate limit: rc=$rc"

# A silent run is stopped at the idle timeout rather than hanging.
rm -f "$TMP/bwrap.args"
rc=0
started=$SECONDS
err="$(FAKE_BWRAP_STALL=1 run_runner --workspace "$WS" --profile github-pr-reviewer \
  --model openrouter/example-model --idle-timeout 1 -- "task" 2>&1 >/dev/null)" || rc=$?
state_root="$(awk 'previous == "--bind" && $0 ~ /opencode-profile\./ { print; exit } { previous=$0 }' "$TMP/bwrap.args")"
[ "$rc" -eq 75 ] && [ $((SECONDS - started)) -lt 10 ] \
  && pass "stalled run exits 75 at the idle timeout" || fail "stalled run: rc=$rc after $((SECONDS - started))s"
grep -Eq 'OpenCode pid [0-9]+ stdin: /dev/null' <<< "$err" \
  && grep -Eq 'OpenCode pid [0-9]+ wchan: .' <<< "$err" \
  && grep -Eq 'OpenCode pid [0-9]+ established TCP connections:' <<< "$err" \
  && pass "stall report shows what OpenCode was waiting on" || fail "stall report missing: $err"
[ -n "$state_root" ] && [ ! -e "$state_root" ] \
  && pass "stalled run state is removed" || fail "stalled run left state: $state_root"

# A caller's timeout still cleans up the disposable state.
rm -f "$TMP/bwrap.args"
env -u XDG_CONFIG_HOME -u GH_CONFIG_DIR PATH="$FAKE_BIN:$PATH" TMPDIR="$RUN_TMPDIR" \
  HOME="$FAKE_HOME" XDG_DATA_HOME="$FAKE_DATA" BWRAP_ARGS="$TMP/bwrap.args" FAKE_BWRAP_STALL=1 \
  FAKE_SANDBOXED="$TMP/sandboxed/opencode" \
  "$RUNNER" --workspace "$WS" --profile github-pr-reviewer \
  --model openrouter/example-model -- "task" >/dev/null 2>&1 &
runner_pid=$!
for _ in $(seq 50); do [ -f "$TMP/bwrap.args" ] && break; sleep 0.1; done
kill -TERM "$runner_pid"
rc=0
wait "$runner_pid" || rc=$?
state_root="$(awk 'previous == "--bind" && $0 ~ /opencode-profile\./ { print; exit } { previous=$0 }' "$TMP/bwrap.args")"
[ "$rc" -eq 143 ] && [ -n "$state_root" ] && [ ! -e "$state_root" ] \
  && pass "terminated run removes its state" || fail "terminated run: rc=$rc state=$state_root"

# The profile carries one reviewer identity across the complete hierarchy.
[ "$(jq -r '.agent | keys | sort | join(",")' "$PROFILE")" = "reviewer,spec,standards" ] \
  && pass "profile defines the reviewer and both review axes" || fail "profile agent roster drifted"
[ "$(jq '[.agent[] | has("model")] | any' "$PROFILE")" = false ] \
  && pass "children inherit the dispatch model" || fail "profile pins a per-agent model"
[ "$(jq -r '.agent.reviewer.permission.task.standards' "$PROFILE")" = allow ] \
  && [ "$(jq -r '.agent.reviewer.permission.task.spec' "$PROFILE")" = allow ] \
  && pass "reviewer can delegate both axes" || fail "review hierarchy is not enabled"
[ "$(jq -r '.permission.task["*"]' "$PROFILE")" = deny ] \
  && [ "$(jq '[.agent.standards, .agent.spec] | map(has("permission")) | any' "$PROFILE")" = false ] \
  && pass "review children hold the shared read-only baseline" \
  || fail "review children carry their own permission overrides"
[ "$(jq -r '.agent.reviewer.permission.bash["gh pr comment *"]' "$PROFILE")" = allow ] \
  && [ "$(jq '.permission.bash | keys | map(startswith("gh pr comment")) | any' "$PROFILE")" = false ] \
  && pass "publication authority is reviewer-only" \
  || fail "publication authority leaks past the reviewer"

# A failed child remains the result, and its state is still disposable.
rm -f "$TMP/bwrap.args"
rc=0
FAKE_BWRAP_EXIT=7 run_runner --workspace "$WS" --profile github-pr-reviewer \
  --model openrouter/example-model -- "review issue 18" || rc=$?
[ "$rc" -eq 7 ] && pass "bubblewrap child exit propagates" || fail "child exit became $rc"
state_root="$(awk 'previous == "--bind" && $0 ~ /opencode-profile\./ { print; exit } { previous=$0 }' "$TMP/bwrap.args")"
[ -n "$state_root" ] && [ ! -e "$state_root" ] \
  && pass "failed dispatch state is removed" || fail "failed dispatch left state: $state_root"

# Missing stored credentials fail before bubblewrap is launched.
rm -f "$TMP/bwrap.args"
rc=0
env -u XDG_CONFIG_HOME -u GH_CONFIG_DIR PATH="$FAKE_BIN:$PATH" TMPDIR="$RUN_TMPDIR" \
  HOME="$FAKE_HOME" XDG_DATA_HOME="$TMP/no-such-data" \
  BWRAP_ARGS="$TMP/bwrap.args" \
  "$RUNNER" --workspace "$WS" --profile github-pr-reviewer \
  --model openrouter/example-model -- "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 71 ] && [ ! -f "$TMP/bwrap.args" ] \
  && pass "missing provider credentials are refused before launch" \
  || fail "missing-credentials refusal: rc=$rc launched=$([ -f "$TMP/bwrap.args" ] && echo yes || echo no)"

rm -f "$TMP/bwrap.args"
rc=0
env -u XDG_CONFIG_HOME -u GH_CONFIG_DIR PATH="$FAKE_BIN:$PATH" TMPDIR="$RUN_TMPDIR" \
  HOME="$TMP/no-gh-home" XDG_DATA_HOME="$FAKE_DATA" \
  BWRAP_ARGS="$TMP/bwrap.args" \
  "$RUNNER" --workspace "$WS" --profile github-pr-reviewer \
  --model openrouter/example-model -- "task" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 71 ] && [ ! -f "$TMP/bwrap.args" ] \
  && pass "missing gh authentication is refused before launch" \
  || fail "missing-gh-auth refusal: rc=$rc launched=$([ -f "$TMP/bwrap.args" ] && echo yes || echo no)"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all opencode runner tests passed"
