# Subagent Case Cleanup Prompt

Use this prompt when delegating cleanup of raw collector output before evidence review.

```text
Clean the attached Codex steering candidate cases for later review.

Return only:
- kept_cases: case_ids that should be reviewed, with a one-phrase reason
- dropped_cases: case_ids that appear to be false positives, with a one-phrase reason
- suggested_batches: groups of case_ids for review, preserving sessions together where possible
- cleanup_notes: short notes about duplicate cases, missing fields, or thin excerpts

Keep raw evidence intact. Do not infer final failure modes, do not propose prevention changes, and do not rewrite case text.
```

Use this for speed and context control when the collector returns more than a small handful of cases.
