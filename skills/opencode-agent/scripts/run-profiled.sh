#!/usr/bin/env bash
# Run one OpenCode session inside a named bubblewrap authority profile.
#
# Stored OpenCode provider credentials (auth.json) and gh CLI authentication
# are mounted read-only, so `opencode auth login` and `gh auth login` are the
# only credential setup; OpenCode state is disposable.
#
# usage: run-profiled.sh --workspace /abs/path --profile NAME \
#   --model PROVIDER/MODEL [--variant LEVEL] [--agent NAME] \
#   [--provider-timeout SECONDS] [--rate-limit-grace SECONDS] \
#   [--idle-timeout SECONDS] -- "PROMPT"
#
# --agent selects the profile's primary agent (default: reviewer).
# --variant passes a provider-specific reasoning setting through unchanged.
# --provider-timeout bounds the wait for a provider's response headers and
# between stream chunks (default 120; OpenCode's own default is 300 per
# attempt, retried about nine times, with no output). Profile values win.
# --rate-limit-grace stops a run once OpenCode logs a rate-limit error and then
# emits no event for that long (default 60), and exits EX_RATE_LIMITED;
# OpenCode otherwise waits out any retry-after silently.
# --idle-timeout stops a run that emits no event for that long (default 1800),
# reports what OpenCode was waiting on, and exits EX_STALL (#53).

set -u -o pipefail

EX_USAGE=2
EX_CLEANUP=70
EX_SETUP=71
EX_STALL=75
EX_RATE_LIMITED=76

err() { printf 'run-profiled: %s\n' "$*" >&2; }
usage() {
  err 'usage: run-profiled.sh --workspace /abs/path --profile NAME --model PROVIDER/MODEL [--variant LEVEL] [--agent NAME] [--provider-timeout SECONDS] [--rate-limit-grace SECONDS] [--idle-timeout SECONDS] -- "PROMPT"'
  exit "$EX_USAGE"
}

workspace=""
profile=""
model=""
variant=""
agent="reviewer"
provider_timeout=120
rate_limit_grace=60
idle_timeout=1800
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) [ $# -ge 2 ] || usage; workspace="$2"; shift 2 ;;
    --profile)   [ $# -ge 2 ] || usage; profile="$2"; shift 2 ;;
    --model)     [ $# -ge 2 ] || usage; model="$2"; shift 2 ;;
    --variant)   [ $# -ge 2 ] && [ -n "$2" ] || usage; variant="$2"; shift 2 ;;
    --agent)     [ $# -ge 2 ] || usage; agent="$2"; shift 2 ;;
    --provider-timeout) [ $# -ge 2 ] || usage; provider_timeout="$2"; shift 2 ;;
    --rate-limit-grace) [ $# -ge 2 ] || usage; rate_limit_grace="$2"; shift 2 ;;
    --idle-timeout) [ $# -ge 2 ] || usage; idle_timeout="$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -n "$workspace" ] && [ -n "$profile" ] && [ -n "$model" ] || usage
[ $# -eq 1 ] || usage
prompt="$1"
[ -n "$prompt" ] || usage
case "$workspace" in /*) ;; *) err "workspace must be absolute: $workspace"; exit "$EX_USAGE" ;; esac
case "$model" in */*) ;; *) err "model must use provider/model form: $model"; exit "$EX_USAGE" ;; esac
case "$variant" in ""|[a-z]*) ;; *) err "variant must be a plain word: $variant"; exit "$EX_USAGE" ;; esac
for seconds in "$provider_timeout" "$rate_limit_grace" "$idle_timeout"; do
  case "$seconds" in ""|0*|*[!0-9]*) err "timeouts must be positive integers: $seconds"; exit "$EX_USAGE" ;; esac
done
variant_args=()
[ -z "$variant" ] || variant_args=(--variant "$variant")
[ "$(uname -s)" = Linux ] || { err 'profiled OpenCode dispatch requires Linux'; exit "$EX_SETUP"; }
[ -d "$workspace" ] || { err "workspace is not a directory: $workspace"; exit "$EX_USAGE"; }
workspace="$(cd "$workspace" && pwd -P)" || { err 'cannot resolve workspace'; exit "$EX_USAGE"; }

script_dir="$(cd "$(dirname "$0")" && pwd -P)" || { err 'cannot resolve script directory'; exit "$EX_SETUP"; }
skill_dir="$(dirname "$script_dir")"
repo_skills="$(cd "$skill_dir/.." && pwd -P)" || { err 'cannot resolve skills directory'; exit "$EX_SETUP"; }
profile_file="$skill_dir/profiles/$profile/config.json"
[ -f "$profile_file" ] || { err "unknown or incomplete profile: $profile"; exit "$EX_USAGE"; }

