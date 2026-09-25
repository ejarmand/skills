# Skills

A curated, integrated collection of engineering and agent-orchestration skills.
Every installable skill lives in the flat `skills/` tree, and `skill-router`
maps the complete collection.

## Inventory

### Routing and implementation flow

- `skill-router` — choose the right skill or flow
- `same-page` — agree on the goal and scope with the user before planning
- `grill` — interview the user about a plan until you share one understanding
- `handoff` — carry context into a fresh session
- `prototype` — answer one design question with throwaway code
- `to-spec` — turn a conversation into a spec and publish it as a GitHub issue
- `to-tickets` — split a spec into tracer-bullet GitHub issues linked by
  their blockers
- `implement` — build a prepared spec or ticket test-first and commit the
  verified result
- `tdd` — build behavior in red → green slices
- `code-review` — review Standards and Spec as separate axes

### On-ramps and codebase health

- `diagnosing-bugs` — establish a reproducer, diagnose, and regression-test
- `wayfinder` — map a multi-session effort as GitHub decision issues and
  resolve them one at a time
- `codebase-design` — shared deep-module vocabulary
- `domain-modeling` — sharpen domain language and decisions
- `improve-codebase-architecture` — find and present deepening opportunities
- `laziness-protocol` — prefer deletion and the smallest diff that solves the
  problem
- `fix-steering` — audit session corrections and recommend prevention changes

### Teaching and visualization

- `teach` — run a stateful learning workspace
- `bro` — restate the last response in plain, concise language
- `unslop` — remove AI writing patterns and improve legibility
- `writing-great-skills` — reference for authoring and editing skills
- `html-visualization` — build HTML diagrams, process maps, timelines, and
  interactive explainers, checking each render with screenshots

### Agent and review orchestration

- `batch-subagents` — fan out many independent CLI agent workers in one shell
  call
- `claude-agent` — execute and resume independent headless Claude Code work
- `codex-agent` — execute and resume independent Codex CLI work
- `cursor-agent` — execute and resume independent Cursor Agent work
- `opencode-agent` — execute OpenCode workers across model providers
- `cross-provider-agent` — dispatch one bounded task to an external provider
  under least authority, with named authority profiles
- `pr-ping-pong` — rally implementation against cross-provider reviewers
- `agent-resume` — message a Claude Code or Codex session when a job finishes
  or a timer fires, resuming it if it has closed

## Install

Link every canonical skill into both supported harness directories:

```bash
scripts/link-skills.sh
```

By default this links into `~/.claude/skills` and `~/.agents/skills`, and links
every executable under `skills/*/bin/` (such as `agent-resume`) into
`~/.local/bin`. Override any destination when needed:

```bash
CLAUDE_SKILLS_DIR=/path/to/claude-skills \
AGENTS_SKILLS_DIR=/path/to/agent-skills \
BIN_DIR=/path/to/bin \
  scripts/link-skills.sh
```

If a link name is already taken by a real file or directory, such as a copy
from an older install, the installer lists every such path and asks once before
deleting them all and linking in their place. Pass `--yes` to delete without
asking. Without a terminal and without `--yes`, it exits before linking or
deleting anything.

On a terminal, and without `--yes`, the installer then offers to set
`crossSessionInbound` to `"accept"` in `~/.claude/settings.json`
(`CLAUDE_SETTINGS_FILE` overrides the path) so `agent-resume` messages reach
bypass-permissions Claude sessions without approval.

The hermetic tests use temporary destinations and do not touch a developer's
installed skills:

```bash
tests/test-inventory.sh
tests/test-link-skills.sh
tests/test-check-requirements.sh
tests/test-agent-resume.sh
```

## Check software requirements

[`requirements.txt`](requirements.txt) is the loose, command-level software
inventory shared across the skills. Check the current machine with:

```bash
scripts/check-requirements.sh
```

The checker lists every command as `installed` or `missing` and remains
informational when software is absent. It does not validate versions,
authentication, network access, browser bundles, model availability, or a
target project's own toolchain. Pass another manifest path to inspect a custom
requirement set.

## Provenance

The promoted upstream skills were vendored from
[`mattpocock/skills`](https://github.com/mattpocock/skills) at commit
`2ab958093e83e0ec752e6c1c5932da465bf23e0c`; snapshot date: 2026-07-30.
Matt Pocock's MIT license is preserved at
`vendor/mattpocock-skills-LICENSE`. The exact promoted set is recorded in
`vendor/mattpocock-skills-SNAPSHOT.md`.

The promoted snapshot is limited to skills named by the upstream router at that
commit. Upstream plugin manifests, marketplace metadata, docs, changesets,
`deprecated/`, and `in-progress/` distribution buckets are intentionally not
part of this repository.

To re-sync, clone or update a clean upstream checkout, review
`git log 2ab9580..HEAD`, and port only the changes worth adopting into this
canonical tree. The vendored files here remain the source of truth.
