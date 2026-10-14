#!/usr/bin/env bash
# Opt-in live tests for skills/opencode-agent/scripts/run-profiled.sh (#53).
#
# Runs the real opencode inside real bubblewrap against a local fake
# OpenAI-compatible provider, so no network or provider account is needed:
# the profile's openrouter baseURL points at the fake, and throwaway
# credentials stand in for the stored ones. Checks that an open stdin pipe no longer
# hangs, that the prompt reaches the provider once, that a provider which never
# answers ends in a clean error, that the idle watchdog reports what OpenCode
# was waiting on, and that a long retry-after on a 429 ends at that watchdog.
# Also checks that a long retry-after on a 429 or 503 exits 76 while a short
# one is waited out, and that workspace plugins stay out of the run even when
# the caller's environment re-enables project config. Checks the profile's
# shell permissions with tool calls from the fake provider. Takes about three
# minutes.
set -u -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)" || exit 1

for cmd in opencode bwrap python3 jq git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "live-opencode-runner: $cmd is required" >&2; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/live-opencode-runner.XXXXXX")" || exit 1
servers=()
trap 'kill "${servers[@]}" 2>/dev/null; rm -rf "$TMP"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok: $*"; }

# Copy the skills so the profile can point at the fake without touching the repo.
mkdir -p "$TMP/skills" "$TMP/bin" "$TMP/data/opencode" "$TMP/gh" "$TMP/state" "$TMP/ws" || exit 1
cp -R "$REPO/skills/opencode-agent" "$REPO/skills/code-review" "$TMP/skills/" || exit 1
RUNNER="$TMP/skills/opencode-agent/scripts/run-profiled.sh"
PROFILE="$TMP/skills/opencode-agent/profiles/github-pr-reviewer/config.json"
printf '#!/bin/sh\necho "fake-gh-ran $*"\n' > "$TMP/bin/gh" && chmod +x "$TMP/bin/gh" || exit 1
echo '{"openrouter":{"type":"api","key":"sk-live-test"}}' > "$TMP/data/opencode/auth.json" || exit 1
touch "$TMP/gh/hosts.yml" || exit 1
git -C "$TMP/ws" init -q && echo hello > "$TMP/ws/README" && git -C "$TMP/ws" add README \
  && git -C "$TMP/ws" -c user.name=test -c user.email=test@example.com commit -qm init || exit 1

