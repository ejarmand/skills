---
name: batch-subagents
description: Run batches of independent agent tasks with stable job labels, using harness delegation or CLI fallbacks.
---

# Batch subagents

Turn independent work into jobs with stable labels, such as one review per file
or one validity check per graph edge. Give each worker its complete prompt,
workspace, and expected result. Collect a result or visible failure for every
label.

Use the harness's delegation tools, including Orchestrator V2, when they support
the jobs. Follow their dispatch and lifecycle instructions. Use
`/cross-provider-agent` only for CLI fallback workers or existing CLI sessions.

## CLI pool

Keep each label, absolute workspace, and complete prompt as literal data in a
numbered job directory. Run a bounded `xargs -0 -n 1 -P "$parallelism"` pool.

GNU `xargs` treats child exit 255 as a stop signal. Have each per-job wrapper
record the worker's real status and result under its job directory, then return
zero to `xargs` so every job can launch. Emit every label with its result or
visible failure, and return nonzero if the pool or any task remains incomplete.
