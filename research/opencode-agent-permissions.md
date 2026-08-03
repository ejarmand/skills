# OpenCode agent permissions for issue #18

> Research note, 2026-08-01 UTC. Investigates the six research questions in
> [issue #18](https://github.com/ejarmand/skills/issues/18), with emphasis on
> delegated-agent authority and containment. Primary sources only: OpenCode's
> official documentation, `anomalyco/opencode` source and tests, first-party issue
> tracker, installed CLI help, and the live probes recorded below.
>
> Version pinned for source and live work: OpenCode **1.18.10**, tag
> [`v1.18.10`](https://github.com/anomalyco/opencode/tree/v1.18.10), commit
> [`7902e04c3a67f7c69726bc955efb46e29214c797`](https://github.com/anomalyco/opencode/commit/7902e04c3a67f7c69726bc955efb46e29214c797),
> on Linux. GitHub CLI **2.96.0**. The model-mediated probes used
> `opencode/big-pickle`; no GitHub comment or other external write was made.

## Answer first

An OpenCode profile alone is **not an adequate authority boundary** for issue #18's
reviewer contract.

OpenCode can express last-match-wins command patterns and it correctly gates the
native `write`, `edit`, and `apply_patch` tools. It can also deny native delegation.
But OpenCode's own security policy says that it **does not sandbox the agent** and
that permissions are a UX feature, not security isolation; it recommends Docker or
a VM for true isolation
([SECURITY.md at the tested commit](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/SECURITY.md#no-sandbox)).
The live results justify taking that statement literally:

- A parent agent's denies are not an inherited ceiling for a native child. A live
  child used native `write` to create a file even though its parent had
  `edit: deny`. This is current intended behavior: the source says the child's own
  agent policy determines its capabilities; only **parent session** deny and
  `external_directory` rules are copied into the child session
  ([source](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/agent/subagent-permissions.ts)).
- A naïve `"gh pr view *": "allow"` permitted
  `gh pr view ... > naive-bypass.txt`, creating the file despite `edit: deny`.
  A later `"*>*": "deny"` blocked this particular spelling, but lexical deny
  patterns are hardening, not a complete shell boundary.
- `"gh pr comment *": "allow"` grants more than “post exactly one fresh comment.”
  GitHub CLI 2.96.0 also accepts `--edit-last`, `--delete-last`, `--web`,
  `--editor`, and `--body-file` under that same prefix
  ([official manual](https://cli.github.com/manual/gh_pr_comment)).

The buildable design is therefore a **two-layer adapter**:

1. Use an isolated OpenCode configuration with a catch-all deny, narrow read
   patterns, `edit: deny`, and normally `task: deny`. This reduces accidental tool
   use and gives useful JSON evidence.
2. Run the process inside an OS boundary inherited by every subprocess and native
   child: a read-only worktree in a container/VM (or an equivalently reviewed OS
   sandbox), with separate writable OpenCode state. Expose the single authorized
   comment operation through an adapter-owned validating wrapper rather than
   allowing unrestricted `gh pr comment *`.

Without that outer boundary and wrapper, the requested “reads + exactly one new
comment; every other write denied” conformance claim would be stronger than what
OpenCode provides.

## Results by issue question

| Question | Result in 1.18.10 |
| --- | --- |
| 1. Command-level allowlist | **Yes, syntactically; insufficient alone.** Bash rules match parsed command strings using simple wildcards and the last match wins. Exact subcommand rules work live, but broad argument wildcards include redirections and semantically broader flags. |
| 2. Config isolation | **Possible with a runner, not one documented replacement flag.** `OPENCODE_CONFIG` and `OPENCODE_CONFIG_DIR` are additive. Use a temporary `XDG_CONFIG_HOME`, source-only `OPENCODE_DISABLE_PROJECT_CONFIG=1`, `--pure`, disabled compatibility inputs, late inline config, a unique primary-agent name, and a resolved-policy preflight. Managed/active-organization config loads after inline config, so fail closed on any mismatch. |
| 3. Fail-closed headless | **Root asks auto-reject without stalling, but exit status is not task success.** A live root `ask` was auto-rejected and the process exited 0. Native-child asks can hang because the run loop ignores permission events whose session ID differs from the root; keep every child path explicitly allow/deny or disable `task`. |
| 4. Native write tools | **Governed by `edit`.** A live forbidden native `write` returned a permission error and did not create the file. This does not govern writes performed inside an allowed shell command. |
| 5. Recursion containment | **Not inherited from parent-agent policy.** Native depth defaults to one and worked live; `task: deny` is safer. A nested CLI is a fresh process/config and inherits no OpenCode permission policy, so block its command and rely on the outer OS boundary. |
| 6. Sessions | **Usable.** `--format json` puts the new session ID on every emitted event; resume uses `--session <id>` or `--continue`, optionally `--fork`. The stream ends when internal status becomes idle, but does not emit that idle event. A final `step_finish.reason == "stop"`, no errors, and an explicit completion/effect check are stronger than exit 0 alone. |

## 1. Command-pattern specificity

### Documented facts

OpenCode permission actions are `allow`, `ask`, and `deny`. Granular object rules use
simple `*`/`?` wildcard matching, and **the last matching rule wins**. The docs advise
putting the catch-all first and specific rules after it
([permissions documentation](https://opencode.ai/docs/permissions#granular-rules-object-syntax)).
`bash` matches parsed commands rather than only the executable name
([available permissions](https://opencode.ai/docs/permissions#available-permissions)).

A profile can therefore distinguish these prefixes:

```json
{
  "permission": {
    "*": "deny",
    "bash": {
      "*": "deny",
      "gh issue view": "allow",
      "gh issue view *": "allow",
      "gh pr view": "allow",
      "gh pr view *": "allow",
      "gh pr diff": "allow",
      "gh pr diff *": "allow",
      "gh pr comment": "allow",
      "gh pr comment *": "allow",
      "rg": "allow",
      "rg *": "allow",
      "head": "allow",
      "head *": "allow",
      "*>*": "deny"
    }
  }
}
```

Use both exact and space-wildcard forms. `gh pr view*` would also match an unwanted
prefix such as `gh pr viewer`; `gh pr view *` does not cover the zero-argument form.

### Source-code findings

`Permission.evaluate()` flattens the rule sets and uses `findLast()` over permission
and resource wildcard matches; the fallback is `ask`
([permission/index.ts](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/permission/index.ts#L28-L37)).
The shell tool parses Bash/PowerShell with tree-sitter, gathers every command node,
and submits each command source as a permission resource
([tool/shell.ts](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/tool/shell.ts#L257-L290),
[collection loop](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/tool/shell.ts#L378-L413)).
Compound commands therefore yield multiple resources which must each resolve.

For a redirected command, however, `source()` deliberately returns the entire
`redirected_statement`
([source](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/tool/shell.ts#L119-L125)).
Consequently the glob `gh pr view *` also matches `gh pr view 18 > file`.

The shell's external-directory scanner is also command-specific rather than a
general process sandbox. Paths are inspected only for executables in its internal
`FILES` set; an allowed program not in that set can access paths using the process's
normal OS authority. This is consistent with OpenCode's explicit no-sandbox threat
model.

### Live observations

With `bash: {"*":"deny", "printf OC_ALLOWED":"allow"}`:

- `printf OC_ALLOWED` completed with exit 0 and output `OC_ALLOWED`.
- Neighboring `printf OC_DENIED` returned a permission error.

With `edit: deny` and `bash: {"*":"deny", "gh pr view *":"allow"}`:

- `gh pr view 18 --repo ejarmand/skills --json title --jq .title > naive-bypass.txt`
  was authorized as a bash call and created `naive-bypass.txt`. `gh` itself exited 4
  because the temporary XDG config hid GitHub authentication, but the shell had
  already created the redirection target.
- Adding the later rule `"*>*":"deny"` made the same command a permission error and
  `hardened-blocked.txt` was not created.

The latter rule is worth keeping as defense in depth, but it cannot turn a shell
allowlist into a sandbox. Argument flags can themselves have write effects, and the
allowed `gh pr comment` prefix includes edit/delete-last behavior. The adapter-owned
wrapper should validate the PR identity and accept only a fresh comment body through
a fixed, non-interactive interface.

## 2. Configuration isolation and precedence

### Documented facts

OpenCode merges configuration sources rather than replacing earlier sources.
Documented order is remote, global, custom `OPENCODE_CONFIG`, project,
`.opencode`/custom directories, `OPENCODE_CONFIG_CONTENT`, then managed settings;
later layers win conflicts and preserve non-conflicting settings
([configuration docs](https://opencode.ai/docs/config#precedence-order)).
`OPENCODE_CONFIG` is explicitly loaded between global and project config, and
`OPENCODE_CONFIG_DIR` is another discovery directory, not an isolated home
([custom path/directory](https://opencode.ai/docs/config#custom-path)).

### Source-code findings

The exact loader confirms global config is always read, project config is read unless
`OPENCODE_DISABLE_PROJECT_CONFIG` is true, `.opencode` and custom directories are
then discovered, and inline content is merged late
([config.ts](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/config/config.ts#L398-L475)).
Active-organization and managed configuration is merged **after** inline content
([config.ts](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/config/config.ts#L478-L534)).

`OPENCODE_DISABLE_PROJECT_CONFIG` is implemented and covered by upstream tests, but
is absent from the installed help and current public CLI environment-variable table
([flag source](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/core/src/flag/flag.ts#L52-L56),
[tests](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/test/config/config.test.ts#L1813-L1887)).
Treat it as a pinned-version adapter detail.

### Recommended runner isolation

For each dispatch:

1. create temporary XDG config and OpenCode state directories, retaining only the
   credential material deliberately required by the chosen provider;
2. set `XDG_CONFIG_HOME` to the temporary directory;
3. set `OPENCODE_DISABLE_PROJECT_CONFIG=1`,
   `OPENCODE_DISABLE_CLAUDE_CODE=1`, and supply the profile through
   `OPENCODE_CONFIG_CONTENT`;
4. invoke `opencode run --pure --agent <random-unique-primary-name> --format json`;
5. before dispatch, run `opencode debug config` and
   `opencode debug agent <name>`, parse the resolved permissions/tools, and fail if
   they differ from the expected closed surface; and
6. keep the OS-level worktree mount read-only for the whole process tree.

The unique agent must have `mode: "primary"` or `"all"`. `opencode run --agent`
rejects an agent whose mode is `subagent` and falls back to the default agent
([run.ts](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/cli/cmd/run.ts#L640-L658)).
Fail rather than accepting the fallback warning.

`--pure` removes external plugins, not all configuration sources. Temporary XDG plus
the project-disable flag isolates ordinary user/project layers; the resolved-policy
assertion catches active-organization/managed or unexpected agent-specific
overrides. This is configuration hygiene, not the outer authority boundary.

## 3. Non-interactive fail-closed behavior

### Source-code finding

For a root session, `opencode run` handles `permission.asked` by approving once only
when `--auto` is set; otherwise it logs `auto-rejecting` and replies `reject`
([run.ts](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/cli/cmd/run.ts#L796-L815)).
Explicit `deny` never becomes an ask, and `--auto` does not override explicit denies
([permissions docs](https://opencode.ai/docs/permissions#auto-mode)).

Do **not** use `--auto` for the reviewer. A strict policy should have no `ask` rules.

### Live observation and exit-status trap

With a root bash resource resolving to `ask`, non-interactive `opencode run` printed:

```text
permission requested: bash (printf OC_ASK); auto-rejecting
```

The tool returned `The user rejected permission...`, execution did not stall, and
the process exited **0**. Its final JSON event was `step_finish` with reason
`tool-calls`, not a successful final response. A separately denied command could be
handled by the model and followed by a normal final response, also exiting 0.

Therefore exit 0 means the transport reached idle, not that the delegated task or
all requested actions succeeded.

### Native-child hang caveat

The root event loop ignores `permission.asked` events whose session ID differs from
the root (`if (permission.sessionID !== sessionID) continue` in the source above).
First-party open issue
[#36868](https://github.com/anomalyco/opencode/issues/36868) reports that a Task child
which asks can consequently wait forever while the parent waits for it, including
under `--auto` (reported on 1.17.20). The same root-only filter remains in 1.18.10.

If native subagents are enabled, every possible child resource must resolve directly
to allow or deny. The safer issue-18 profile denies `task` entirely.

## 4. Native write tools

OpenCode documents that the single `edit` permission gates `write`, `edit`, and
`apply_patch`
([agent permissions table](https://opencode.ai/docs/agents#permissions)). The source
maps those three tool IDs to `edit` both for tool hiding and runtime evaluation
([permission/index.ts](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/permission/index.ts#L204-L218)).

Live effect probe:

- policy: `edit: {"*":"deny", "allowed.txt":"allow"}` so the native edit family
  remained visible but the requested path was denied;
- request: native `write` of `FORBIDDEN` to `forbidden.txt`;
- JSON result: tool `write`, status `error`, rule `edit/*/deny`;
- effect: `forbidden.txt` did not exist after the run.

This verifies the native path. It does not cover writes by allowed shell programs,
plugins, MCP tools, LSPs, nested CLIs, or native children with a different effective
policy. The catch-all deny and `--pure` close many of those UX paths; the read-only
OS mount closes the filesystem effect.

## 5. Delegation, inheritance, and recursion containment

### Native subagents do not inherit parent-agent authority

Agent permission rules are merged in this order: permissive built-in defaults,
global user permission, then that agent's own permission
([agent.ts](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/agent/agent.ts#L119-L151),
[custom-agent merge](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/agent/agent.ts#L267-L294)).
An agent-specific later allow can therefore override a global deny.

When Task creates a child, `deriveSubagentSessionPermission()` carries forward only
the parent **session's** deny rules and external-directory rules. The function's own
comment is explicit: “Parent agent restrictions only govern that agent; the
subagent's own permissions determine its capabilities”
([source](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/agent/subagent-permissions.ts#L4-L26)).
The upstream regression suite asserts both that a general child can edit under a
read-only plan parent and that a custom child may explicitly enable edits denied to
its parent
([test](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/test/agent/plan-mode-subagent-bypass.test.ts#L29-L105)).
This is the resolution of the earlier transitive-permission report
[#20549](https://github.com/anomalyco/opencode/issues/20549) and partial ceiling fix
[#23290](https://github.com/anomalyco/opencode/pull/23290), not full parent-policy
inheritance.

Live effect probe confirmed it on 1.18.10:

- custom primary `reviewer`: `edit: deny`, Task allowed only for `general`;
- reviewer delegated a native-write request to built-in `general`;
- child `general` created `child-bypass.txt` containing `CHILD_BYPASS`;
- parent read the file back, and an external shell check confirmed the content.

This directly answers the user's central question: **a parent agent's permission
profile is not inherited as the native subagent's authority ceiling**.

A global catch-all deny is included in every built-in agent before its own config,
so it is a useful floor, but it is not immutable: later per-agent configuration can
widen it. If native delegation is necessary, enumerate every allowed child agent,
give each its own complete closed policy, allow only those names under `task`, and
preflight every resolved agent. For issue #18, `task: deny` is simpler and safer.

### Depth containment

Task walks the parent session chain and rejects when depth is at least
`subagent_depth`, which defaults to **1**
([task.ts](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/tool/task.ts#L104-L117)).
The option is now documented
([config docs](https://opencode.ai/docs/config#subagent-depth)).

Live probe: a primary delegated to a custom worker which was itself explicitly
allowed to delegate to the same worker. The nested call failed with:

```text
Subagent depth limit reached (1). Increase "subagent_depth" to allow nested subagents.
```

Set `subagent_depth: 1` explicitly rather than relying on the default. `task: deny`
remains the stronger control.

### Nested CLI

A shell-spawned `opencode` is a fresh process which performs its own config loading;
there is no OpenCode mechanism that makes it inherit the caller agent's permission
rules. Do not allow the `opencode` executable under `bash`. An outer container/VM or
OS sandbox is inherited by the process and remains the actual ceiling even if a
shell or nested CLI bypasses the UX policy.

## 6. Session IDs, resume, and terminal success

Installed `opencode run --help` on 1.18.10 exposes:

```text
-c, --continue       continue the last session
-s, --session        session id to continue
    --fork           fork before continuing (requires --continue or --session)
    --format         default | json
    --agent          agent to use
```

There is no CLI pre-allocation command. In JSON mode, `run` creates/resolves the
session first and adds its ID to every emitted JSON record
([run.ts](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/cli/cmd/run.ts#L670-L690)).
Capture and persist the `sessionID` from the first valid JSON line. `opencode session
list --format json`, `opencode export <sessionID>`, and `opencode run --session <id>`
are recovery/discovery mechanisms, but the first event is the unambiguous per-run
capture path.

Live resume:

```text
initial ID: ses_04381d014ffe2pWq0VRC7uoYoc
opencode run ... --session ses_04381d014ffe2pWq0VRC7uoYoc \
  'Reply exactly RESUMED and do not use tools.'
```

Every resumed event retained the same ID, the text event was `RESUMED`, and the final
event was `step_finish` with reason `stop`.

Internally, the CLI breaks its event loop when the active session status becomes
idle, but does not print that idle event in JSON mode
([run.ts](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/packages/opencode/src/cli/cmd/run.ts#L776-L818)).
`session.error` makes the process nonzero, while a permission-denied tool may still
exit 0. Adapter terminal success should require all of:

1. process exit 0;
2. a captured session ID;
3. no JSON `error` event and no `tool_use` with `state.status == "error"`;
4. a final `step_finish` with `reason == "stop"`;
5. the adapter's explicit completion marker in the final text; and
6. effect checks: clean/unchanged read-only worktree and exactly the expected marker
   comment when publication is exercised.

## Reproducibility: live probe shape

All model-mediated probes used this isolation prefix, changing only inline policy
and the prompt:

```bash
XDG_CONFIG_HOME=/tmp/opencode-issue18-probe/xdg \
OPENCODE_DISABLE_PROJECT_CONFIG=1 \
OPENCODE_DISABLE_CLAUDE_CODE=1 \
OPENCODE_PURE=1 \
OPENCODE_CONFIG_CONTENT='<JSON shown by each probe>' \
opencode run --pure \
  --model opencode/big-pickle \
  --agent reviewer \
  --format json \
  --dir /tmp/opencode-issue18-probe/work \
  '<probe prompt>'
```

Representative requested commands/effects:

```text
printf OC_ALLOWED
printf OC_DENIED
printf OC_ASK
native write: forbidden.txt = FORBIDDEN
gh pr view 18 --repo ejarmand/skills --json title --jq .title > naive-bypass.txt
same command > hardened-blocked.txt after adding "*>*": "deny"
native child write: child-bypass.txt = CHILD_BYPASS
native worker -> worker recursion with subagent_depth=1
resume the captured session with --session and reply RESUMED
```

The JSON events and filesystem effects were inspected immediately after each run.
The marker-comment stage was deliberately not executed because research did not
authorize an external write. The GitHub read in the redirect probe was unauthenticated
because the temporary XDG directory also hid `gh` config; that limitation strengthens,
rather than weakens, the redirection observation because the empty target was created
before the failing program ran.

Model-mediated tool choice is nondeterministic, so these observations should become
deterministic conformance fixtures before landing an adapter. Pin OpenCode by both
version and commit, assert the resolved agent policy, run positive and neighboring
negative effects, and enforce a timeout around every run (especially any native-child
configuration).

## Implementation decision for issue #18

Proceed only if the adapter includes OS containment and a validating comment shim.
The profile should still use OpenCode permissions as a useful inner layer, but its
conformance statement must not call them a sandbox.

Minimum safe shape:

- random unique primary agent selected explicitly; fallback warning is fatal;
- temporary config/state and `OPENCODE_DISABLE_PROJECT_CONFIG=1`;
- `--pure`, no `--auto`, `share: "disabled"`;
- catch-all deny, explicit local read/search allows, `edit: deny`,
  `external_directory: deny`, `task: deny`, exact command pairs, and trailing shell
  metacharacter denies as defense in depth;
- resolved-config and resolved-agent comparison before the model runs;
- read-only OS-mounted worktree inherited by all descendants;
- adapter-owned `post-review-comment` command which rejects edit/delete/web/editor,
  fixes the repository and PR target, accepts one bounded body, and records a
  deterministic marker;
- timeout, JSON error/tool-error checks, completion marker, clean-tree verification,
  and external comment effect verification.

If container/VM/equivalent containment is outside the intended adapter scope, record
OpenCode as **unsupported for the write-authorized reviewer profile**, rather than
claiming the profile itself enforces the authority contract.

## Primary-source index

- [Issue #18](https://github.com/ejarmand/skills/issues/18)
- [OpenCode permissions](https://opencode.ai/docs/permissions)
- [OpenCode agents](https://opencode.ai/docs/agents)
- [OpenCode configuration and precedence](https://opencode.ai/docs/config)
- [OpenCode CLI](https://opencode.ai/docs/cli)
- [OpenCode security policy](https://github.com/anomalyco/opencode/blob/7902e04c3a67f7c69726bc955efb46e29214c797/SECURITY.md)
- [OpenCode 1.18.10 source](https://github.com/anomalyco/opencode/tree/7902e04c3a67f7c69726bc955efb46e29214c797)
- [Transitive-permission issue #20549](https://github.com/anomalyco/opencode/issues/20549)
- [Partial child-session ceiling PR #23290](https://github.com/anomalyco/opencode/pull/23290)
- [Headless child-permission hang #36868](https://github.com/anomalyco/opencode/issues/36868)
- [GitHub CLI `gh pr comment` manual](https://cli.github.com/manual/gh_pr_comment)
