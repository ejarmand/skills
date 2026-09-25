#!/usr/bin/env bash
# Run one OpenCode session inside a named bubblewrap authority profile.
#
# Stored OpenCode provider credentials (auth.json) and gh CLI authentication
# are mounted read-only, so `opencode auth login` and `gh auth login` are the
# only credential setup; OpenCode state is disposable.
#
# usage: run-profiled.sh --workspace /abs/path --profile NAME \
#   --model PROVIDER/MODEL [--variant LEVEL] [--agent NAME] \
#   [--idle-timeout SECONDS] -- "PROMPT"
#
# --agent selects the profile's primary agent (default: reviewer).
# --variant passes a provider-specific reasoning setting through unchanged.
# --idle-timeout stops a run that emits no event for that long (default 600)
# and exits EX_STALL; OpenCode can otherwise hang indefinitely (#53).

set -u -o pipefail

EX_USAGE=2
EX_CLEANUP=70
EX_SETUP=71
EX_STALL=75

err() { printf 'run-profiled: %s\n' "$*" >&2; }
usage() {
  err 'usage: run-profiled.sh --workspace /abs/path --profile NAME --model PROVIDER/MODEL [--variant LEVEL] [--agent NAME] [--idle-timeout SECONDS] -- "PROMPT"'
  exit "$EX_USAGE"
}

workspace=""
profile=""
model=""
variant=""
agent="reviewer"
idle_timeout=600
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) [ $# -ge 2 ] || usage; workspace="$2"; shift 2 ;;
    --profile)   [ $# -ge 2 ] || usage; profile="$2"; shift 2 ;;
    --model)     [ $# -ge 2 ] || usage; model="$2"; shift 2 ;;
    --variant)   [ $# -ge 2 ] && [ -n "$2" ] || usage; variant="$2"; shift 2 ;;
    --agent)     [ $# -ge 2 ] || usage; agent="$2"; shift 2 ;;
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
case "$idle_timeout" in ""|0|*[!0-9]*) err "idle timeout must be a positive integer: $idle_timeout"; exit "$EX_USAGE" ;; esac
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

config_json="$(< "$profile_file")" || { err 'cannot read profile config'; exit "$EX_SETUP"; }
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
  > "$events" &
child=$!

line=""
read_status=0
while :; do
  IFS= read -r -t "$idle_timeout" line || { read_status=$?; break; }
  printf '%s\n' "$line"
done < "$events"
[ -z "$line" ] || printf '%s' "$line"

if [ "$read_status" -gt 128 ]; then
  kill "$child" 2>/dev/null
  wait "$child"
  err "no OpenCode event for ${idle_timeout}s; stopped the run. Log tail:"
  tail -n 20 "$state_root/data/opencode/log/opencode.log" >&2 2>/dev/null
  child_exit="$EX_STALL"
else
  wait "$child"
  child_exit=$?
fi
child=""

if ! rm -rf "$run_dir"; then
  err "failed to remove disposable state $run_dir"
  [ "$child_exit" -ne 0 ] || exit "$EX_CLEANUP"
fi
exit "$child_exit"
