# Subagent Merge Prompt

Use this prompt after evidence-review subagents return their notes.

```text
Merge the attached steering-case review notes into a compact evidence summary.

Return only:
- merged_cases: one row per unique case with case_id, likely_error, missing_context_or_guardrail, confidence, evidence, expanded_context_used, and ambiguity
- duplicate_or_overlapping_cases: case_ids that refer to the same steering moment
- non_errors: case_ids that reviewers marked as normal follow-up or too ambiguous
- candidate_addressable_groups: tentative groups based on shared missing context or guardrail, with case_ids
- unresolved_questions: only questions that materially affect final categorization

Do not force cases into a predefined taxonomy. Do not write the final report or propose final AGENTS.md/skill changes.
```

Keep the output compact enough for the parent agent to categorize de novo.
