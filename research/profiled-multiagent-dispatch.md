# Profiled multi-agent dispatch: child inheritance and better transports

> Research note, 2026-08-02 UTC. Investigates whether better mechanisms exist than
> PR #19's amended design — a per-provider review coordinator spawning two native
> subagents, with Codex transported through a transactional temp-`CODEX_HOME`
> wrapper — and how child/subagent authority inheritance actually works in each
> CLI. Includes the composability lens requested mid-research: rate each mechanism
> on "arbitrary profile as a runtime parameter, no prior machine-level install"
> (feeding the medium-term goal of dispatching cross-provider subagents with
> arbitrary configs, not one baked-in profile).
>
> Versions for all source reads and live probes: codex-cli **0.146.0** (source at
> tag [`rust-v0.146.0`](https://github.com/openai/codex/tree/rust-v0.146.0), plus
> `main` fetched 2026-08-02), cursor-agent **2026.07.23-e383d2b**, Claude Code
> **2.1.220**, gh 2.96.0, Linux. Live probes ran 2026-08-01→02 UTC; the only
> network-touching command any probe executed was `gh pr view` (no GitHub writes).
> Builds on the prior notes `agent-permission-allowlists.md` and
> `subagent-profile-portability.md` (deleted at `78ecf4d`, recoverable at
> `71f64d7`); their live results are cited below as "prior probe".

## Answer first

| Provider | Children bound by the profile? | Arbitrary profile as runtime parameter? | Wrapper required |
| --- | --- | --- | --- |
| Claude Code | **Yes** (live) | **Yes** — `--settings <abs path> --setting-sources ""` | None |
| Cursor CLI | **Yes** (live) | Staged files only; the runner takes any profile dir | Transactional runner stays |
| Codex CLI | **Yes** — sandbox by docs, rules by live probe | **Yes** — an assembled private `CODEX_HOME` selected by env var | Thin ephemeral-home assembly — much less than planned |

1. **The coordinator + native-children hierarchy is safe on all three providers.**
   Live probes on each show spawned children are bound by the dispatched profile
   and cannot widen it (§1.1, §2, §3). The user's fallback — one parent with
   extensive permissions managing all subagents — is not needed.
2. **Codex flags-only dispatch is dead.** `--ignore-rules` *and*
   `--ignore-user-config` each kill the profile's sibling `rules/` while leaving
   the role TOML applied (§1.2, live). There is no flag combination that drops
   user config/rules but keeps profile rules.
3. **The temp-`CODEX_HOME` direction is right, but should go further.** With a
   private home, the profile *is* the home (`config.toml` + `rules/`): the
   parent→child bootstrap relay disappears, and a profiled `gh pr view` dispatch
   cost **5,593 tokens vs ~47–51k** through the relay (§1.3, live). The wrapper
   shrinks to: assemble temp home, run, verify, delete — no workspace mutation,
   no lock, no snapshot/restore.
4. **Auth staging is a symlink, not a copy.** Codex persists `auth.json` by
   open+truncate+write, not tempfile+rename
   ([`login/src/auth/storage.rs`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/login/src/auth/storage.rs)
   ~L210–216), so a refresh writes *through* a symlink into the real
   `~/.codex/auth.json`. Live: a session ran with symlinked auth; the real file
   was byte-identical and untouched after (§1.3).
5. **One hazard survives every Codex transport:** the workspace's own
   `.codex/rules/` loads into the reviewer's policy without any trust ceremony
   (prior probe), so a PR under review can grant its own reviewer sandbox
   escapes. Dispatch needs a checkout preflight (§1.4).

## 1. Codex

### 1.1 Children inherit the parent's authority

The subagents doc is explicit: "Subagents inherit your current sandbox policy",
and "Codex also reapplies the parent turn's live runtime overrides when it
spawns a child … even if the selected custom agent file sets different
defaults" ([subagents doc](https://learn.chatgpt.com/docs/agent-configuration/subagents),
fetched 2026-08-01). So under `codex exec --sandbox read-only`, a child cannot
select a wider sandbox; the CLI-level override wins over the agent file. In
source, a spawned role is applied as a high-precedence config layer on top of
the parent's full layer stack
([`core/src/agent/role.rs`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/core/src/agent/role.rs)
module doc), and `child_uses_parent_exec_policy`
([`core/src/exec_policy.rs`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/core/src/exec_policy.rs))
reuses the parent's policy when the config folders match.

