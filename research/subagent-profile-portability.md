# Portable subagent profiles for issue #14 point 5

> Research note, 2026-08-01. Follow-up to
> [`agent-permission-allowlists.md`](./agent-permission-allowlists.md), evaluating
> three ways to package and transport the subagent permissions required by
> [issue #14 point 5](https://github.com/ejarmand/skills/issues/14#issuecomment-5147950617).
> The resulting implementation outline was posted back to
> [issue #14](https://github.com/ejarmand/skills/issues/14#issuecomment-5149791026).
>
> Current local versions: Codex CLI 0.146.0 and Cursor CLI
> 2026.07.23-e383d2b. Sources are first-party documentation, first-party source,
> issue trackers, installed CLI help, and the live probes recorded below.

## Conclusion

The three scenarios are layers, not alternatives:

1. **Authoring:** define a named provider-neutral authority contract in
   `cross-provider-agent`, with each provider-specific encoding beside the
   adapter that owns that CLI mechanism.
2. **Transport:** have each CLI adapter load or stage that profile for one
   dispatch.
3. **Distribution:** later expose the same profile through native agent/plugin
   installation where the provider supports it.

For issue #14, implement **1 + 2** now and treat **3** as optional distribution
UX. Do not make installation a prerequisite for `cross-provider-agent`.

Codex 0.146.0 can dynamically load a custom-agent TOML by absolute path through
`-c agents.<role>.config_file=...`; a sibling `rules/` directory is also loaded
for that child. This was verified end to end with a read-only child whose only
sandbox escape was `gh issue view`. The child must be a fresh/no-history spawn.

Cursor can discover custom agents and Cursor plugins can package them, but its
CLI has no `--agent`, `--agents`, or arbitrary profile-file flag. Its command
permissions and network sandbox remain workspace/user configuration rather than
fields in a custom-agent file. The adapter therefore needs to stage scoped
`.cursor/cli.json` and `.cursor/sandbox.json` configuration (or use an already
installed plugin/profile) for the dispatch.

Claude Code is the clearest reference design: it supports plugin-provided agents,
session-only `--agents` JSON, and `--agent <name>`. It demonstrates that all three
scenarios can coexist, though plugin agents intentionally cannot ship their own
`permissionMode`, MCP servers, or hooks.

## Keep three meanings of “profile” separate

| Object | Purpose | Codex representation |
| --- | --- | --- |
| Agent profile | Role instructions and child-specific session settings | `.codex/agents/<name>.toml` or `[agents.<role>].config_file` |
| CLI config profile | Named top-level session preset | `$CODEX_HOME/<name>.config.toml`, selected by `--profile <name>` |
| Permission profile | Filesystem and network sandbox boundary | `default_permissions` plus `[permissions.<name>]` |

An agent TOML is a config layer and may contain normal config keys, including a
permission profile, MCP servers, sandbox settings, and skill configuration.
However, issue #14 asks for a **command** allowlist (`gh issue view`, not all
GitHub-bound commands). That remains an execpolicy `.rules` concern. A network
domain allowlist alone would also allow state-changing `gh` requests to the same
domain.

Sources: [Codex custom agents](https://learn.chatgpt.com/docs/agent-configuration/subagents#custom-agents),
[Codex profiles](https://learn.chatgpt.com/docs/config-file/config-advanced#profiles),
[Codex permission profiles](https://learn.chatgpt.com/docs/permissions), and
[Codex execpolicy rules](https://learn.chatgpt.com/docs/agent-configuration/rules).

## Scenario 1: profiles nested in skills and used on the fly

### Verdict: best authoring shape; native discovery is provider-dependent

Codex discovers custom agents only from `~/.codex/agents/` and
`.codex/agents/`, or from role declarations in active configuration. Its current
plugin manifest supports skills, MCP servers, apps, hooks, and assets, but has no
agent component. A TOML merely stored under a skill is therefore not
automatically registered in an already-running native session.

There is also no custom-role selector in the `spawn_agent` interface exposed to
this root session. Recent official bug reports show why relying on name matching
is unsafe: tool-backed children have silently inherited the parent instead of
binding the intended role. See
[openai/codex#32587](https://github.com/openai/codex/issues/32587). The current
CLI can bind a registered role, but the skill cannot add a new role to an already
started parent solely by naming a nested file.

Cursor discovers project and user agents from `.cursor/agents/` and also lists
`.claude/agents/` and `.codex/agents/` compatibility locations. Its current
agent schema includes role instructions, model, `readonly`, and background
selection. Cursor plugins can package subagents. This is close to scenario 1,
but a plain skill folder is not itself an agent discovery root.

Claude Code supports project/user agents and plugin `agents/` directories.
Plugin agents are namespaced and explicitly invokable, making a plugin the
native packaging unit for a skill-plus-agent bundle.

Sources: [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents),
[Codex plugin structure](https://developers.openai.com/plugins/build/plugins#plugin-structure),
[Cursor subagents](https://cursor.com/docs/subagents),
[Cursor 2.5 plugins](https://cursor.com/changelog/2-5), and
[Claude Code custom subagents](https://code.claude.com/docs/en/sub-agents).

## Scenario 2: pass profiles to cross-provider CLI calls

### Verdict: recommended execution seam now

This is the strongest path for `cross-provider-agent`, because the adapter
already owns provider-specific invocation mechanics.

### Codex

`codex exec` accepts repeatable `-c key=value` overrides and `--profile <name>`.
`--profile` only selects an installed `$CODEX_HOME/<name>.config.toml`; it is not
an arbitrary file-path flag. The useful zero-install mechanism is instead:

```shell
codex exec --sandbox read-only \
  -c 'agents.issue14_reviewer.description="Read-only issue/PR reviewer."' \
  -c 'agents.issue14_reviewer.config_file="/absolute/skill/path/profiles/codex/reviewer.toml"' \
  'Spawn one fresh issue14_reviewer child for TASK, wait, and return its result.'
```

The role must be spawned without a full-history fork. A live 0.146.0 probe first
attempted a full-history fork and received:

```text
Full-history forked agents inherit the parent agent type; omit agent_type, or
spawn without a full-history fork.
```

The fresh child then returned a marker present only in its
`developer_instructions`, confirming that the dynamic role bound successfully.

A second probe used this layout:

```text
/tmp/issue14-profile/
├── reviewer.toml
└── rules/
    └── reviewer.rules
```

The rule allowed only the prefix `gh issue view`. Under
`codex exec --sandbox read-only`, the custom child successfully ran
`gh issue view 14 --repo ejarmand/skills --json title` and returned issue #14's
real title. The otherwise network-denied sandbox remained in force. This proves
that an agent config layer can carry its adjacent execpolicy rules into the
child without global installation.

Important limitation: Codex has no `codex exec --agent <role>` flag. The command
starts a parent CLI agent which then spawns the configured child, so this costs
an extra context and requires the dispatch prompt to enforce one fresh child and
relay its result. An installed top-level `--profile` avoids that nesting but is
not path-portable.

Sources: installed `codex exec --help` 0.146.0,
[Codex CLI reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli), and
the official [configuration schema](https://github.com/openai/codex/blob/main/codex-rs/core/config.schema.json)
and [config TOML source](https://github.com/openai/codex/blob/main/codex-rs/config/src/config_toml.rs).

### Cursor

Cursor CLI 2026.07.23 has `--plugin-dir <path>` but no `--agent`, `--agents`, or
arbitrary config-profile file flag. A local plugin can make a custom subagent
available, and the prompt can explicitly invoke `/name`, but the agent's
`readonly` field is not the command/network allowlist required by issue #14.

For the exact least-authority policy, the adapter should stage:

- `.cursor/cli.json` with narrow `Shell(gh issue view)`,
  `Shell(gh pr view)`, `Shell(rg)`, and `Shell(head)` allows; and
- `.cursor/sandbox.json` with a read-only workspace and GitHub-only network
  domains.

The multi-word `Shell(...)` behavior is live-tested but undocumented, so keep
the domain allowlist as defense in depth. See the companion
[`agent-permission-allowlists.md`](./agent-permission-allowlists.md#6-addendum-2026-08-01-live-end-to-end-permission-tests).

### Claude Code reference

Claude Code accepts an ephemeral JSON map with `--agents` and can select the
main session role with `--agent <name>`. The JSON supports instructions, tools,
disallowed tools, permission mode, MCP servers, hooks, skills, model, effort,
and other fields. This is the cleanest version of scenario 2 and a useful target
for the cross-provider abstraction.

Source: [Claude Code custom subagents and CLI-defined agents](https://code.claude.com/docs/en/sub-agents#choose-the-subagent-scope).

## Scenario 3: install/invoke profiles like skills

### Verdict: useful distribution UX, but not the runtime contract

Codex now has filesystem installation scopes for custom agents:

- personal: `~/.codex/agents/`
- project: `.codex/agents/`

That is “installed like a skill” at the file level, but not yet at the product
level. Codex plugins cannot declare agents, agents do not appear as `$skill`
invocations, and direct custom-role selection is not a documented `codex exec`
flag. Native invocation is delegation by role/name after discovery.

Cursor and Claude Code plugins do package subagents, so scenario 3 is already a
native distribution path there. Claude additionally supports `--agent`; Cursor
supports explicit `/name` invocation but no top-level CLI role flag.

Profiles that carry permissions deserve a stronger trust ceremony than passive
workflow text. Installation should display the effective tool, command,
filesystem, network, and external-write authority. A reviewer profile that can
publish comments should be separate from the default read-only reviewer profile;
do not silently amend issue #14's “coordinator publishes” rule.

## Recommended shape for issue #14

`cross-provider-agent` owns the logical `github-readonly-reviewer` authority
contract and selects it. The provider adapters own the concrete configuration
because they already own CLI flags, config locations, authentication, and
provider quirks. Keep Standards/Spec review briefs in `code-review`, as the
issue already specifies.

~~~text
skills/
├── cross-provider-agent/
│   └── SKILL.md                       # logical contract and selection
├── codex-agent/
│   └── profiles/github-readonly-reviewer/
│       ├── agent.toml
│       └── rules/
│           └── github-read.rules
└── cursor-agent/
    └── profiles/github-readonly-reviewer/
        ├── cli.json
        └── sandbox.json
~~~

The task prompt remains separate and contains the selected review axis.
Publishing stays coordinator-side unless the caller deliberately selects a
distinct write-authorized profile.

Before landing the PR, automate two conformance checks per backend:

1. the allowed GitHub read plus local text reads succeed; and
2. a nearby write (`gh issue comment`, `gh pr comment`, file edit) fails.

This turns the profile into a tested authority contract instead of relying on
prompt wording or config parsing alone.

## Primary-source index

### Issue and resulting decision

- [Issue #14 design](https://github.com/ejarmand/skills/issues/14)
- [Point 5 clarification](https://github.com/ejarmand/skills/issues/14#issuecomment-5147947457)
- [Point 5 command-allowlist addendum](https://github.com/ejarmand/skills/issues/14#issuecomment-5147950617)
- [Resulting implementation outline](https://github.com/ejarmand/skills/issues/14#issuecomment-5149791026)

### OpenAI Codex

- [Subagents and custom agents](https://learn.chatgpt.com/docs/agent-configuration/subagents)
- [Configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Advanced configuration profiles](https://learn.chatgpt.com/docs/config-file/config-advanced#profiles)
- [CLI command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli)
- [Execpolicy rules](https://learn.chatgpt.com/docs/agent-configuration/rules)
- [Permission profiles](https://learn.chatgpt.com/docs/permissions)
- [Plugin structure](https://developers.openai.com/plugins/build/plugins#plugin-structure)
- [Codex configuration schema](https://github.com/openai/codex/blob/main/codex-rs/core/config.schema.json)
- [Codex config TOML source](https://github.com/openai/codex/blob/main/codex-rs/config/src/config_toml.rs)
- [Open role-routing bug #32587](https://github.com/openai/codex/issues/32587)
- Historical related reports: [#26868](https://github.com/openai/codex/issues/26868) and [#32703](https://github.com/openai/codex/issues/32703)

### Cursor

- [Subagents](https://cursor.com/docs/subagents)
- [CLI overview](https://cursor.com/docs/cli/overview)
- [CLI permissions](https://cursor.com/docs/cli/reference/permissions)
- [Sandbox reference](https://cursor.com/docs/reference/sandbox)
- [Cursor 2.4: subagents and skills](https://cursor.com/changelog/2-4)
- [Cursor 2.5: plugins and sandbox controls](https://cursor.com/changelog/2-5)
- [Cursor plugin announcement](https://cursor.com/blog/marketplace)

### Claude Code reference design

- [Custom subagents](https://code.claude.com/docs/en/sub-agents)
- [CLI reference](https://code.claude.com/docs/en/cli-usage)
- [Plugins](https://code.claude.com/docs/en/plugins)
- [Permissions](https://code.claude.com/docs/en/permissions)
