# The Code Standard

Two rules bind everything below:
- **The repo overrides.** A documented repo standard always wins; where it
  endorses something this file would flag, suppress the finding.
- **Always a judgement call.** Every rule here is a labelled heuristic
  ("possible Feature Envy"), never a hard violation — and skip anything
  tooling already enforces.

## **reduce**, reuse, recycle
Focus on locality, drop unecessary abstractions:
- Agreesively cut adapters
- Inline logic. 
- Don't add functions for the sole purpose of logic narration. 

Meaningful adapters should pass:
- **Rule of three.** The same logic shape occurs at 3+ real occurrences
  codebase-wide.
- **The deletion test.** Imagine deleting the structure: if complexity
  reappears across N callers, it was earning its keep; if the complexity just
  vanishes, it was a pass-through — delete it.
- **Module interface** The adapter preserves meaningful independence between modules.  

Edge cases:
- the adapture isolates a genuinely tricky branch
- the adapter prevents a real bug.

## Named smells

Modified Fowler smells (_Refactoring_, ch.3); surface level
issues that point to or easily produce structural problems.
Each reads *what it is* → *how to fix*; match against the diff:

- **Mysterious Name** — a function, variable, or type whose name doesn't reveal what it does or holds. → rename it; if no honest name comes, the design's murky.
- **Duplicated Code** — the same logic shape appears in more than one hunk or file in the change. → extract the shared shape, call it from both.
- **Feature Envy** — a method that reaches into another object's data more than its own. → move the method onto the data it envies.
- **Data Clumps** — the same few fields or params keep travelling together (a type wanting to be born). → bundle them into one type, pass that.
- **Primitive Obsession** — a primitive or string standing in for a domain concept that deserves its own type. → give the concept its own small type.
- **Repeated Switches** — the same `switch`/`if`-cascade on the same type recurs across the change. → replace with polymorphism, or one map both sites share.
- **Shotgun Surgery** — one logical change forces scattered edits across many files in the diff. → gather what changes together into one module.
- **Divergent Change** — one file or module is edited for several unrelated reasons. → split so each module changes for one reason.
- **Speculative Generality** — abstraction, parameters, or hooks added for needs the spec doesn't have. → delete it; inline back until a real need shows.
- **Middle Man** — a class or function that mostly just delegates onward. → cut it, call the real target direct.
- **Refused Bequest** — a subclass or implementer that ignores or overrides most of what it inherits. → drop the inheritance, use composition.
- **Permissive internal interfaces** — extensive checking or reformatting for an interface we control -> simplify to a single expected schema, remove any checks or formatting that allow divergent inputs.

## Boundary rules
- **Let underlying packages raise.** Don't catch, wrap, or translate an error
  unless the added context truly adds value.
- **Reject stale or non-canonical input shapes** instead of carrying
  compatibility branches for them.
- **Shell-facing parsing stay in scripts**, not modules. Package code
  takes canonical inputs.
