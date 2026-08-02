#!/usr/bin/env bash
# Hermetic lifecycle tests for skills/codex-agent/scripts/run-profiled.sh.
# Uses a fake codex on PATH; no network, no real CLI, no mutation of the
# user's real CODEX_HOME.
set -u -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
RUNNER="$REPO/skills/codex-agent/scripts/run-profiled.sh"
PROFILE_DIR="$REPO/skills/codex-agent/profiles/github-pr-reviewer"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-codex-runner.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }

md5() { md5sum < "$1" | cut -d' ' -f1; }

# --- fake codex ------------------------------------------------------------
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN" || exit 1
cat > "$FAKE_BIN/codex" <<'FAKE'
#!/usr/bin/env bash
{
  echo "home=${CODEX_HOME:-}"
  echo "args=$*"
  home="${CODEX_HOME:-}"
  if [ -n "$home" ]; then
    if [ -f "$home/config.toml" ]; then
      echo "config_md5=$(md5sum < "$home/config.toml" | cut -d' ' -f1)"
    else
      echo "config_md5=absent"
    fi
    if ls "$home/rules/"*.rules > /dev/null 2>&1; then
      echo "rules=present"
    else
      echo "rules=absent"
    fi
    echo "auth_target=$(readlink "$home/auth.json" 2>/dev/null || echo none)"
    echo "skills_target=$(readlink "$home/skills" 2>/dev/null || echo none)"
  fi
  if [ -t 0 ]; then echo "stdin=tty"; else echo "stdin=redirected"; fi
} > "$RECORD_FILE"
exit "${FAKE_EXIT:-0}"
FAKE
chmod +x "$FAKE_BIN/codex" || exit 1

# --- fake real home and workspace ------------------------------------------
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.codex/skills" || exit 1
echo '{"token":"fake"}' > "$FAKE_HOME/.codex/auth.json" || exit 1
WS="$TMP/workspace"
mkdir -p "$WS" || exit 1
RUN_TMPDIR="$TMP/tmp"
mkdir -p "$RUN_TMPDIR" || exit 1

run_runner() {
  env -u CODEX_HOME PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" \
    TMPDIR="$RUN_TMPDIR" RECORD_FILE="$TMP/record" FAKE_EXIT="${FAKE_EXIT:-0}" \
    "$RUNNER" "$@"
}

record() { sed -n "s/^$1=//p" "$TMP/record" | head -n 1; }

# --- 1. happy path: assembled home, envelope args, cleanup ------------------
rm -f "$TMP/record"
run_runner --workspace "$WS" --profile github-pr-reviewer -- --json "review task"
rc=$?
[ "$rc" -eq 0 ] && pass "happy path exits 0" || fail "happy path exited $rc"
[ -f "$TMP/record" ] || { fail "fake codex was not invoked"; exit 1; }

tmp_home="$(record home)"
case "$tmp_home" in
  "$RUN_TMPDIR"/codex-profile.*) pass "child ran in a private CODEX_HOME" ;;
  *) fail "unexpected CODEX_HOME: $tmp_home" ;;
esac
[ ! -e "$tmp_home" ] && pass "temporary home removed after exit" \
  || fail "temporary home left behind: $tmp_home"
[ "$(record config_md5)" = "$(md5 "$PROFILE_DIR/config.toml")" ] \
  && pass "home config.toml is the profile's" || fail "config.toml mismatch"
[ "$(record rules)" = "present" ] && pass "profile rules staged" \
  || fail "rules missing from assembled home"
[ "$(record auth_target)" = "$FAKE_HOME/.codex/auth.json" ] \
  && pass "auth.json symlinked to the real home" \
  || fail "auth target: $(record auth_target)"
[ "$(record skills_target)" = "$FAKE_HOME/.codex/skills" ] \
  && pass "skills symlinked to the real home" \
  || fail "skills target: $(record skills_target)"
[ -f "$FAKE_HOME/.codex/auth.json" ] && pass "real auth.json survives cleanup" \
  || fail "cleanup removed the real auth.json"
[ -d "$FAKE_HOME/.codex/skills" ] && pass "real skills dir survives cleanup" \
  || fail "cleanup removed the real skills dir"
case "$(record args)" in
  "exec --sandbox read-only -C $WS --json review task")
    pass "runner owns the envelope; child args pass through" ;;
  *"--ephemeral"*)
    fail "--ephemeral reintroduced: it breaks full-history child forks (no thread with id)" ;;
  *) fail "unexpected args: $(record args)" ;;
esac
[ "$(record stdin)" = "redirected" ] && pass "stdin closed for the child" \
  || fail "stdin left open"

# --- 2. child exit propagates; cleanup still runs ---------------------------
rm -f "$TMP/record"
FAKE_EXIT=7 run_runner --workspace "$WS" --profile github-pr-reviewer -- "task"
rc=$?
[ "$rc" -eq 7 ] && pass "child exit code propagates" || fail "expected 7, got $rc"
tmp_home="$(record home)"
[ ! -e "$tmp_home" ] && pass "temporary home removed after failed child" \
  || fail "temporary home left behind after failure: $tmp_home"

# --- 3. child argument allowlist --------------------------------------------
for bad in --ignore-rules --ignore-user-config --sandbox --full-auto; do
  rm -f "$TMP/record"
  run_runner --workspace "$WS" --profile github-pr-reviewer -- "$bad" "task" 2>/dev/null
  rc=$?
  [ "$rc" -eq 2 ] && [ ! -f "$TMP/record" ] \
    && pass "rejects $bad without launching" \
    || fail "$bad: rc=$rc invoked=$([ -f "$TMP/record" ] && echo yes || echo no)"
done

# --- 4. workspace containing .codex/ is refused ------------------------------
mkdir -p "$WS/.codex/rules" || exit 1
rm -f "$TMP/record"
run_runner --workspace "$WS" --profile github-pr-reviewer -- "task" 2>/dev/null
rc=$?
[ "$rc" -eq 71 ] && [ ! -f "$TMP/record" ] \
  && pass "refuses a workspace with .codex/" \
  || fail ".codex preflight: rc=$rc invoked=$([ -f "$TMP/record" ] && echo yes || echo no)"
rm -rf "$WS/.codex"

# --- 5. missing auth fails closed --------------------------------------------
mv "$FAKE_HOME/.codex/auth.json" "$TMP/auth.stash" || exit 1
rm -f "$TMP/record"
run_runner --workspace "$WS" --profile github-pr-reviewer -- "task" 2>/dev/null
rc=$?
[ "$rc" -eq 71 ] && [ ! -f "$TMP/record" ] \
  && pass "refuses to dispatch without auth.json" \
  || fail "auth preflight: rc=$rc invoked=$([ -f "$TMP/record" ] && echo yes || echo no)"
mv "$TMP/auth.stash" "$FAKE_HOME/.codex/auth.json" || exit 1

# --- 6. no stray temp homes ---------------------------------------------------
leftovers="$(find "$RUN_TMPDIR" -maxdepth 1 -name 'codex-profile.*' | wc -l)"
[ "$leftovers" -eq 0 ] && pass "no stray temporary homes" \
  || fail "$leftovers stray temporary home(s) under $RUN_TMPDIR"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all codex runner lifecycle tests passed"