[openai/codex#32587](https://github.com/openai/codex/issues/32587) (open,
no maintainer response) is a Codex **App** multi-agent bug: `spawn_agent` there
lacks an `agent_type` parameter and children silently inherit the parent's
model. On CLI 0.146.0 role binding worked in every probe here and in the prior
notes; a failed binding fails *closed* for authority (a child without the role
gets no rules, hence no sandbox escape).

### 1.2 The flags dead end — live

Probe setup: fresh git repo, profile dir with `reviewer.toml`
(`sandbox_mode = "read-only"` + marker `developer_instructions`) and sibling
`rules/gh-view.rules` allowing exactly `gh pr view`;
`codex execpolicy check` confirmed the rule offline. Parent invocation:
`codex exec --json --ephemeral --skip-git-repo-check --sandbox read-only
-c 'agents.probe_reviewer.description=…'
-c 'agents.probe_reviewer.config_file="<abs>/reviewer.toml"'` with a prompt to
spawn one fresh child that runs `gh pr view 19 --repo ejarmand/skills --json
title`. All three runs returned the child's marker, proving the role TOML
bound; only the rules outcome differed:

| Extra flags | Child's `gh pr view` | Reading |
| --- | --- | --- |
| none | **succeeded** (real PR title) | sibling rules govern the child; also re-verifies the prior probe under `--ephemeral` |
| `--ignore-user-config --ignore-rules` | **bwrap loopback failure** | rules gone |
| `--ignore-user-config` only | **bwrap loopback failure** | rules gone — `--ignore-user-config` alone kills profile rules |

Source explains half of this: rules are collected per config layer from
`<layer folder>/rules/`, and `--ignore-rules` skips layers whose source is
`User` or `Project`
([`exec_policy.rs` `load_exec_policy`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/core/src/exec_policy.rs)).
The probes show the role `config_file`'s sibling rules ride a user-classified
path, so both ignore flags remove them while the role TOML itself (delivered as
a separate spawn-time layer) survives. Net: **no flag combination gives a
hermetic profiled dispatch**. `--ignore-user-config` did confirm one useful
fact incidentally: the session authenticated from the real `CODEX_HOME`
(matching its help text, "auth still uses `CODEX_HOME`").

### 1.3 Assembled private `CODEX_HOME`: profile-as-home, no relay — live

Layout and invocation:

```text
$TMP_HOME/
├── auth.json -> ~/.codex/auth.json     # symlink, not a copy
├── config.toml                          # the profile: sandbox_mode, developer_instructions
└── rules/default.rules                  # the profile's command allowlist
```

```shell
env CODEX_HOME=$TMP_HOME codex exec --ephemeral --skip-git-repo-check \
  --sandbox read-only 'Run exactly `gh pr view 19 …` and report raw output.' </dev/null
```

Result (0.146.0, 2026-08-02): the root session itself ran under the profile —
marker present, `gh pr view` escaped the read-only sandbox through the home's
rules and returned the real PR title in 182ms, total **5,593 tokens**. The
relay probes above cost 47–51k input tokens each. The dummy-parent relay — the
part of the original design the author flagged as problematic — is simply gone:
the root *is* the profiled agent, and for the review hierarchy the root is the
coordinator whose native children inherit the same home (sandbox by §1.1;
rules because children rebuild config from the same layer stack).

Operational notes, all observed live:

- **Per-dispatch temp home, not the skill's profile dir.** Codex writes state
  into the home even with `--ephemeral` (sqlite state/goals/memories, logs,
  `models_cache.json`, `plugins/`, `skills/`). Assemble a throwaway dir from
  the profile; delete it after verification.
- **Skills don't follow.** A private home has an empty `$CODEX_HOME/skills/`,
  and `SkillsConfig` only enables/disables discovered skills — there is no
  extra-load-path key
  ([`config/src/skills_config.rs`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/config/src/skills_config.rs)).
  If the dispatch expects the child to invoke `/code-review`, symlink
  `~/.codex/skills` (or just the needed skills) into the assembled home.
