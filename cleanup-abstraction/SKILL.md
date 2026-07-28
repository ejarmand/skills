---
name: cleanup-abstraction
description: Simplify over-abstracted code paths by removing one-call-site helpers, private step-function chains, wrapper dataclasses, and script-only package helpers. Use when a refactor or review should reduce indirection rather than rearrange it, especially in loaders, asset-prep scripts, orchestration code, and narrow runtime flows that have become harder to read than the logic they contain.
---

# Cleanup Abstraction

## Overview

Use this skill to make code simpler.

Prefer inline code, short comments, and direct branches over helper pyramids, boundary theater, and compatibility logic for stale formats.

## Core Standard

Follow these rules unless there is a direct, stated reason not to:

- Focus on brevity and clarity.
- Avoid helper methods unless the same logic is duplicated more than 3 times.
- Let underlying packages raise errors unless context truly needs to be added.
- Reject stale or non-canonical input shapes instead of adding broad compatibility support.

If you disagree with the standard in a specific case, say so directly before changing the code:
- state which rule you want to bend
- state why this case is different
- state what concrete benefit justifies the added complexity

## Main Smells

### One-call-site helpers

Treat these as default deletion candidates:

- `load_x_config`, `build_x_processor`, `resolve_x_source`, `normalize_x_input`
- private helpers like `_resolve_x`, `_prepare_x`, `_load_x`, `_finalize_x`
- helpers whose bodies only hide 3 to 10 obvious lines

Inline them unless they remove real duplication or isolate a genuinely tricky branch.

### Private step-function chains

Treat private wrapper chains as a primary smell, even if no public API is involved.

Bad pattern:
- one runtime flow
- many private functions
- each function calls the next once
- the names do the explanatory work that a comment should do

Prefer one readable function with a couple of real branches.

### Boundary theater

Treat these as suspect:

- two modules for one narrow runtime path
- dataclasses that only shuttle 3 fields from one helper to another
- “resolver” layers that do not create genuine reuse

Collapse them unless there are truly separate responsibilities.

### Script-only helpers in package code

Move shell-facing parsing back into the script when it only exists for one CLI flow.

Do not keep package helpers just to parse things like:
- `GENOME=/path/to/file.fa`
- stringly CLI routing inputs
- thin wrappers around one script call sequence

Keep package code focused on canonical Python inputs.

### Comments replaced by wrappers

If a wrapper function is acting like a comment in function form, inline it and write the comment instead.

## Good Reasons To Keep A Helper

Keep a helper only when at least one of these is true:

- it is reused more than 3 times
- it isolates a branch that is hard to parse inline
- it prevents a subtle bug rather than just visual clutter
- it expresses a stable domain concept, not a step in one flow
- it supports a real integration path with independent value

## Cleanup Workflow

1. Find the real runtime entry points.
2. Identify which branches are actually used in integration paths.
3. Inline one-call-site helpers first, especially private ones.
4. Delete wrapper dataclasses that only move values between helpers.
5. Move script-specific parsing out of package code.
6. Remove support for stale or non-canonical formats.
7. Re-run the integration paths that matter most.

## Review Questions

Ask these before adding or keeping an abstraction:

1. How many real call sites does this have?
2. Would a short comment be clearer than a new function?
3. Does this remove duplication, or only hide a short sequence?
4. Is this supporting production behavior, or stale tests and fixtures?
5. If this helper or module disappeared, would the caller become simpler?

If the answers are weak, inline it.

## Concrete Biases

Bias toward:

- one module instead of two when the split only adds routing
- one function with two real branches instead of five helper layers
- direct `if wrapper_checkpoint: ... else: ...`
- comments over `_resolve_*` and `_finalize_*` scaffolding

Bias against:

- `ResolvedX`, `PreparedX`, `RuntimeX` objects that carry little weight
- private `_step_*` chains in narrow flows
- helper pyramids in loaders and asset-prep code
- package APIs built around script internals
- added support for stale data formats when the fixture should be updated instead

## Success Criteria

Count a cleanup as successful when it does at least one of these:

- reduces total lines in the touched area
- reduces the number of private helpers in the runtime path
- reduces the number of public functions
- reduces the number of modules involved in the same flow
- makes the runtime path readable top-to-bottom without jumping through wrappers

If a refactor increases net code, say so explicitly. Do not present reorganization as simplification.
