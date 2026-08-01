# Per-command allowlists for dispatched subagent CLIs

> Research note, 2026-07-31. Investigates the question from issue #14's "Addendum to
> point 5 (subagent tool access)": can each dispatched CLI grant specific
> network-touching reads (`gh issue view`, `gh pr view`) plus text tools (`rg`, `head`)
> via a per-command allowlist, instead of blanket sandbox loosening?
>
> Location note: the repo had no research-notes convention (ad-hoc notes live loose at
> the root), so this starts a dedicated `research/` directory.
>
> Versions checked: codex-cli **0.146.0**, cursor-agent **2026.07.23-e383d2b**,
> gh **2.96.0** (all installed locally); Codex docs (developers.openai.com, now
> 308-redirecting to learn.chatgpt.com) and `openai/codex@main` source, Cursor docs
> (cursor.com/docs), and Claude Code docs (code.claude.com) all fetched 2026-07-31.

## Answer first

| CLI | Per-command allowlist? | Mechanism |
| --- | --- | --- |
| Codex CLI | **Yes** (experimental) | execpolicy `.rules` files: `prefix_rule` with subcommand-level patterns; `decision = "allow"` runs the matched command *outside* the sandbox (so network works) without prompting. Verified live on 0.146.0. |
| Cursor CLI | **Yes** (undocumented) | Docs define `Shell(commandBase)` as first-token matching, but live tests (§6, 2026-08-01) show multi-word rules like `Shell(git log)` match at subcommand level on both allow and deny. Plus a domain-level network allowlist in `sandbox.json` as a second layer. |
| Claude Code | **Yes** | `Bash(gh issue view:*)` prefix rules, `dontAsk` mode to auto-deny the rest, and/or sandbox `network.allowedDomains`. Documented subcommand-level matching with operator-aware splitting. |

The addendum's doctrine holds: the *doctrine* (network-touching reads via explicit
allowlist, not a broader sandbox) is expressible everywhere, but the *mechanism* is
CLI-specific. Full subcommand granularity is available in all three — though Cursor's
is undocumented behavior (verified live, §6), so its domain allowlist should stay on
as a second layer.

## 1. OpenAI Codex CLI

### Sandbox modes and network

`--sandbox` accepts `read-only | workspace-write | danger-full-access`
(`codex exec --help`, 0.146.0). In source, both restricted modes carry a
`network_access: bool` whose doc comment reads "When set to `true`, outbound network
access is allowed. `false` by default":

```rust
// codex-rs/protocol/src/protocol.rs (main @ 2026-07-31), SandboxPolicy
ReadOnly       { network_access: bool /* #[serde(default)] → false */ }
WorkspaceWrite { writable_roots, network_access: bool /* default false */, .. }

pub fn has_full_network_access(&self) -> bool {
    match self {
        SandboxPolicy::DangerFullAccess => true,
        SandboxPolicy::ReadOnly { network_access, .. } => *network_access,
        SandboxPolicy::WorkspaceWrite { network_access, .. } => *network_access,
        ...
    }
}
```

The only documented config toggle is for workspace-write:
`sandbox_workspace_write.network_access` — "Allow outbound network access inside the
workspace-write sandbox" ([config reference](https://developers.openai.com/codex/config-reference),
also `codex-rs/config/src/types.rs:929`, `#[serde(default)]` → `false`).

### Approvals in headless runs

