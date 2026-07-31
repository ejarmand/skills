# The Code Standard

The single code standard for this collection: the bar structure must clear to
exist, the module merge/split rule, the boundary rules, and the named smells.
`/code-review` pastes this whole file into its Standards sub-agent;
implementers hold their own diff to it before review. It travels standalone —
everything a reviewer needs is in this file.

Two rules bind everything below:

- **The repo overrides.** A documented repo standard always wins; where it
  endorses something this file would flag, suppress the finding.
- **Always a judgement call.** Every rule here is a labelled heuristic
  ("possible Feature Envy"), never a hard violation — and skip anything
  tooling already enforces.

## The bar: when structure earns existence

Structure — a helper, a type, a module — earns its existence one of two ways:

- **Rule of three.** The same logic shape occurs at **3+ real occurrences
  codebase-wide**. Two occurrences stay inline.
- **The deletion test.** Imagine deleting the structure: if complexity
  reappears across N callers, it was earning its keep; if the complexity just
  vanishes, it was a pass-through — delete it.

Two sub-bar exceptions, and only these: the structure isolates a genuinely
tricky branch, or it prevents a subtle bug.

**Counting is codebase-scoped.** A reviewer seeing two occurrences in the diff
checks whether a third exists outside it before flagging an extraction — or a
missed one.

Corollaries of the bar:

- **Small types face the same bar.** A domain-flavored name alone does not
  justify a type; a dataclass that only shuttles fields between two helpers in
  one flow is inlined.
- **Switch cascades** that clear the bar get a **shared dispatch map first;
  polymorphism only when the variant types already exist** with their own
  behavior. Never invent a class hierarchy to kill a switch.
- **No chain rule.** A long `a.b().c().d()` navigation is never a smell per
  se; a *repeated* chain is caught by the duplication bar like any other logic
  shape.

## Module merge and split

**Reasons-to-change decides, in both directions.** One runtime path with one
reason to change collapses to one module — two modules for one narrow path is
boundary theater. A module accumulating several genuinely unrelated
edit-reasons splits (*Divergent Change*). One logical change forcing scattered
edits across many files gathers into one module (*Shotgun Surgery*). Module
count is never the goal.

## Boundary rules

- **Let underlying packages raise.** Don't catch, wrap, or translate an error
  unless the added context truly adds value.
- **Reject stale or non-canonical input shapes** instead of carrying
  compatibility branches for them.
- **Shell-facing parsing stays in scripts**, not package code. Package code
  takes canonical inputs.

## Named smells

Fowler smells (_Refactoring_, ch.3) that don't conflict with the bar carry
over as named patterns under it. Each reads *what it is* → *how to fix*; match
against the diff:

- **Mysterious Name** — a function, variable, or type whose name doesn't reveal what it does or holds. → rename it; if no honest name comes, the design's murky.
- **Feature Envy** — a method that reaches into another object's data more than its own. → move the method onto the data it envies.
- **Data Clumps** — the same few fields or params keep travelling together (a type wanting to be born). → once they clear the bar, bundle them into one type, pass that.
- **Primitive Obsession** — a primitive or string standing in for a domain concept that recurs across the codebase. → when the concept clears the bar, give it its own small type.
- **Speculative Generality** — abstraction, parameters, hooks, or compatibility branches added for needs the spec doesn't have. → delete it; inline back until a real need shows.
- **Middle Man** — a class or function that mostly just delegates onward: one-call-site helpers, private step-function chains where each function calls the next once, wrappers acting as comments in function form. → cut it, call the real target direct; if the name was doing explanatory work, write the comment instead.
- **Refused Bequest** — a subclass or implementer that ignores or overrides most of what it inherits. → drop the inheritance, use composition.