cat > "$TMP/fakeprov.py" <<'PY'
# Fake OpenAI-compatible provider. MODE ok: stream "OK"; hang: accept and never
# answer; 429 or 503: rate limit or overload with a 900 s retry-after; 429-brief:
# the first two requests get a 429 with a 2 s retry-after, then "OK";
# shell:COMMAND: a shell tool call running COMMAND, then "OK". Writes
# its port to argv[2], and request lines and bodies to argv[3].
import http.server, json, sys, time
mode = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    posts = 0
    def do_POST(self):
        H.posts += 1
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        with open(sys.argv[3], "ab") as log:
            log.write(body + b"\n")
        if mode == "hang":
            time.sleep(3600)
        brief = mode == "429-brief" and H.posts <= 2
        if mode in ("429", "503") or brief:
            message = "Service overloaded" if mode == "503" else "Rate limit exceeded"
            status = 503 if mode == "503" else 429
            body = json.dumps({"error": {"message": message, "code": status}}).encode()
            self.send_response(status)
            self.send_header("retry-after", "2" if brief else "900")
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        request = json.loads(body or b"{}")
        call = mode.startswith("shell:") and any(t["function"]["name"] == "shell" for t in request.get("tools", [])) \
            and not any(m["role"] == "tool" for m in request.get("messages", []))
        chunk = lambda delta, finish: "data: " + json.dumps({
            "id": "fake", "object": "chat.completion.chunk", "created": 0, "model": "fake",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            **({"usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}} if finish else {}),
        }) + "\n\n"
        if call:
            tool = {"index": 0, "id": "call_1", "type": "function",
                    "function": {"name": "shell", "arguments": json.dumps({"command": mode[6:]})}}
            body = (chunk({"role": "assistant", "tool_calls": [tool]}, None) + chunk({}, "tool_calls") + "data: [DONE]\n\n").encode()
        else:
            body = (chunk({"role": "assistant", "content": "OK"}, None) + chunk({}, "stop") + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        with open(sys.argv[3], "a") as log:
            log.write(args[0] % args[1:] + "\n")
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[2], "w") as port:
    port.write(str(server.server_address[1]))
server.serve_forever()
PY

# start_provider MODE: start a fake and point the profile at it.
start_provider() {
  rm -f "$TMP/port" "$TMP/requests"
  python3 "$TMP/fakeprov.py" "$1" "$TMP/port" "$TMP/requests" &
  servers+=($!)
  for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
  [ -s "$TMP/port" ] || { echo "live-opencode-runner: fake provider did not start" >&2; exit 1; }
  jq --arg url "http://127.0.0.1:$(cat "$TMP/port")/api/v1" \
    '.provider.openrouter = {options: {baseURL: $url}, models: {fake: {name: "fake"}}}
     | .small_model = "openrouter/fake"' \
    "$REPO/skills/opencode-agent/profiles/github-pr-reviewer/config.json" > "$PROFILE" || exit 1
}

# run_live ARGS...: one runner dispatch with stdin held open, bounded by timeout.
run_live() {
  mkfifo "$TMP/stdin" && exec 3<> "$TMP/stdin" || exit 1
  started=$SECONDS
  rc=0
  env -u XDG_CONFIG_HOME PATH="$TMP/bin:$PATH" TMPDIR="$TMP/state" \
    XDG_DATA_HOME="$TMP/data" GH_CONFIG_DIR="$TMP/gh" \
    timeout 300 "$RUNNER" --workspace "$TMP/ws" --profile github-pr-reviewer \
    --model openrouter/fake "$@" -- "Reply with the single word OK." \
    <&3 > "$TMP/out" 2> "$TMP/err" || rc=$?
  exec 3>&-
  rm -f "$TMP/stdin"
  elapsed=$((SECONDS - started))
}

start_provider ok
run_live
[ "$rc" -eq 0 ] && grep -q '"type":"text"' "$TMP/out" && [ -s "$TMP/requests" ] \
  && pass "open stdin pipe: run reached the provider and finished in ${elapsed}s" \
  || fail "open stdin pipe: rc=$rc after ${elapsed}s: $(tail -n 5 "$TMP/err")"
# Title generation sends the prompt too, so count within each request.
most="$(awk '{ n = gsub(/Reply with the single word OK\./, ""); if (n > max) max = n } END { print max + 0 }' "$TMP/requests")"
[ "$most" -eq 1 ] && pass "each request carries the prompt once" \
  || fail "a request carried the prompt $most times"

start_provider hang
run_live --provider-timeout 5
[ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 75 ] && grep -q '"type":"error"' "$TMP/out" \
  && pass "silent provider: clean exit $rc in ${elapsed}s: $(grep -o '"message":"[^"]*"' "$TMP/out" | head -n 1)" \
  || fail "silent provider: rc=$rc after ${elapsed}s: $(tail -n 5 "$TMP/err")"

run_live --provider-timeout 600 --idle-timeout 10
grep -q 'stdin: /dev/null' "$TMP/err" && grep -q "127.0.0.1:$(cat "$TMP/port")" "$TMP/err" \
  && [ "$rc" -eq 75 ] \
  && pass "idle watchdog exits 75 and reports the provider connection" \
  || fail "idle watchdog: rc=$rc after ${elapsed}s: $(cat "$TMP/err")"
sed -n '/stdin:/,/Log tail/p' "$TMP/err" | sed 's/^/    /'

start_provider 429
run_live --rate-limit-grace 5
[ "$rc" -eq 76 ] && grep -q 'Rate limit exceeded' "$TMP/err" \
  && pass "rate-limited provider: exit 76 in ${elapsed}s" \
  || fail "rate-limited provider: rc=$rc after ${elapsed}s: $(tail -n 5 "$TMP/err")"

start_provider 503
run_live --rate-limit-grace 5
[ "$rc" -eq 76 ] && grep -q 'Service overloaded' "$TMP/err" \
  && pass "overloaded provider: exit 76 in ${elapsed}s" \
  || fail "overloaded provider: rc=$rc after ${elapsed}s: $(tail -n 5 "$TMP/err")"

start_provider 429-brief
run_live --rate-limit-grace 5
[ "$rc" -eq 0 ] && grep -q '"type":"text"' "$TMP/out" && grep -q ' 429 ' "$TMP/requests" \
  && pass "a retry-after within the grace is waited out: finished in ${elapsed}s" \
  || fail "brief rate limit: rc=$rc after ${elapsed}s: $(tail -n 5 "$TMP/err")"

# A workspace plugin would run inside OpenCode with its credentials. It posts
# to the fake provider when loaded.
start_provider ok
mkdir -p "$TMP/ws/.opencode/plugins/sentinel" || exit 1
printf 'await fetch("http://127.0.0.1:%s/sentinel", { method: "POST", body: "sentinel-plugin-loaded" })\nexport default { id: "sentinel", setup: async () => {} }\n' \
  "$(cat "$TMP/port")" > "$TMP/ws/.opencode/plugins/sentinel/server.js" || exit 1
OPENCODE_CONFIG_PROJECT_DISABLE=0 OPENCODE_DISABLE_PROJECT_CONFIG=0 run_live
rm -rf "$TMP/ws/.opencode"
[ "$rc" -eq 0 ] && ! grep -q sentinel-plugin-loaded "$TMP/requests" \
  && pass "workspace plugins stay out when the caller re-enables project config" \
  || fail "workspace plugin: rc=$rc loaded=$(grep -c sentinel-plugin-loaded "$TMP/requests")"

# expect_shell COMMAND STATUS OUTPUT: the reviewer's shell call ends in STATUS
# with OUTPUT in its result.
expect_shell() {
  start_provider "shell:$1"
  run_live
  result="$(jq -r 'select(.type == "tool_use") | "\(.part.state.status) \(.part.state.output // .part.state.error // "")"' "$TMP/out")"
  [ "$rc" -eq 0 ] && [ "${result%% *}" = "$2" ] && grep -Fq -- "$3" <<< "$result" \
    && pass "profile: $1 -> $2" || fail "profile: $1: rc=$rc result=$result"
}
expect_shell "git status --short" completed ""
expect_shell "touch /state/tmp/denied" error "Permission denied"
expect_shell "gh pr review 1 --approve" error "Permission denied"
expect_shell "gh pr comment 1 --body hi" completed "fake-gh-ran pr comment 1"

[ -z "$(ls -A "$TMP/state")" ] && pass "runner left no disposable state" \
  || fail "runner left state: $(ls "$TMP/state")"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all live opencode runner tests passed"
