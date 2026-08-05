# Skill platform compatibility: Claude Code, Codex, and OpenCode

> Research snapshot: **2026-08-05 UTC**. Primary sources only: the
> [Agent Skills specification](https://agentskills.io/specification),
> [Claude Code skills documentation](https://code.claude.com/docs/en/slash-commands),
> [Codex skills documentation](https://developers.openai.com/codex/skills), and
> [OpenCode skills documentation](https://opencode.ai/docs/skills), supplemented
> by installed CLI help and read-only local probes. Installed versions were
> Claude Code **2.1.222**, Codex CLI **0.146.1**, and OpenCode **1.18.13**.
>
> Labels below mean: **Verified** = stated by a primary source or observed in a
> named local probe; **Inferred** = conclusion from those facts; **Untested** =
> not exercised end-to-end. This note records the current landscape; it does not
> prescribe repository policy.
>
> Follow-up in this worktree: cross-skill `/skill-name` prose is accepted as
> compatible because the linked skills are adequately discovered in practice.
> The added root `requirements.txt` and `scripts/check-requirements.sh` address
> the audited software-inventory gap without changing the baseline findings.

## Executive summary

**Verified.** All 26 repository skills are structurally discoverable by all
three installed local clients when installed through the repository's existing
dual-link scheme. Claude reads `~/.claude/skills`; Codex reads
`~/.agents/skills`; OpenCode reads both of those plus its native config path.
The common runtime contract ends much sooner: portable Agent Skills guarantee a
`SKILL.md`, standard frontmatter, Markdown instructions, and relative bundled
resources. They do not standardize explicit-invocation syntax, invocation
policy, tool names, subagent APIs, permissions, or dependency installation.

**Verified.** Ten repository skills are intentionally user-only. Their Claude
frontmatter (`disable-model-invocation: true`) is mirrored for Codex by
`agents/openai.yaml` (`policy.allow_implicit_invocation: false`). OpenCode
1.18.13 ignores both controls and advertises these skills to the model. A
hermetic `opencode debug skill --pure` probe specifically confirmed that
`handoff` is loaded from `.agents/skills` despite both metadata controls.

**Verified.** Three skills contain hard provider-tool assumptions:
`code-review` requires two Claude `Agent`/`general-purpose` calls;
`improve-codebase-architecture` requires `Agent` with
`subagent_type=Explore`; and the optional design-it-twice flow in
`codebase-design` requires the Claude `Agent` tool. Many more skills use
Claude-style `/skill-name` prose, while Codex's documented explicit form is
`$skill-name` and OpenCode exposes a `skill({name})` tool.

**Verified at the audited baseline.** No repository `SKILL.md` has a standard
`compatibility` field and no `agents/openai.yaml` declares a dependency. The
standard's compatibility field is descriptive text, not resolution or
enforcement. The skills depend on binaries, authentication, network access,
provider-specific history, and host tools that were encoded through prose and
scripts before the follow-up inventory was added.

## Failure list at a glance

- **Direct orchestration mismatch:** `code-review` and the optional
  design-it-twice flow in `codebase-design` require Claude's `Agent` tool;
  `improve-codebase-architecture` additionally requires Claude's `Explore`
  agent type. They have no literal Codex or OpenCode execution path as written.
- **Invocation-policy mismatch on OpenCode:** `grill-with-docs`, `handoff`,
  `improve-codebase-architecture`, `pr-ping-pong`, `skill-router`, `teach`,
  `to-spec`, `to-tickets`, `wayfinder`, and `writing-great-skills` are intended
  to be explicit-only, but OpenCode ignores that control.
- **Missing OpenCode transport:** `cross-provider-agent` dispatches Claude,
  Codex, or Cursor workers, but has no OpenCode worker adapter. `pr-ping-pong`
  inherits that gap for external implementation and review sessions.
- **Non-portable cross-skill syntax:** `batch-luna-agents`, `claude-agent`,
  `codex-agent`, `cross-provider-agent`, `cursor-agent`, `diagnosing-bugs`,
  `grill-with-docs`, `implement`, `improve-codebase-architecture`,
  `pr-ping-pong`, `skill-router`, `teach`, and `wayfinder` contain
  `/skill-name` calls. Claude defines that syntax; Codex and OpenCode require
  adaptation.

The first three groups are concrete behavior or feature gaps. The slash-call
group is an inferred portability gap: models may translate it successfully,
but the platform contracts do not guarantee that translation.

## Verified platform contracts

| Concern | Claude Code 2.1.222 | Codex CLI 0.146.1 | OpenCode 1.18.13 |
| --- | --- | --- | --- |
| Local discovery | `~/.claude/skills`, ancestor `.claude/skills` to repo root, plugin `skills/`; added directories are a special case | `~/.agents/skills`, ancestor `.agents/skills` to repo root, admin/system locations | Native `.opencode/skills`, Claude-compatible `.claude/skills`, and `.agents/skills`, globally and from CWD to worktree root |
| Required format | Local Claude is lenient: `name` optional, `description` recommended | `SKILL.md` with `name` and `description` | `name` and `description`; strict name/directory and length rules |
| Standard optional fields | Accepts `license`, `compatibility`, `metadata`, `allowed-tools`; `compatibility` is not acted on | Documents standard skill body plus product metadata in `agents/openai.yaml` | Recognizes `license`, `compatibility`, and string-map `metadata`; unknown fields ignored |
| Supporting files | Relative links plus `${CLAUDE_SKILL_DIR}` and `${CLAUDE_PROJECT_DIR}` extensions | Optional `scripts/`, `references/`, `assets/`; selected skill is read in full | Skill tool returns body; local probe returned the absolute `SKILL.md` location. Resources remain file reads |
| Explicit invocation | `/skill-name` | `$skill-name` or `/skills` picker | Agent calls `skill({name})`; current skills docs do not specify Claude-compatible `/skill-name` invocation |
| User-only / implicit control | `disable-model-invocation`; also `user-invocable`, `skillOverrides` | `agents/openai.yaml` `policy.allow_implicit_invocation` | Host config can allow/ask/deny skill loading, but no per-skill user-only metadata is documented |
| Per-skill tool control | `allowed-tools` grants approval for one turn; `disallowed-tools` removes tools for one turn | No standard `allowed-tools` behavior is documented; `openai.yaml` dependencies currently describe MCP tools | `allowed-tools` is unknown frontmatter and ignored; permissions are host/agent configuration |
| Subagents | `Agent` tool; built-ins include `general-purpose`, `Explore`, `Plan`; `context: fork` is a skill extension | Native subagent workflows and built-in `default`, `worker`, `explorer`; exact harness controls are not an Agent Skills contract | `task` tool; agents use `primary`, `subagent`, or `all` mode and `permission.task` |
| Dependency model | `compatibility` accepted but explicitly not acted on | `openai.yaml` supports `dependencies.tools`, currently MCP only | No skill dependency resolver documented; `compatibility` is metadata |

Sources: [Agent Skills specification](https://agentskills.io/specification),
[client implementation guide](https://agentskills.io/client-implementation/adding-skills-support),
[Claude discovery and frontmatter](https://code.claude.com/docs/en/slash-commands#where-skills-live),
[Claude supporting files](https://code.claude.com/docs/en/slash-commands#add-supporting-files),
[Claude invocation controls](https://code.claude.com/docs/en/slash-commands#control-who-invokes-a-skill),
[Codex local locations and metadata](https://developers.openai.com/codex/skills),
[Codex subagents](https://developers.openai.com/codex/subagents),
[OpenCode discovery and permissions](https://opencode.ai/docs/skills), and
[OpenCode agents](https://opencode.ai/docs/agents).

### Local probes

- **Verified — Codex.** `codex debug prompt-input` advertised 16 implicit
  repository skills. The ten skills with `allow_implicit_invocation: false`
  were suppressed. Codex documentation warns that its initial catalog has a
  context budget and can omit entries, so catalog presence must not be used as
  a complete inventory check.
- **Verified — OpenCode.** The root audit loaded all 26 via `skills.paths`.
  A second isolated probe copied only `handoff` beneath a temporary
  `.agents/skills`; `opencode debug skill --pure` returned it even though its
  frontmatter and `openai.yaml` both say user-only in provider-specific terms.
- **Verified — Claude.** The current install contains per-skill symlinks in
  `~/.claude/skills`. Claude plugin validation succeeded; it emitted only
  missing-version/author warnings. Runtime invocation of every skill was not
  performed.

## Per-skill compatibility matrix

All rows have **loader: C/K/O yes** under the verified installation above.
“Policy” describes whether intended implicit/manual invocation survives across
providers. “Behavior mismatch” identifies instruction-level portability, not
whether a capable model might improvise around it.

| Skill | Policy | Behavioral/tool mismatch | External/runtime dependencies |
| --- | --- | --- | --- |
| `batch-luna-agents` | Default on all | Codex/Luna-only transport; `/codex-agent`; GNU `xargs -0 -P`; hard-coded model | `codex`, Bash, GNU `xargs`, writable temp space |
| `claude-agent` | Default on all | Claude CLI flags, JSON/session schema, Claude plugin/settings semantics; `/cross-provider-agent` | `claude`, authentication, shell, network for remote work |
| `code-review` | Default on all | **Fails natively outside Claude:** two `Agent` calls using `general-purpose` | `git`; spec source may require authenticated `gh`/network |
| `codebase-design` | Default on all | Core reference is portable; `DESIGN-IT-TWICE.md` hardcodes parallel Claude `Agent` calls | File reads; subagent capability for optional flow |
| `codex-agent` | Default on all | Codex CLI flags/events, execpolicy, `CODEX_HOME`; `/cross-provider-agent` | `codex`, authentication, Bash; `gh`/network for reviewer profile |
| `cross-provider-agent` | Default on all | Routes using Claude-style `/adapter` names; behavior depends on three adapter skills | At least one authenticated `claude`, `codex`, or `cursor-agent`; network as needed |
| `cursor-agent` | Default on all | Cursor flags, event/session schema, workspace trust and config files; `/cross-provider-agent` | `cursor-agent`, authentication, Bash, `jq`; `gh`/network for profile |
| `diagnosing-bugs` | Default on all | Workflow prose is portable; exact debugger/browser/tools are host-dependent | Project test/runtime tools; optional Bash HITL template, browser/profiler |
| `domain-modeling` | Default on all | Modeling core portable; work-record contract is GitHub/`gh` specific | Authenticated `gh`, GitHub network for work records |
| `fix-steering` | Default on all | Reads Codex-specific history schema/locations and requires several subagents | Python 3, readable Codex history, subagent capability |
| `grill-with-docs` | **C/K user-only; O implicit** | `/grilling` and `/domain-modeling` composition uses Claude slash syntax | Repository writes for context/ADR records |
| `grilling` | Default on all | No provider-specific tool named | Conversation/user input capability |
| `handoff` | **C/K user-only; O implicit** | Claude-only `argument-hint`; otherwise prose | Writable destination for handoff document |
| `html-visualization` | Default on all | Platform opener and screenshot-delivery behavior vary | `playwright-cli`, installed browser, Python 3, `curl`, POSIX shell, localhost; browser install may need network |
| `implement` | Default on all | `/tdd` composition is Claude slash syntax; assumes commit authorization | Project build/test tools and `git` |
| `improve-codebase-architecture` | **C/K user-only; O implicit** | **Fails natively outside Claude:** `Agent` with `subagent_type=Explore`; several `/skill` calls | `git`, HTML visualization stack, Tailwind/Mermaid CDN network |
| `pr-ping-pong` | **C/K user-only; O implicit** | Native-subagent and `/cross-provider-agent` orchestration are harness-dependent | Authenticated `gh`, GitHub network, `git`, provider CLIs, separate workspaces |
| `prototype` | Default on all | Host/file tooling is generic; capture flow assumes git branches/issues | Project runtime/package manager, `git`; GitHub issue access when recording pointer |
| `research` | Default on all | Requires a background subagent but does not name a portable subagent API | Subagent capability, web/API access, writable Markdown destination |
| `skill-router` | **C/K user-only; O implicit** | Pervasive `/skill` chaining and Claude built-in `/compact` | Dependencies of every routed downstream skill |
| `tdd` | Default on all | Workflow is portable; test and mocking tools are project-specific | Project test runner/build tools |
| `teach` | **C/K user-only; O implicit** | Claude-only `argument-hint`; `/html-visualization` composition | Web access for sources/communities; visualization stack; workspace writes |
| `to-spec` | **C/K user-only; O implicit** | Instructions are mostly portable; GitHub publishing and cross-skill assumptions are not | Authenticated `gh`, GitHub network, repository reads |
| `to-tickets` | **C/K user-only; O implicit** | `/domain-modeling` reference and GitHub native sub-issue/dependency operations | Authenticated `gh`, GitHub network |
| `wayfinder` | **C/K user-only; O implicit** | `/research` subagents and extensive `/skill` chaining; orchestration API unspecified | Authenticated `gh`, GitHub network, subagents, git branches/worktrees |
| `writing-great-skills` | **C/K user-only; O implicit** | Its claim that `disable-model-invocation` hides a skill is false on OpenCode | File reads only |

## Dependency inventory

**Verified — baseline repository scan.** Dependencies were encoded only in
prose, shell examples, and runner preflights:

- Provider CLIs and credentials: `claude`, `codex`, `cursor-agent`.
- GitHub workflows: authenticated `gh`, `git`, and outbound GitHub access.
- Visualization: `playwright-cli`, a compatible installed browser, Python 3
  HTTP server, `curl`, localhost process/socket access, and sometimes CDN or
  browser-download network access.
- Scripts: Bash/POSIX utilities, Python 3, `jq`, GNU `xargs`, temp directories,
  and platform-specific openers (`xdg-open`, `open`, `start`).
- Harness capabilities: background/parallel subagents, user questioning,
  filesystem edits, shell execution, web access, and image/file delivery.
- Product state: Codex history layout and `CODEX_HOME`, Claude settings/plugins,
  Cursor workspace config and trust state.

The follow-up `requirements.txt` records the shared executable names and
`scripts/check-requirements.sh` reports whether each is present. It remains a
loose inventory: the checker deliberately does not claim version, auth,
network, browser-bundle, model, or project-toolchain compatibility.

**Verified — standard limitation.** `compatibility` is a free-text field up to
500 characters. The standard says scripts should be self-contained or clearly
document dependencies, but defines no package manager, version constraint
schema, capability negotiation, install hook, or runtime dependency check.
Codex's product extension declares MCP tool dependencies only. Claude says it
does not act on `compatibility`. OpenCode documents the field but no resolver.

## Unknowns and untested behavior

- **Untested:** executing every skill's representative task end-to-end on all
  three providers. Loader success is not behavioral success.
- **Untested:** Windows and macOS behavior, especially Bash/GNU assumptions,
  browser installation, temp paths, and platform openers.
- **Untested:** whether a model reliably interprets `/skill-name` as prose and
  substitutes an available Codex/OpenCode activation mechanism without an
  adapter instruction.
- **Untested:** permission and sandbox equivalence across the three clients;
  their tool allow/deny models are not semantically interchangeable.
- **Inferred:** relative Markdown resource links are the strongest portable
  path form because the standard defines them from the skill root. Bare
  placeholders such as `/absolute/path/to/codex-agent/scripts/run-profiled.sh`
  require model resolution and are not a host guarantee.
- **Verified:** Claude-local frontmatter extensions work in Claude Code, but
  Claude's docs say claude.ai/API packaging hard-fails fields outside the six
  Agent Skills fields. Thus the ten user-only skills and two `argument-hint`
  skills are not strict portable upload bundles even though Claude Code plugin
  validation succeeds.
