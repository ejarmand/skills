# Subagent Review Prompt

Use this prompt when delegating batches of collected steering cases.

```text
Review the attached Codex steering cases. For each case, infer whether the prior assistant likely made an error that caused the user to correct, interrupt, redirect, or constrain it.

Return concise structured notes only. Do not propose AGENTS.md or skill changes; the parent agent will do final categorization and recommendations.

If the excerpt is inadequate, inspect only narrow extra context from the cited session log. Use the case path, line, and session_id to read nearby JSONL records or adjacent turns. Do not search unrelated sessions. Report any extra lines or turns you inspected.

For each meaningful case, report:
- case_id
- likely_error: one sentence
- evidence: short reference to the user steering and assistant context
- missing_context_or_guardrail: what instruction, habit, check, or workflow would likely have prevented the error
- confidence: high, medium, or low
- ambiguity: anything that could make the case a false positive
- expanded_context_used: yes/no, with line or turn references if yes

After the per-case notes, include:
- addressable_groups: 3-7 short bullets grouping cases by likely missing context or guardrail
- non_errors: case_ids that look like normal follow-up rather than steering
```

Pass only the case batch and this prompt. Do not include the parent agent's suspected taxonomy or recommendations.
