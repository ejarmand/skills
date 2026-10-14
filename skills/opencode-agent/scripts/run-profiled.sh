#!/usr/bin/env bash
# Run one OpenCode session inside a named bubblewrap authority profile.
#
# The selected provider's stored OpenCode credential is copied into disposable
# OpenCode state and gh CLI authentication is mounted read-only, so
# `opencode auth login` and `gh auth login` are the only credential setup.
#
# usage: run-profiled.sh --workspace /abs/path --profile NAME \
#   --model PROVIDER/MODEL [--variant LEVEL] [--agent NAME] \
#   [--provider-timeout SECONDS] [--rate-limit-grace SECONDS] \
#   [--idle-timeout SECONDS] -- "PROMPT"
#
# --agent selects the profile's primary agent (default: reviewer).
# --variant passes a provider-specific reasoning setting through unchanged, as
# the PROVIDER/MODEL#LEVEL form OpenCode 2 takes.
# --provider-timeout bounds the wait for a provider's response headers and
# between stream chunks (default 120; OpenCode's own default is 300 per
# attempt, retried about nine times, with no output). Profile values win.
# --rate-limit-grace is the longest retry-after OpenCode may wait out after a
# provider rate limit or overload (default 60). The runner's plugin declines a
# longer wait, so the run fails with the provider's error and exits
# EX_RATE_LIMITED; OpenCode otherwise waits silently, up to 15 minutes a retry.
# --idle-timeout stops a run that emits no event for that long (default 1800),
# reports what OpenCode was waiting on, and exits EX_STALL (#53).
# The prompt must not start with "-": OpenCode 2 sends anything after its own
# "--" twice, so the prompt goes to it as a plain argument.

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
case "$prompt" in -*) err 'prompt must not start with "-"'; exit "$EX_USAGE" ;; esac
case "$workspace" in /*) ;; *) err "workspace must be absolute: $workspace"; exit "$EX_USAGE" ;; esac
case "$model" in */*) ;; *) err "model must use provider/model form: $model"; exit "$EX_USAGE" ;; esac
case "$variant" in ""|[a-z]*) ;; *) err "variant must be a plain word: $variant"; exit "$EX_USAGE" ;; esac
for seconds in "$provider_timeout" "$rate_limit_grace" "$idle_timeout"; do
  case "$seconds" in ""|0*|*[!0-9]*) err "timeouts must be positive integers: $seconds"; exit "$EX_USAGE" ;; esac
done
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

