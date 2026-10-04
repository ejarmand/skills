---
name: code-review
description: Review the changes since a fixed point (commit, branch, tag, or merge-base) along two axes — Standards (does the code follow this repo's documented coding standards?) and Spec (does the code match what the originating issue/PRD asked for?). Use when the user wants a branch, PR, or work-in-progress reviewed, or asks to "review since X".
---

Two-axis review of the diff between `HEAD` and a fixed point the user supplies:

- **Standards** — does the code conform to this repo's documented coding standards?
- **Spec** — does the code faithfully implement the originating issue / PRD / spec?

Both axes run as **parallel sub-agents** so they don't pollute each other's context, then this skill aggregates their findings.

## Process

### 1. Pin the fixed point

Use the requested fixed point, or the PR's base when reviewing a PR. Ask only
when the intended comparison is unclear.

Capture the diff command once: `git diff <fixed-point>...HEAD` (three-dot, so the comparison is against the merge-base). Also note the list of commits via `git log <fixed-point>..HEAD --oneline`.

Use the caller's pinned base and head OIDs when supplied. Otherwise resolve the
fixed point before dispatching children. An empty diff needs only a no-changes
report.

For named CLI review profiles, issue shell commands separately; chained commands
can be denied. Those profiles allow `git diff`, `git log`, `git show`, and
`git status`.

### 2. Identify the spec source

Look for the originating spec, in this order:

1. Issue references in the commit messages (`#123`, `Closes #45`, etc.) — fetch per the work-record contract in [`../wayfinder/WORK-RECORDS.md`](../wayfinder/WORK-RECORDS.md).
2. A path the user passed as an argument.

### 3. Identify the standards sources

Anything in the repo that documents how code should be written, such as `CODING_STANDARDS.md` or `CONTRIBUTING.md`.

On top of whatever the repo documents, the Standards axis always carries the **unified code standard** in [`../codebase-design/STANDARD.md`](../codebase-design/STANDARD.md). 

### 4. Spawn both sub-agents in parallel

Use the harness's delegation tools to run both axes in separate contexts.
Children return their reports to this coordinator.

**Standards sub-agent prompt** — include:

- The full diff command and commit list.
- The list of standards-source files you found in step 3, **plus the full contents of `../codebase-design/STANDARD.md`** pasted into the prompt. 
- The brief: "Report — per file/hunk where relevant — (a) every place the diff violates a documented standard: cite the standard (file + the rule); and (b) any violation of the pasted unified standard: name the rule or smell and quote the hunk. Apply the standard's binding rules. Under 400 words."

**Spec sub-agent prompt** — include:

- The diff command and commit list.
- The path or fetched contents of the spec.
- The brief: "Report: (a) requirements the spec asked for that are missing or partial; (b) behaviour in the diff that wasn't asked for (scope creep); (c) requirements that look implemented but where the implementation looks wrong. Quote the spec line for each finding. Under 400 words."

If the spec is missing, skip the Spec sub-agent and note this in the final report.

### 5. Aggregate

Combine the reports under `## Standards` and `## Spec`, keeping each finding on
its axis. When PR publication is requested, the coordinator posts one combined
comment; children only return findings.

End with a one-line summary: total findings per axis, and the worst issue _within each axis_ (if any).
