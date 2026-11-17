# pstack skills snapshot

- Upstream: <https://github.com/cursor/plugins> (`pstack/`)
- Commit: `bf0c7cd80abdbf7fe47b634978a7d1b4071f71a7`
- Snapshot date: 2026-11-16

Promoted skills:

- `in-your-own-words`
- `ketchup`
- `show-me-your-work`
- `statechart`

Each listed directory was copied unedited, with its references and scripts,
except `statechart/scripts/test/`: the tool's own test suite and its 3.8 MB
corpus of TLC outputs were left out. An `agents/openai.yaml` was added to each
skill, because upstream ships none and the inventory test requires one for a
user-invoked skill.

Local edits since the copy:

- `ketchup`: `/visualize` became `/html-visualization`, this repo's chart and
  diagram skill.
