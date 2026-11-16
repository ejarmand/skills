# Codex batch worker

```bash
codex exec --json --sandbox read-only -C /absolute/workspace \
  -m gpt-6-luna -c model_reasoning_effort=high "PROMPT"
```

- Use `--sandbox workspace-write` when the job writes files. `codex exec`
  never asks for approval, so a sandboxed command that needs network fails.
- Model slugs take the full `gpt-<version>-<name>` form.
  `~/.codex/models_cache.json` lists the ones the account serves.
- A job succeeded when the process exits zero and the stream ends in
  `turn.completed`; `turn.failed` or `error` is a failure. The result is the
  last `item.completed` whose item type is `agent_message`, or the file named
  by `--output-last-message`.
