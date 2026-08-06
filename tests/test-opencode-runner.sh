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
printf '%s\n' "$@" > "$BWRAP_ARGS"
exit "${FAKE_BWRAP_EXIT:-0}"
FAKE

chmod +x "$FAKE_BIN/opencode" "$FAKE_BIN/gh" "$FAKE_BIN/bwrap" || exit 1

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
    BWRAP_ARGS="$TMP/bwrap.args" \
    "$RUNNER" "$@"
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
[ "$(tail -n 2 "$TMP/bwrap.args" | head -n 1)" = -- ] \
  && pass "runner separates the prompt from OpenCode flags" || fail "prompt has no option boundary"
grep -Fxq -- "$FAKE_DATA/opencode/auth.json" "$TMP/bwrap.args" \
  && grep -Fxq -- "/state/data/opencode/auth.json" "$TMP/bwrap.args" \
  && pass "runner mounts stored provider credentials" || fail "provider credential mount missing"
grep -Fxq -- "$FAKE_HOME/.config/gh" "$TMP/bwrap.args" \
  && grep -Fxq -- "/state/config/gh" "$TMP/bwrap.args" \
  && pass "runner mounts stored gh authentication" || fail "gh authentication mount missing"

state_root="$(awk 'previous == "--bind" && $0 ~ /opencode-profile\./ { print; exit } { previous=$0 }' "$TMP/bwrap.args")"
[ -n "$state_root" ] || fail "writable state bind missing"
[ -n "$state_root" ] && [ ! -e "$state_root" ] \
  && pass "disposable state removed after dispatch" || fail "state was not cleaned up: $state_root"

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
