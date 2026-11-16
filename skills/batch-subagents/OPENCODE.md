# OpenCode batch worker

```bash
cd /absolute/workspace && timeout 30m \
  opencode run --format json --model provider/model#variant "PROMPT"
```

- Pass the prompt as a plain argument. OpenCode 2 sends anything after `--`
  twice.
- The `provider/` prefix decides who sees the prompt. Free, trial and
  Contributor models on OpenCode Zen collect data, so use them only where
  repository policy allows.
- `run` attaches to the user's background OpenCode service unless given
  `--standalone`.
- OpenCode prints nothing while it waits on a provider, and it waits out a
  rate limit or overload (429, 503, 529) for up to 15 minutes a retry. The
  `timeout` is what ends a stuck job.
- A job succeeded when the process exits zero with no error event. OpenCode 2
  does not always emit a final `step_finish`.
