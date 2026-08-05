# Skills

A curated, integrated collection of engineering and agent-orchestration skills.
Every installable skill lives in the flat `skills/` tree, and `skill-router`
maps the complete collection.

## Inventory

### Routing and implementation flow

- `skill-router` — choose the right skill or flow
- `grill-with-docs` — sharpen a codebase-backed idea and retain decisions
- `grilling` — shared interview primitive
- `handoff` — carry context into a fresh session
- `prototype` — answer one design question with throwaway code
- `to-spec` — turn a conversation into a buildable spec
- `to-tickets` — split a spec into ordered tracer-bullet tickets
- `implement` — run the TDD and verification sequence
- `tdd` — build behavior in red → green slices
- `code-review` — review Standards and Spec as separate axes

### On-ramps and codebase health

- `diagnosing-bugs` — establish a reproducer, diagnose, and regression-test
- `wayfinder` — resolve decision-heavy, multi-session efforts
- `codebase-design` — shared deep-module vocabulary
- `domain-modeling` — sharpen domain language and decisions
- `improve-codebase-architecture` — find and present deepening opportunities
- `research` — delegate primary-source reading into a cited repository note
- `fix-steering` — audit session corrections and recommend prevention changes

### Teaching and visualization

- `teach` — run a stateful learning workspace
- `writing-great-skills` — reference for authoring and editing skills
- `html-visualization` — render, screenshot, and critique browser-based reports

### Agent and review orchestration

- `batch-luna-agents` — fan out independent Luna workers in one shell call
- `claude-agent` — execute and resume independent headless Claude Code work
- `codex-agent` — execute and resume independent Codex CLI work
- `cursor-agent` — execute and resume independent Cursor Agent work
- `opencode-agent` — execute OpenCode workers across model providers
- `cross-provider-agent` — dispatch one bounded task to an external provider
  under least authority, with named authority profiles
- `pr-ping-pong` — rally implementation against cross-provider reviewers

## Install

Link every canonical skill into both supported harness directories:

```bash
scripts/link-skills.sh
```

By default this links into `~/.claude/skills` and `~/.agents/skills`. Override
either destination when needed:

```bash
CLAUDE_SKILLS_DIR=/path/to/claude-skills \
AGENTS_SKILLS_DIR=/path/to/agent-skills \
  scripts/link-skills.sh
```

The installer refuses to replace a real file or directory. Its hermetic smoke
test uses temporary destinations and does not mutate a developer's installed
skills:

```bash
tests/test-inventory.sh
tests/test-link-skills.sh
```

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
