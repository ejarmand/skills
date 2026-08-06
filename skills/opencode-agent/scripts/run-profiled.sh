#!/usr/bin/env bash
# Run one OpenCode session inside a named bubblewrap authority profile.
#
# Stored OpenCode provider credentials (auth.json) and gh CLI authentication
# are mounted read-only, so `opencode auth login` and `gh auth login` are the
# only credential setup; OpenCode state is disposable.
#
# usage: run-profiled.sh --workspace /abs/path --profile NAME \
#   --model PROVIDER/MODEL -- "PROMPT"

set -u -o pipefail

EX_USAGE=2
EX_CLEANUP=70
EX_SETUP=71

err() { printf 'run-profiled: %s\n' "$*" >&2; }
usage() {
  err 'usage: run-profiled.sh --workspace /abs/path --profile NAME --model PROVIDER/MODEL -- "PROMPT"'
  exit "$EX_USAGE"
}

workspace=""
profile=""
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) [ $# -ge 2 ] || usage; workspace="$2"; shift 2 ;;
    --profile)   [ $# -ge 2 ] || usage; profile="$2"; shift 2 ;;
    --model)     [ $# -ge 2 ] || usage; model="$2"; shift 2 ;;
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
[ "$(uname -s)" = Linux ] || { err 'profiled OpenCode dispatch requires Linux'; exit "$EX_SETUP"; }
[ -d "$workspace" ] || { err "workspace is not a directory: $workspace"; exit "$EX_USAGE"; }
workspace="$(cd "$workspace" && pwd -P)" || { err 'cannot resolve workspace'; exit "$EX_USAGE"; }

script_dir="$(cd "$(dirname "$0")" && pwd -P)" || { err 'cannot resolve script directory'; exit "$EX_SETUP"; }
skill_dir="$(dirname "$script_dir")"
repo_skills="$(cd "$skill_dir/.." && pwd -P)" || { err 'cannot resolve skills directory'; exit "$EX_SETUP"; }
profile_file="$skill_dir/profiles/$profile/config.json"
[ -f "$profile_file" ] || { err "unknown or incomplete profile: $profile"; exit "$EX_USAGE"; }

command -v bwrap >/dev/null 2>&1 || { err 'bubblewrap is required'; exit "$EX_SETUP"; }
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
state_root="$(mktemp -d "${TMPDIR:-/tmp}/opencode-profile.XXXXXXXX")" \
  || { err 'cannot create disposable OpenCode state'; exit "$EX_SETUP"; }
chmod 700 "$state_root" || { rm -rf "$state_root"; exit "$EX_SETUP"; }
mkdir -p "$state_root"/{home,config/gh,data/opencode,cache,xdg-state,tmp} \
  || { rm -rf "$state_root"; exit "$EX_SETUP"; }
touch "$state_root/data/opencode/auth.json" || { rm -rf "$state_root"; exit "$EX_SETUP"; }

bwrap \
  --die-with-parent --new-session \
  --unshare-all --unshare-user --share-net --disable-userns \
  --ro-bind /usr /usr \
  --ro-bind-try /bin /bin \
  --ro-bind-try /sbin /sbin \
  --ro-bind-try /lib /lib \
  --ro-bind-try /lib64 /lib64 \
  --ro-bind /etc /etc \
  --ro-bind-try /run/systemd/resolve /run/systemd/resolve \
  --proc /proc --dev /dev --tmpfs /tmp \
  --dir /opt \
  --ro-bind "$opencode_bin" /opt/opencode \
  --ro-bind "$gh_bin" /opt/gh \
  --ro-bind "$workspace" /workspace \
  --ro-bind "$repo_skills" /skills \
  --bind "$state_root" /state \
  --ro-bind "$auth_json" /state/data/opencode/auth.json \
  --ro-bind "$gh_config" /state/config/gh \
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
  /opt/opencode run --pure --format json --agent reviewer --model "$model" -- "$prompt"
child_exit=$?

if ! rm -rf "$state_root"; then
  err "failed to remove disposable state $state_root"
  [ "$child_exit" -ne 0 ] || exit "$EX_CLEANUP"
fi
exit "$child_exit"