command -v jq >/dev/null 2>&1 || { err 'jq is required'; exit "$EX_SETUP"; }
# OpenCode silently swaps a subagent or unknown name for its default agent.
[ "$(jq -r --arg agent "$agent" '.agent[$agent].mode // empty' "$profile_file")" = primary ] \
  || { err "agent is not a primary agent of profile $profile: $agent"; exit "$EX_USAGE"; }

command -v bwrap >/dev/null 2>&1 || { err 'bubblewrap is required'; exit "$EX_SETUP"; }
# --disable-userns arrived in bubblewrap 0.8; older hosts still get --unshare-user.
userns_args=()
bwrap --help 2>&1 | grep -q -- --disable-userns && userns_args=(--disable-userns)
opencode_bin="$(command -v opencode)" || { err 'opencode is required'; exit "$EX_SETUP"; }
opencode_bin="$(readlink -f "$opencode_bin")" || { err 'cannot resolve opencode executable'; exit "$EX_SETUP"; }
gh_bin="$(command -v gh)" || { err 'GitHub CLI is required'; exit "$EX_SETUP"; }
gh_bin="$(readlink -f "$gh_bin")" || { err 'cannot resolve GitHub CLI executable'; exit "$EX_SETUP"; }

auth_json="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json"
[ -f "$auth_json" ] \
  || { err "no OpenCode provider credentials in $auth_json; run opencode auth login first"; exit "$EX_SETUP"; }
gh_config="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
[ -f "$gh_config/hosts.yml" ] \
  || { err "no gh authentication in $gh_config; run gh auth login first"; exit "$EX_SETUP"; }

