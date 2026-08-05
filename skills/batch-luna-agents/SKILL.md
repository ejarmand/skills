---
name: batch-luna-agents
description: Batch independent Codex/Luna CLI workers through one finite-concurrency shell invocation. Use when a parent should fan out many independent tasks without making one tool call per worker.
---

# Batch Luna Agents

Read `/codex-agent` first. It owns each worker's CLI, authority, monitoring,
and result-validation contract; this skill changes only the fan-out boundary.

## Batch

Turn the independent work into numbered jobs with stable labels. Through
exactly one parent-visible shell call, launch one `codex exec` invocation per
job in an `xargs -0 -n 1 -P "$parallelism"` pool. Construct and assess those
invocations under the `/codex-agent` contract. Every worker uses `gpt-5.6-luna`
at `high` reasoning effort.

Validate `parallelism` as a canonical positive decimal matching
`^[1-9][0-9]*$` before calling `xargs`.

Keep each label, absolute workspace, and complete prompt as literal data in its
numbered job directory. Pass only NUL-delimited job-directory names through
`xargs`; read the fields inside the worker and quote every expansion. Never
interpolate job data into shell source, filenames, or the `xargs` template.

GNU `xargs` treats child exit 255 as a stop signal. Have each per-job wrapper
record the worker's real status and result under its job directory, then return
zero to `xargs` so every job can launch. After `xargs` has waited for the whole
pool, aggregate the recorded statuses, emit every stable label with its result
or visible failure, and return nonzero if the pool or any worker failed.