# git, and gh through it, must reach the repository's shared git dir, which a
# linked worktree or a subdirectory checkout keeps outside the workspace.
git_args=()
common_dir="$(git -C "$workspace" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common_dir=""
case "$common_dir" in ""|"$workspace"/*) ;; *) git_args=(--ro-bind "$common_dir" "$common_dir") ;; esac

gh_config="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}"
[ -f "$gh_config/hosts.yml" ] \
  || { err "no gh authentication in $gh_config; run gh auth login first"; exit "$EX_SETUP"; }

# A stalled provider otherwise leaves OpenCode silent for up to 300 s per
# attempt. The plugin, read from the /skills mount, bounds rate-limit waits.
config_json="$(jq -c --arg id "${model%%/*}" --argjson ms "$((provider_timeout * 1000))" \
  --arg plugin "/skills/$(basename "$skill_dir")/plugins/decline-long-retry" \
  --argjson grace "$((rate_limit_grace * 1000))" \
  '.provider[$id].options |= {headerTimeout: $ms, chunkTimeout: $ms} + .
   | .plugins += [{package: $plugin, options: {graceMs: $grace}}]' "$profile_file")" \
  || { err 'cannot read profile config'; exit "$EX_SETUP"; }
# OpenCode 2 always reads the system config directory, plugins included.
etc_args=()
[ ! -d /etc/opencode ] || etc_args=(--tmpfs /etc/opencode)
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
mkfifo "$events" || setup_fail

# OpenCode 2 keeps credentials in its database and no longer reads auth.json,
# so import the selected provider's into the disposable state. A provider with
# none stored (a free model, a custom endpoint) runs without one. OpenCode
# unpacks native libraries into TMPDIR, so both calls use the disposable one.
credentials="$(TMPDIR="$state_root/tmp" "$opencode_bin" auth export --standalone "${model%%/*}" 2>/dev/null < /dev/null)" \
  || credentials='[]'
if [ "$(jq 'length' <<< "$credentials" 2>/dev/null)" != 0 ]; then
  (umask 077 && printf '%s' "$credentials" > "$run_dir/credentials.json") || setup_fail
  (cd "$state_root" && env -u OPENCODE_CONFIG -u OPENCODE_CONFIG_DIR \
    HOME="$state_root/home" XDG_CONFIG_HOME="$state_root/config" XDG_DATA_HOME="$state_root/data" \
    XDG_CACHE_HOME="$state_root/cache" XDG_STATE_HOME="$state_root/xdg-state" TMPDIR="$state_root/tmp" \
    OPENCODE_CONFIG_PROJECT_DISABLE=1 OPENCODE_DISABLE_PROJECT_CONFIG=1 \
    "$opencode_bin" auth import --standalone "$run_dir/credentials.json") < /dev/null > /dev/null 2>&1 \
    || { err "cannot import the stored ${model%%/*} credential"; setup_fail; }
  rm -f "$run_dir/credentials.json" || setup_fail
fi

bwrap \
  --die-with-parent --new-session \
  --unshare-all --unshare-user --share-net "${userns_args[@]}" \
  --ro-bind /usr /usr \
  --ro-bind-try /bin /bin \
  --ro-bind-try /sbin /sbin \
  --ro-bind-try /lib /lib \
  --ro-bind-try /lib64 /lib64 \
  --ro-bind /etc /etc \
  "${etc_args[@]}" \
  --ro-bind-try /run/systemd/resolve /run/systemd/resolve \
  --ro-bind-try /run/resolvconf /run/resolvconf \
  --proc /proc --dev /dev --tmpfs /tmp \
  --dir /opt \
  --ro-bind "$opencode_bin" /opt/opencode \
  --ro-bind "$gh_bin" /opt/gh \
  --ro-bind "$workspace" "$workspace" \
  "${git_args[@]}" \
  --ro-bind "$repo_skills" /skills \
  --bind "$state_root" /state \
  --ro-bind "$gh_config" /state/config/gh \
  --ro-bind "$state_root/config/opencode" /state/config/opencode \
  --chdir "$workspace" \
  --setenv PATH /opt:/usr/bin:/bin \
  --setenv HOME /state/home \
  --setenv XDG_CONFIG_HOME /state/config \
  --setenv XDG_DATA_HOME /state/data \
  --setenv XDG_CACHE_HOME /state/cache \
  --setenv XDG_STATE_HOME /state/xdg-state \
  --setenv TMPDIR /state/tmp \
  --unsetenv OPENCODE_CONFIG \
  --unsetenv OPENCODE_CONFIG_DIR \
  --setenv OPENCODE_CONFIG_PROJECT_DISABLE 1 \
  --setenv OPENCODE_DISABLE_PROJECT_CONFIG 1 \
  --setenv OPENCODE_CONFIG_CONTENT "$config_json" \
  /opt/opencode run --standalone --format json --agent "$agent" --model "$model${variant:+#$variant}" "$prompt" \
  < /dev/null > "$events" &
child=$!

# Report what each OpenCode process below bwrap waits on: the run client and
# the standalone server it starts, which holds the provider connections.
report_stall() {
  local parents="$child" rows="" pids="" pid=""
  while [ -n "$parents" ]; do
    rows="$(ps -o pid=,comm= --ppid "$parents")" || break
    pids+=" $(awk '$2 == "opencode" { print $1 }' <<< "$rows")"
    parents="$(awk '{ print $1 }' <<< "$rows" | paste -sd, -)"
  done
  [ -n "${pids// /}" ] || { err 'no OpenCode process found'; return; }
  for pid in $pids; do
    err "OpenCode pid $pid stdin: $(readlink "/proc/$pid/fd/0")"
    err "OpenCode pid $pid wchan: $(cat "/proc/$pid/wchan")"
    err "OpenCode pid $pid established TCP connections:"
    command -v ss >/dev/null 2>&1 || { err '  unavailable: ss is not installed'; continue; }
    ss -tnpH state established | grep -F "pid=$pid," >&2 || err '  none'
  done
}

# Relay events byte for byte, waking each second to check the idle clock.
# read -t keeps a partial line on timeout, so pieces collect in buf.
log="$state_root/data/opencode/log/opencode.log"
buf=""
line=""
stop=""
last_error=""
last_event=$SECONDS
while :; do
  read_status=0
  IFS= read -r -t 1 line || read_status=$?
  if [ "$read_status" -eq 0 ]; then
    printf '%s\n' "$buf$line"
    case "$buf$line" in '{"type":"error"'*) last_error="$buf$line" ;; esac
    buf="" line="" last_event=$SECONDS
  elif [ "$read_status" -gt 128 ]; then
    [ -z "$line" ] || { buf+="$line"; line=""; last_event=$SECONDS; }
  else
    break
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
  *)
    wait "$child"
    child_exit=$?
    # A failed run whose last error is a rate limit or overload, whether the
    # plugin declined a long wait or OpenCode ran out of retries.
    status="$(jq -r '.error.status // empty' <<< "$last_error" 2>/dev/null)"
    case "$child_exit:$status" in
      0:*) ;;
      *:429|*:503|*:529)
        err "provider rate limit or overload; stopped the run rather than wait longer than ${rate_limit_grace}s:"
        jq -r '.error.message' <<< "$last_error" >&2
        child_exit="$EX_RATE_LIMITED" ;;
    esac ;;
esac
child=""

if ! rm -rf "$run_dir"; then
  err "failed to remove disposable state $run_dir"
  [ "$child_exit" -ne 0 ] || exit "$EX_CLEANUP"
fi
exit "$child_exit"
