---
name: batch-luna-agents
description: Batch independent Codex/Luna CLI workers through one finite-concurrency shell invocation. Use when a parent should fan out many independent tasks without making one tool call per worker.
---

# Batch Luna Agents

Read `/codex-agent` first. It owns each worker's CLI, authority, monitoring,
and result-validation contract; this skill owns only the process pool.

## Batch

Turn the independent work into numbered jobs with stable labels. In one shell
tool call, materialize each job as a directory containing `label`, `workspace`,
and `prompt` files, then pass only those directory names through a finite
`xargs -P` pool. Use `gpt-5.6-luna` at `high` reasoning effort for every
worker.

Keep prompts, labels, and workspace paths as data. Write them with quoted,
non-expanding heredocs whose terminators do not occur in the values; never
splice them into shell source, filenames, or an `xargs` command template.
Quote every expansion, pass the prompt on stdin, and delimit the generated job
directory names with NUL bytes. Labels identify results but grant no authority.

Use this shape inside that single shell call, filling its job-materialization
section with the current batch:

```bash
set -u -o pipefail
batch_root="$(mktemp -d "${TMPDIR:-/tmp}/luna-batch.XXXXXXXX")" || exit 1
trap 'rm -rf "$batch_root"' EXIT
jobs="$batch_root/jobs"
mkdir "$jobs" || exit 1

parallelism=4                 # choose a positive finite value; never use -P 0
sandbox=read-only             # resolve least authority through /codex-agent
case "$parallelism" in *[!0-9]*|0|'') exit 2 ;; esac
case "$sandbox" in read-only|workspace-write) ;; *) exit 2 ;; esac

# Create $jobs/000001, $jobs/000002, ... here. Put the stable label,
# absolute workspace, and complete prompt in separate literal data files.
set -- "$jobs"/[0-9]*
[ -d "$1" ] || exit 2

pool_rc=0
find "$jobs" -mindepth 1 -maxdepth 1 -type d -print0 |
  xargs -0 -n 1 -P "$parallelism" sh -c '
    sandbox=$1
    job=$2
    workspace=$(cat "$job/workspace") || { printf "%s\n" 70 > "$job/exit"; exit 0; }
    codex exec --json -c '"'"'model_reasoning_effort="high"'"'"' \
      --sandbox "$sandbox" -C "$workspace" --model gpt-5.6-luna \
      --output-last-message "$job/result" - \
      < "$job/prompt" > "$job/events" 2> "$job/stderr"
    rc=$?
    printf "%s\n" "$rc" > "$job/exit"
    exit 0
  ' sh "$sandbox" || pool_rc=$?

final_rc=$pool_rc
for job in "$jobs"/[0-9]*; do
  printf '=== '
  cat "$job/label"
  printf ' ===\n'
  rc=$(cat "$job/exit" 2>/dev/null || printf 70)
  if [ "$rc" -eq 0 ] &&
     [ -f "$job/result" ] &&
     tail -n 1 "$job/events" | grep -q '^{"type":"turn.completed"' &&
     ! grep -Eq '^{"type":"(turn.failed|error)"' "$job/events"; then
    cat "$job/result"
  else
    printf 'FAILED (exit %s)\n' "$rc"
    cat "$job/stderr" 2>/dev/null
    grep -E '^{"type":"(turn.failed|error)"' "$job/events" 2>/dev/null || true
    final_rc=1
  fi
  printf '\n'
done
exit "$final_rc"
```

The shell call must wait for `xargs`, print every labeled result or failure,
and return nonzero when the pool or any worker fails. Split batches when jobs
need different authority; do not add retries or resume failed workers here.