`approval_policy` values: `untrusted | on-request | never |
{ granular = { sandbox_approval, rules, mcp_elicitations, request_permissions, skill_approval } }`;
"`on-failure` is deprecated" ([config reference](https://developers.openai.com/codex/config-reference)).
`codex exec` hard-defaults to never asking:

```rust
// codex-rs/exec/src/lib.rs (main @ 2026-07-31)
// Default to never ask for approvals in headless mode.
approval_policy: Some(AskForApproval::Never),
```

So under `codex exec --sandbox read-only`, a command that needs network has **no
escalation path at runtime** — it just fails inside the sandbox. Pre-authorization via
rules is the mechanism that exists for this.

### The rules mechanism (execpolicy)

Documented at [Rules](https://developers.openai.com/codex/exec-policy)
(→ learn.chatgpt.com/docs/agent-configuration/rules); "Rules are experimental and may
change." Starlark `.rules` files load from `~/.codex/rules/default.rules` (user) and
`<repo>/.codex/rules/` ("loads only when trusted"). `codex exec --ignore-rules`
disables loading ("Do not load user or project execpolicy `.rules` files",
`codex exec --help` 0.146.0); there is **no per-run `--rules` flag on `exec`** — only
`codex execpolicy check --rules <PATH>` takes one.

Decisions: `allow` — "Run the command outside the sandbox without prompting";
`prompt`; `forbidden`. "Codex applies the most restrictive decision when more than one
rule matches (`forbidden` > `prompt` > `allow`)." Command chains using only
`&&`/`||`/`;`/`|` are split and each part evaluated separately; scripts with
redirection or substitutions are evaluated as one `["bash", "-lc", ...]` invocation
(which won't match a `gh` prefix — it falls to the sandbox default).

### Least-authority reviewer config — verified live

`rg` and `head` need no rule at all: they run inside the read-only sandbox. Only the
network-touching reads need rules, in `~/.codex/rules/default.rules` (or a trusted
repo's `.codex/rules/`):

```starlark
prefix_rule(
    pattern = ["gh", ["issue", "pr"], "view"],
    decision = "allow",
    justification = "reviewer may read issue/PR state",
)
```

Verified with codex-cli 0.146.0 on 2026-07-31:

- `codex execpolicy check --rules reviewer.rules -- gh issue view 14` → `"decision": "allow"`
- `... -- gh pr create --title x` → no allow match (falls to sandbox default)

**Footgun (verified):** adding a broad fallback like
`prefix_rule(pattern = ["gh"], decision = "prompt")` makes `gh issue view` resolve to
`prompt` — most-restrictive-wins turns the fallback into a blocker, and under exec's
`Never` approval a prompt can't surface. Write only the narrow `allow` rules; leave
everything else to the sandbox default.

**Trade-off:** `allow` runs the command *unsandboxed*, so an allowed `gh issue view`
gets network *and* filesystem access. The allowlist bounds *which commands* escape the
sandbox, not what an escaped command could do — acceptable for read-only `gh`
subcommands, which is exactly why the allowlist should stay at `view`-level prefixes.

**Reliability caveats (open issues in openai/codex):**
[#15298](https://github.com/openai/codex/issues/15298) — on Windows (Codex App,
`windows.sandbox = "elevated"`), prefix rules returning `allow` from
`execpolicy check` still trigger approval prompts (open bug, no maintainer response as
of 2026-07-31); [#13175](https://github.com/openai/codex/issues/13175) — prefix
matching fails for shell wrappers and env-prefix commands. The
`codex-rs/execpolicy` README also marks the CLI surface "still in preview".

## 2. Cursor CLI (`cursor-agent`)

### Permissions config

[Permissions reference](https://cursor.com/docs/cli/reference/permissions): global
`~/.cursor/cli-config.json`, project `<project>/.cursor/cli.json`, structure
`{"permissions": {"allow": [...], "deny": [...]}}`, "Deny rules take precedence over
allow rules." Shell rules are `Shell(commandBase)` where commandBase is "the first
token in the command line"; every documented example is a single binary (`Shell(ls)`,
`Shell(git)`, `Shell(curl:*)`). **Subcommand scoping like `gh issue view` is not
documented** — rules are per-binary. Other rule types: `Read(pathOrGlob)`,
`Write(pathOrGlob)`, `WebFetch(domainOrPattern)`, `Mcp(server:tool)`.

For print mode, the docs say only: "Use `permissions.allow`, `permissions.deny`, and
`--force` to control what runs without prompts." What a denied command does in `-p`
(skip vs stall) is not specified in the docs.

### Sandbox and network

[sandbox.json reference](https://cursor.com/docs/reference/sandbox): `~/.cursor/sandbox.json`
(user) and `<workspace>/.cursor/sandbox.json` (repo, higher priority). Sandbox `type`:
`workspace_readwrite` (default) | `workspace_readonly` | `insecure_none`. Network is
**deny-by-default** with a domain allowlist:

```json
{
  "type": "workspace_readonly",
  "networkPolicy": {
    "default": "deny",
    "allow": ["api.github.com", "github.com"]
  }
}
```

Patterns: exact domain, `*.example.com`, CIDR; "deny always beats allow"; merge order
per-user < per-repo < team-admin < hardcoded. The CLI exposes
`--sandbox enabled|disabled` (`cursor-agent --help`, 2026.07.23) and the
[2.5 changelog](https://cursor.com/changelog/2-5) announced the three network levels
(user config only / user config + Cursor defaults / allow all). The sandbox.json page
doesn't explicitly confirm CLI coverage — it's written for Cursor's agent generally.

### Least authority in Cursor

Per the docs, the closest expressible configuration: `--mode plan` (read-only per
`cursor-agent --help`) or `type: workspace_readonly`, plus `permissions.allow` of
`Shell(gh)`, `Shell(rg)`, `Shell(head)` and a `networkPolicy` allowing only GitHub
domains — because `Shell(commandBase)` is documented as first-token matching, which
would let `gh pr merge` ride the same binary and domain as `gh pr view`.

**Superseded by live testing (§6):** multi-word Shell rules in fact match at
subcommand granularity on both allow and deny, so `Shell(gh issue view)` /
`Shell(gh pr view)` allows are enforceable. This is undocumented behavior — keep the
`networkPolicy` domain allowlist as a second layer in case an update reverts it.

## 3. Claude Code (coordinator side)

From [Permissions](https://code.claude.com/docs/en/permissions) and
[Sandboxing](https://code.claude.com/docs/en/sandboxing), fetched 2026-07-31:

- Bash rules are prefix/glob patterns: `Bash(gh issue view:*)` (the `:*` suffix equals
  a trailing ` *`). Wildcards can sit at any position; a trailing ` *` enforces a word
  boundary.
- Evaluation order is "deny, then ask, then allow. The first match in that order
  determines the outcome, and rule specificity doesn't change the order" — so **a
  broad `deny Bash(gh *)` cannot carry a narrow allow exception**. The clean
  least-authority shape for an unattended subagent is `dontAsk` mode ("Auto-denies
  tools unless pre-approved") plus narrow allows:

  ```json
  { "permissions": { "allow": [
      "Bash(gh issue view:*)", "Bash(gh pr view:*)",
      "Bash(rg:*)", "Bash(head:*)"
  ] } }
  ```

  (`head`, `grep`, and other built-in read-only commands already run promptless.)
- Compound commands split on `&&`, `||`, `;`, `|`, `|&`, `&`, newlines; "A rule must
  match each subcommand independently." A fixed wrapper list (`timeout`, `nice`, …) is
  stripped. The docs explicitly warn that argument-constraining patterns are fragile
  (the `curl http://github.com/ *` example) and recommend domain-level control
  instead.
- Sandbox: OS-enforced (Seatbelt / bubblewrap+socat); network is proxy-mediated with
  "no domains pre-allowed by default", `sandbox.network.allowedDomains` to pre-allow,
  `strictAllowlist` (v2.1.219+) to deny instead of prompt, and the
  `dangerouslyDisableSandbox` retry escape hatch gated by `allowUnsandboxedCommands`.
  Troubleshooting notes that Go-based CLIs **including `gh`** "may fail TLS
  verification under Seatbelt" on macOS → `excludedCommands` — i.e. even Claude Code's
  own answer for `gh`-in-sandbox is a scoped exclusion, not a wider sandbox.

## 4. The addendum's premises, checked

**(a) "Default read-only sandbox denies network" — confirmed for Codex.**
`SandboxPolicy::ReadOnly.network_access` is `#[serde(default)]` → `false`, doc comment
"`false` by default" (`codex-rs/protocol/src/protocol.rs`, main @ 2026-07-31), and no
config key exposes read-only network (only `sandbox_workspace_write.network_access`
exists). Claude Code's sandbox likewise pre-allows no domains; Cursor's
`networkPolicy.default` is `deny`.

**(b) "Sandbox network denial ≠ auth failure" — confirmed by live experiment**
(gh 2.96.0, 2026-07-31). Network-blocked (dead proxy):

```
Get "https://api.github.com/rate_limit": proxyconnect tcp: dial tcp 127.0.0.1:9: connect: connection refused
```

Actual auth failure (`GH_TOKEN=invalid`):

```
{"message": "Bad credentials", "documentation_url": "https://docs.github.com/rest", ...}
```

Distinct shapes: transport failures are Go `dial`/`lookup`/`connect` errors naming the
URL; auth failures are HTTP 401 bodies saying "Bad credentials". The adapters' rule is
sound and mechanically checkable.

## 5. Gaps and contradictions with the adapter skills

- **`skills/codex-agent/SKILL.md` "Monitor and collect":** "retry the same scoped
  command using the environment's approval or network-escalation mechanism" — under
  `codex exec` there is no such runtime mechanism: headless approval is hardcoded
  `AskForApproval::Never`. The working mechanism is *pre*-authorization via `.rules`
  files, which the skill only references negatively (`--ignore-rules` in its
  never-add list). If #14's doctrine lands, the Codex adapter's concrete flag is a
  rules-file recipe, not a retry recipe.
- **`skills/codex-agent/SKILL.md` read-only default for review** — consistent with
  current docs and source.
- **`skills/cursor-agent/SKILL.md`** — `--sandbox enabled` exists as documented, but
  the skill doesn't mention `sandbox.json` `networkPolicy`, which is where Cursor's
  domain allowlist actually lives. The `-p`-requires-`--trust` and
  `--auto-review`-stall claims were not re-verified here (no live `-p` run was made).
- **Issue #14 addendum wording** — "per-subagent command allowlist (e.g. allow
  `gh issue view` / `gh pr view`, `rg`, `head`; deny writes and everything else)" is
  fully expressible in all three CLIs. (This bullet originally said "not in Cursor at
  subcommand granularity", per the docs; superseded by the §6 live tests showing
  multi-word `Shell(...)` rules do match.) Also note the allowlist doesn't need to
  cover `rg`/`head` on Codex at all — those run inside the read-only sandbox; only
  the network-touching `gh` reads need rules.
- **Stability caveat for cross-provider-agent doctrine:** Codex rules are explicitly
  experimental with open matching bugs (#15298, #13175); any adapter text should say
  "verify with `codex execpolicy check`" rather than trusting the rule file blindly.

## 6. Addendum 2026-08-01: live end-to-end permission tests

Run locally (codex-cli 0.146.0, cursor-agent 2026.07.23-e383d2b, Linux) after the
initial note; these tests exercise the real dispatch path, not just policy checkers.

### Cursor: multi-word Shell rules work (undocumented)

Test repo with project `.cursor/cli.json`; `-p` print mode throughout.

| Config | Invocation | Command | Result |
| --- | --- | --- | --- |
| allow `Shell(git)`, deny `Shell(git log)` | `-p --force` | `git log --oneline -1` | **DENIED** ("Command blocked by permissions configuration") |
| same | `-p --force` | `git status --short --branch` | RAN (deny is targeted, not a parse-failure deny-all) |
| allow `Shell(git log)` only | `-p --trust` | `git log --oneline -1` | **RAN** (multi-word allow matched) |
| same | `-p --trust` | `git status --short` | **DENIED** ("`Rejected:`") — non-allowed commands auto-deny in print mode, no stall |

Conclusions: (a) `Shell(...)` rules match multi-word prefixes on both allow and deny,
despite the docs defining commandBase as "the first token"; (b) `--force` still honors
explicit denies (allow-unless-denied); (c) plain `-p` without `--force` is
deny-unless-allowed and does not stall on denial; (d) `-p` refuses to run in an
untrusted directory at all — pass `--trust` (trusts the cwd without force-allowing
commands). So the full reviewer allowlist (`Shell(gh issue view)`, `Shell(gh pr view)`,
`Shell(rg)`, `Shell(head)`) IS expressible; being undocumented, pair it with the
`sandbox.json` `networkPolicy` GitHub-domain allowlist as defense in depth.

### Codex: project-local rules verified on the real `exec` path

Test repo with `.codex/rules/reviewer.rules` containing the §1 `prefix_rule`
(`["gh", ["issue", "pr"], "view"]` → allow), run under `codex exec --sandbox read-only`:

- `gh issue view 1 --repo cli/cli` → real GitHub GraphQL response ("Could not resolve
  to an Issue with the number of 1") in 485ms — the command escaped the sandbox and
  reached the API with working auth. Note it executed as `/bin/bash -lc 'gh issue
  view ...'` and still matched, so simple `bash -lc` wrapping is unwrapped for policy
  evaluation.
- `gh api rate_limit` (no matching rule, same session setup) →
  `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted` — it stayed inside
  the sandbox and couldn't even bring up loopback. This is a third error shape for
  the "network denial ≠ auth failure" rule (alongside `dial tcp ... connection
  refused` and HTTP 401), specific to Linux bubblewrap network isolation.

**Trust gating did not bite:** the rules loaded and allowed the escape both with and
without `-c 'projects."<dir>".trust_level="trusted"'`, in a fresh local git repo never
marked trusted in `~/.codex/config.toml` (verified absent before and after). The docs'
"loads only when trusted" gate either doesn't apply to `exec` on 0.146.0 or trusts
fresh local repos implicitly. Two consequences: the recipe needs no trust ceremony in
practice, but trust also cannot be relied on as a *blocker* against a hostile repo's
`.codex/rules/` — another reason dispatch worktrees should be coordinator-created.
(The machine used Codex's bundled bubblewrap — `bwrap` not on PATH — and enforcement
still held.)

### CLI-passability, corrected: Cursor file-only; Codex flag-passable after all

An earlier revision of this note claimed neither external CLI can take the permission
config via flags. Half right. Cursor: confirmed — the full `cursor-agent --help`
(88 lines, 2026-08-01) has no allow/deny/permission/profile flag (`--force`,
`--trust`, `--sandbox enabled|disabled`, `--mode`, `--plugin-dir` are the whole
surface); staging `.cursor/cli.json` + `.cursor/sandbox.json` is the only
per-dispatch path. Codex: **wrong** — as found in
[`subagent-profile-portability.md`](./subagent-profile-portability.md),
`codex exec -c 'agents.<role>.config_file="/abs/path/reviewer.toml"'` loads the agent
TOML as a config layer, and since Codex scans `rules/` under every active config
layer, a `rules/` directory sibling to that TOML rides along — no worktree or global
mutation. Independently reproduced here (0.146.0, 2026-08-01): fresh workdir with no
`.codex/` anywhere, profile passed only via the two `-c` flags, parent instructed to
spawn one fresh `reviewer` child; the child ran
`gh issue view 14 --repo ejarmand/skills --json title` through the read-only sandbox
and returned the real title. Trade-offs vs the project-layer file drop: no
`codex exec --agent` flag exists, so a parent agent must spawn the child and relay
its result (~17.4k tokens vs ~7.2k for the direct-rules run of the same read), the
child must be a fresh spawn (a full-history fork rejects `agent_type`), and role
binding has an open reliability bug
([openai/codex#32587](https://github.com/openai/codex/issues/32587)) — though a
failed binding fails *closed* here (child without the role gets no rules, hence no
network escape). Both Codex mechanisms are now live-verified; choose per dispatch:
project-layer drop for the simple, adapter-symmetric recipe; `config_file` when the
worktree must stay untouched.

## 7. Addendum 2026-08-01: Codex native file writes bypass the read-only sandbox

Found by the `github-pr-reviewer` live conformance probes
(`scripts/conformance-profiles.sh`, codex-cli 0.146.0, Linux):

- Profiled dispatch (`--sandbox read-only` + agent config layer): an instructed
  file creation in the workspace **succeeded** — the conformance canary caught
  `conformance-denied.txt` and a dirty tree.
- Plain `codex exec --sandbox read-only` with no agent layer: `apply_patch`
  created the file after a syntax retry — the bypass is provider-level, not
  introduced by the agent config layer.
- `-c features.apply_patch_freeform=false` did not remove the capability; the
  model fell back to "a direct exact-byte write" and the file landed.
- No kill switch found in the 0.146.0 schema: the `tools` section toggles only
  `experimental_request_user_input`/`update_plan`/`web_search`, and
  `AgentRoleToml` carries only `config_file`/`description`/`nickname_candidates`.
- Shell writes remain sandbox-governed (on this machine every sandboxed shell
  command fails at bwrap loopback setup — the §6 error shape — so shell
  enforcement could not be distinguished from environment failure here).
- `gh search issues` on openai/codex found no existing report; worth filing.

Consequence: on Codex, the profile's "forbids filesystem writes" is currently
**detect-and-reject, not prevent**. The coordinator's post-dispatch check —
pinned head, clean tree, discard the review otherwise — is the operative
guard, now stated in cross-provider-agent's dispatch step. A chmod-based
transactional wrapper (drop user-write bits before dispatch, restore after)
would convert native writes into EACCES failures and is the hardening path if
upstream does not fix; shell `chmod +w` escape attempts stay sandbox-blocked.
