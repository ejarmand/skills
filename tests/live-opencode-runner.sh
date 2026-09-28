#!/usr/bin/env bash
# Opt-in live tests for skills/opencode-agent/scripts/run-profiled.sh (#53).
#
# Runs the real opencode inside real bubblewrap against a local fake
# OpenAI-compatible provider, so no network or provider account is needed:
# the profile's openrouter baseURL points at the fake, and throwaway
# credentials stand in for the stored ones. Checks that an open stdin pipe no longer
# hangs, that a provider which never answers ends in a clean error, that a
# long retry-after on a 429 or 503 exits 76, and that the idle watchdog reports
# what OpenCode was waiting on. Takes about two minutes.
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
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/gh" && chmod +x "$TMP/bin/gh" || exit 1
echo '{"openrouter":{"type":"api","key":"sk-live-test"}}' > "$TMP/data/opencode/auth.json" || exit 1
touch "$TMP/gh/hosts.yml" || exit 1
git -C "$TMP/ws" init -q && echo hello > "$TMP/ws/README" && git -C "$TMP/ws" add README \
  && git -C "$TMP/ws" -c user.name=test -c user.email=test@example.com commit -qm init || exit 1

cat > "$TMP/fakeprov.py" <<'PY'
# Fake OpenAI-compatible provider. MODE ok: stream "OK"; hang: accept and never
# answer; 429 or 503: rate limit or overload with a 900 s retry-after. Writes
# its port to argv[2].
import http.server, json, sys, time
mode = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        if mode == "hang":
            time.sleep(3600)
        if mode in ("429", "503"):
            message = "Rate limit exceeded" if mode == "429" else "Service overloaded"
            body = json.dumps({"error": {"message": message, "code": int(mode)}}).encode()
            self.send_response(int(mode))
            self.send_header("retry-after", "900")
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        chunk = lambda delta, finish: "data: " + json.dumps({
            "id": "fake", "object": "chat.completion.chunk", "created": 0, "model": "fake",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            **({"usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}} if finish else {}),
        }) + "\n\n"
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

start_provider hang
run_live --provider-timeout 5
[ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 75 ] && grep -q '"type":"error"' "$TMP/out" \
  && pass "silent provider: clean exit $rc in ${elapsed}s: $(grep -o '"name":"[A-Za-z]*"' "$TMP/out" | head -n 1)" \
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

[ -z "$(ls -A "$TMP/state")" ] && pass "runner left no disposable state" \
  || fail "runner left state: $(ls "$TMP/state")"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all live opencode runner tests passed"