- **Auth rotation is safe through the symlink** on this version: persistence
  opens with `truncate(true).write(true).create(true)` and writes in place
  (storage.rs, §Answer-first #4), which follows symlinks. Re-verify on CLI
  bumps — a move to atomic rename would break the link silently. Keyring and
  encrypted-storage auth paths exist for other setups; the symlink recipe
  covers the file-based default.
- **Close stdin.** Without `</dev/null`, `codex exec` hung reading stdin in one
  probe (killed at 300s).
- **Concurrency comes free.** Each dispatch owns its home; nothing touches the
  workspace or any shared config, so parallel Codex dispatches need no lock —
  unlike the Cursor runner.

**Addendum (2026-08-02): drop `--ephemeral` from this recipe.** Controlled
probes on 0.146.0 show `--ephemeral` breaks full-history native child forks —
the fork path looks up the parent thread before copying its context, and an
ephemeral root registers no thread id, so the spawn fails with
`collab spawn failed: no thread with id: <parent>` (fresh/no-history children
bypass the lookup, which is why the simple spawn probes above still passed).
This is the same root cause as the pre-existing adapter warning against
`--ephemeral` when resume is needed. The flag was only ever session-persistence
hygiene, and an incomplete version of it — the state writes listed above happen
regardless — so the temp home's deletion subsumes its entire job: without the
flag, session rollouts land in the assembled home and are removed with it.
`run-profiled.sh` dispatches without the flag accordingly. Residual trade-off:
a hard-killed runner (cleanup never runs) now leaves rollouts — the full
conversation — in the temp dir alongside the state files that already leaked in
that scenario.

### 1.4 Hazards that survive any Codex transport

- **Workspace `.codex/rules/` loads without trust gating** (prior probe: rules
  in a fresh, never-trusted repo authorized a sandbox escape on the real exec
  path). For a reviewer dispatched into a PR checkout this is an authority
  inversion: the code under review can allowlist commands for its reviewer.
  Neither the temp home nor any flag stops the project layer — it rides with
  the checkout. Dispatch preflight: fail closed (or strip) if the pinned
  checkout contains `.codex/` — this belongs in cross-provider-agent's dispatch
  step, beside the pinned-head check. The same class of check is worth doing
  for `.cursor/` (the runner already replaces staged files, but only for
  Cursor dispatches) — Claude is covered by `--setting-sources ""`.
- **Native file-tool writes bypass the read-only sandbox** (prior probe, §7 of
  the allowlists note; no kill switch in the 0.146.0 schema). Post-dispatch
  pinned-head + clean-tree verification with discard-on-mismatch remains the
  operative guard.
- **Headless approvals are hardcoded `Never`** (prior note): anything not
  pre-authorized by rules fails with no runtime escalation, which is the
  correct fail-closed shape here.

## 2. Cursor CLI

Live probe (2026-08-02): workspace `.cursor/cli.json` allowing only `Read(**)`
and `Shell(git log)`, plain `-p --output-format json --trust`
(deny-unless-allowed), prompt instructing the agent to spawn one **Task**
subagent that runs `git log --oneline -1` then `git status --short`:

- the Task spawn itself ran **without** any Task allow rule;
- inside the child, `git log` **ran** and `git status` was **"Rejected"**
  (three retries, no output).

So Task children inherit the workspace permission config, enforcement happens
inside the child, and delegation is not part of the permission surface (it
cannot be enabled or disabled by allowlist omission; a deny spelling for Task
is untested). The landed `github-pr-reviewer` profile therefore supports the
coordinator hierarchy **unchanged**. The subagents doc
([cursor.com/docs/subagents](https://cursor.com/docs/subagents), fetched
2026-08-01) says nothing about permission inheritance — like multi-word
`Shell(...)` matching, this is live-verified undocumented behavior, one more
reason the `sandbox.json` GitHub-domain allowlist stays on as defense in depth.

Composability: unchanged from the prior note — the CLI has no permission,
profile, or agents flag; the profile travels as `CURSOR_CONFIG_DIR` plus staged
workspace files, which is why the transactional runner exists. The runner is
already parametric over profile directories (`--profile <name>` resolving under
`profiles/`), so arbitrary profiles work, but the transport stays the heaviest:
workspace mutation, a lock that forbids concurrent same-workspace dispatches,
byte-for-byte restore. Two consequences for the rally design: Cursor's staged
`.cursor/` files make the shared checkout dirty while it runs, so another
provider's post-dispatch clean-tree verification can spuriously fail — either
serialize providers per rally or pin one checkout per provider.

## 3. Claude Code

Two live probes (2.1.220, 2026-08-02), both run with the **landed profile
exactly as committed** (`claude -p --settings <abs>/settings.json
--setting-sources ""`):

1. **Hierarchy works unchanged; children are bound.** The Agent tool spawned a
   general-purpose subagent even though `Agent` appears nowhere in the
   profile's allow list — under `dontAsk`, delegation is not permission-gated.
   Inside the child, `git log` (allowed) ran and `touch denied-probe.txt` was
   denied by the permission system. The parent analysis's assumed gap ("the
   Claude profile must add the Agent tool") is **wrong** — no profile edit
   needed.
2. **The `permissionMode` escape vector is closed by `--setting-sources ""`.**
   A planted `.claude/agents/probe-writer.md` with
   `permissionMode: bypassPermissions` was not loaded — the session reported no
   such agent type exists, fell back to general-purpose, the write was denied,
   and the canary file was never created.

Docs corroborate: built-in subagents "inherit the parent conversation's
permissions with additional tool restrictions"; denying the `Agent` tool blocks
delegation entirely; the Task tool was renamed Agent in 2.1.63 with `Task(...)`
kept as an alias; a parent's `bypassPermissions`/`acceptEdits` mode takes
precedence over child overrides; `--agents` JSON defines session-only agents
(with `tools`, `disallowedTools`, `permissionMode`) as explicit caller input
([sub-agents doc](https://code.claude.com/docs/en/sub-agents), fetched
2026-08-01).

Composability: the gold standard. The profile is a pure runtime parameter
(`--settings` by absolute path), `--setting-sources ""` excludes every
pre-existing layer *and* project agent definitions, `--agents` can inject
arbitrary child roles per dispatch, and no wrapper, staging, or installation
exists anywhere in the path.

## 4. Architecture comparison

| | (a) Per-axis one-shot externals (pre-amendment) | (b) Coordinator + native children (amendment) | (c) Broad-permission parent managing everything |
| --- | --- | --- | --- |
| Authority containment | Simplest — no delegation at all | Verified: children bound on all three providers | Worst — the parent is the one over-privileged piece |
| Sessions per provider per rally | 2 external | 1 external (+2 native children) | 1 giant |
| PR comments per provider | 2 | 1 aggregated | 1 |
| `/code-review` contract reuse | No — briefs pasted per axis | Yes — native two-child spawn is the skill's own shape | Partial |
| Codex cost | Now cheap too (direct dispatch, no relay) | Cheap (coordinator is the profiled root; no dummy relay) | n/a |
| Extra requirements | None new | Skills present in child environment (Codex: symlink into home) | None |

The amendment's shape (b) stands, now with evidence behind its containment
claim on all three providers, and the Codex objection dissolved — the "small
CLI-parent → profiled-child relay" is replaced by the profiled root itself.
Shape (a) remains a clean fallback if a future CLI version breaks child
inheritance (the conformance probes below would catch it). Shape (c) — the
survivable-worst-case in the steer — is unnecessary.

## 5. Composability ratings (arbitrary profile as parameter, no install)

| Provider | Transport | Arbitrary profile? | Machine install? | Wrapper weight | Rating |
| --- | --- | --- | --- | --- | --- |
| Claude Code | `--settings <path> --setting-sources ""` (+ `--agents` JSON) | Yes — any settings file | None | None | **A** |
| Codex | assembled ephemeral `CODEX_HOME` via env var | Yes — any profile dir becomes the home | None (skills symlinked in when needed) | Thin: mkdir + 2–3 symlinks/copies + rm | **B+** |
| Cursor | `CURSOR_CONFIG_DIR` + staged `.cursor/` files via runner | Yes — runner is profile-agnostic | None | Heavy: stage, lock, supervise, restore, recover | **C+** |

For the medium-term goal: every transport above takes a profile *directory* as
a runtime parameter, so cross-provider-agent's "named logical profile +
adapter encoding" contract already generalizes to arbitrary profiles — the
only `github-pr-reviewer` coupling is file layout, not mechanism. Avoid the
provider-native installation routes (Codex `~/.codex/agents/` discovery,
Cursor plugins) as the *runtime* path: they reintroduce machine-level state
and, on Codex, the unreliable name-binding surface (#32587).

## 6. Recommendations, ranked by confidence

1. **High — replace the Codex transport with the assembled-ephemeral-home
   direct dispatch** (§1.3): profile-as-home, auth symlinked, no `--ephemeral`
   (it breaks full-history child forks — §1.3 addendum),
   stdin closed, temp home deleted after verification. This deletes the
   bootstrap relay, the auth-copy question, and roughly 90% of the planned
   `run-profiled.sh` (no workspace staging, no lock, no restore) while keeping
   the temp-home isolation the amendment wanted.
2. **High — never combine profiled dispatch with `--ignore-user-config` or
   `--ignore-rules`** (§1.2): each silently strips the profile's rules while
   the role instructions keep working — worst case, an unauthorized-looking
   failure; with a home-based profile the flags are unnecessary anyway.
3. **High — add a checkout preflight to the dispatch step**: fail closed if the
   pinned checkout contains `.codex/` (PR-controlled reviewer authority, §1.4);
   check `.cursor/` for non-Cursor dispatches likewise.
4. **High — land the hierarchy with zero permission edits to the Claude and
   Cursor profiles** (§2, §3); the assumed Agent/Task allowlist gap does not
   exist. Extend the conformance suite instead: per provider, spawn a child
   under the profile and assert (a) an allowed read works inside the child,
   (b) a denied write fails inside the child.
5. **Medium — re-verify the auth symlink on Codex version bumps** (a switch to
   atomic-rename persistence would silently orphan refreshes) and keep the
   pinned-head/clean-tree discard rule for the native-write bypass.
6. **Medium — serialize providers on a shared checkout or pin one checkout per
   provider** (§2): Cursor's staged files otherwise trip the other providers'
   clean-tree verification.

## Primary-source index

### Codex
- [Subagents & custom agents](https://learn.chatgpt.com/docs/agent-configuration/subagents) — inheritance quotes
- [`config/src/loader/mod.rs`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/config/src/loader/mod.rs) — layer precedence, `ignore_user_config`
- [`core/src/exec_policy.rs`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/core/src/exec_policy.rs) — per-layer rules collection, `--ignore-rules` filter, `child_uses_parent_exec_policy`
- [`core/src/agent/role.rs`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/core/src/agent/role.rs), [`core/src/config/agent_roles.rs`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/core/src/config/agent_roles.rs) — role layering at spawn
- [`login/src/auth/storage.rs`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/login/src/auth/storage.rs) — truncate-in-place auth persistence
- [`config/src/skills_config.rs`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/config/src/skills_config.rs) — no extra skills load path
- [#32587](https://github.com/openai/codex/issues/32587) — App spawn_agent role-binding bug
- Installed `codex --help` / `codex exec --help`, 0.146.0

### Cursor
- [Subagents](https://cursor.com/docs/subagents) — Task tool; silent on permission inheritance
- [CLI permissions](https://cursor.com/docs/cli/reference/permissions), [sandbox reference](https://cursor.com/docs/reference/sandbox)

### Claude Code
- [Custom subagents](https://code.claude.com/docs/en/sub-agents) — inheritance, Agent rule spelling, `--agents`, mode precedence
- [Permissions](https://code.claude.com/docs/en/permissions)

### Prior project research (deleted at `78ecf4d`, recoverable at `71f64d7`)
- `research/agent-permission-allowlists.md` — execpolicy verification, untrusted-repo rules loading (§6), native-write bypass (§7)
- `research/subagent-profile-portability.md` — `config_file` layer probes, Cursor runner contract