# A stalled provider otherwise leaves OpenCode silent for up to 300 s per attempt.
config_json="$(jq -c --arg id "${model%%/*}" --argjson ms "$((provider_timeout * 1000))" \
  '.provider[$id].options |= {headerTimeout: $ms, chunkTimeout: $ms} + .' "$profile_file")" \
  || { err 'cannot read profile config'; exit "$EX_SETUP"; }
run_dir="$(mktemp -d "${TMPDIR:-/tmp}/opencode-profile.XXXXXXXX")" \
  || { err 'cannot create disposable OpenCode state'; exit "$EX_SETUP"; }
child=""
cleanup() {
  [ -z "$child" ] || kill "$child" 2>/dev/null
  rm -rf "$run_dir"
}
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
setup_fail() { cleanup; exit "$EX_SETUP"; }

chmod 700 "$run_dir" || setup_fail
state_root="$run_dir/state"
events="$run_dir/events"
mkdir -p "$state_root"/{home,config/gh,config/opencode,data/opencode,cache/opencode,xdg-state,tmp} \
  || setup_fail
touch "$state_root/data/opencode/auth.json" || setup_fail
# OpenCode npm-installs its plugin package into any writable config directory on
# every start; a read-only one (with the .gitignore it would write) skips that.
touch "$state_root/config/opencode/.gitignore" || setup_fail
# Seed the models.dev catalog from the host cache when present: a fresh sandbox
# otherwise fetches it at startup, and a failed fetch under concurrency makes
# every model "not found". Copy it, keeping its age, so a stale catalog still
# refreshes into disposable state.
models_cache="${XDG_CACHE_HOME:-$HOME/.cache}/opencode/models.json"
if [ -f "$models_cache" ]; then
  cp -p "$models_cache" "$state_root/cache/opencode/models.json" || setup_fail
fi
mkfifo "$events" || setup_fail

bwrap \
  --die-with-parent --new-session \
  --unshare-all --unshare-user --share-net "${userns_args[@]}" \
  --ro-bind /usr /usr \
  --ro-bind-try /bin /bin \
  --ro-bind-try /sbin /sbin \
  --ro-bind-try /lib /lib \
  --ro-bind-try /lib64 /lib64 \
  --ro-bind /etc /etc \
  --ro-bind-try /run/systemd/resolve /run/systemd/resolve \
  --ro-bind-try /run/resolvconf /run/resolvconf \
  --proc /proc --dev /dev --tmpfs /tmp \
  --dir /opt \
  --ro-bind "$opencode_bin" /opt/opencode \
  --ro-bind "$gh_bin" /opt/gh \
  --ro-bind "$workspace" /workspace \
  --ro-bind "$repo_skills" /skills \
  --bind "$state_root" /state \
  --ro-bind "$auth_json" /state/data/opencode/auth.json \
  --ro-bind "$gh_config" /state/config/gh \
  --ro-bind "$state_root/config/opencode" /state/config/opencode \
  --chdir /workspace \
  --setenv PATH /opt:/usr/bin:/bin \
  --setenv HOME /state/home \
  --setenv XDG_CONFIG_HOME /state/config \
  --setenv XDG_DATA_HOME /state/data \
  --setenv XDG_CACHE_HOME /state/cache \
  --setenv XDG_STATE_HOME /state/xdg-state \
  --setenv TMPDIR /state/tmp \
  --unsetenv OPENCODE_CONFIG \
  --unsetenv OPENCODE_CONFIG_DIR \
  --setenv OPENCODE_DISABLE_PROJECT_CONFIG 1 \
  --setenv OPENCODE_DISABLE_CLAUDE_CODE 1 \
  --setenv OPENCODE_DISABLE_EXTERNAL_SKILLS 1 \
  --setenv OPENCODE_PURE 1 \
  --setenv OPENCODE_CONFIG_CONTENT "$config_json" \
  /opt/opencode run --pure --format json --agent "$agent" --model "$model" "${variant_args[@]}" -- "$prompt" \
  < /dev/null > "$events" &
child=$!

# Report what the stalled OpenCode process (the first one below bwrap) waits on.
report_stall() {
  local parents="$child" rows="" pid=""
  while [ -n "$parents" ]; do
    rows="$(ps -o pid=,comm= --ppid "$parents")" || break
    pid="$(awk '$2 == "opencode" { print $1; exit }' <<< "$rows")"
    [ -z "$pid" ] || break
    parents="$(awk '{ print $1 }' <<< "$rows" | paste -sd, -)"
  done
  [ -n "$pid" ] || { err 'no OpenCode process found'; return; }
  err "OpenCode pid $pid stdin: $(readlink "/proc/$pid/fd/0")"
  err "OpenCode pid $pid wchan: $(cat "/proc/$pid/wchan")"
  err "OpenCode pid $pid established TCP connections:"
  ss -tnpH state established | grep -F "pid=$pid," >&2 || err '  none'
}

# Relay events byte for byte, waking each second to check the log and the idle
# clock. read -t keeps a partial line on timeout, so pieces collect in buf.
log="$state_root/data/opencode/log/opencode.log"
# A rate-limit stream error logged after the last event (past log_seen bytes).
# Title generation (small=true) failing does not block the run.
rate_limit_re='message="stream error".* small=false .*error\.error=.*(\b429\b|rate[ _-]?limit|too many requests)'
buf=""
line=""
stop=""
last_event=$SECONDS
log_seen=0
limited=""
limited_at=0
while :; do
  read_status=0
  IFS= read -r -t 1 line || read_status=$?
  if [ "$read_status" -eq 0 ]; then
    log_seen="$(stat -c %s "$log" 2>/dev/null)" || log_seen=0
    printf '%s\n' "$buf$line"
    buf="" line="" limited="" last_event=$SECONDS
    continue
  fi
  [ "$read_status" -gt 128 ] || break
  [ -z "$line" ] || { buf+="$line"; line=""; last_event=$SECONDS; }
  if [ -z "$limited" ]; then
    limited="$(tail -c +"$((log_seen + 1))" "$log" 2>/dev/null | grep -m 1 -Ei -- "$rate_limit_re")"
    limited_at=$SECONDS
  elif [ $((SECONDS - limited_at)) -ge "$rate_limit_grace" ]; then
    stop=rate-limited; break
  fi
  [ $((SECONDS - last_event)) -lt "$idle_timeout" ] || { stop=idle; break; }
done < "$events"
[ -z "$buf$line" ] || printf '%s' "$buf$line"

case "$stop" in
  idle)
    err "no OpenCode event for ${idle_timeout}s; stopped the run."
    report_stall
    kill "$child" 2>/dev/null
    wait "$child"
    err 'Log tail:'
    tail -n 20 "$log" >&2 2>/dev/null
    child_exit="$EX_STALL" ;;
  rate-limited)
    kill "$child" 2>/dev/null
    wait "$child"
    err "provider rate limit and no OpenCode event for ${rate_limit_grace}s; stopped the run:"
    printf '%s\n' "$limited" >&2
    child_exit="$EX_RATE_LIMITED" ;;
  *)
    wait "$child"
    child_exit=$? ;;
esac
child=""

if ! rm -rf "$run_dir"; then
  err "failed to remove disposable state $run_dir"
  [ "$child_exit" -ne 0 ] || exit "$EX_CLEANUP"
fi
exit "$child_exit"
