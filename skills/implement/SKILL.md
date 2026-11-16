---
name: implement
description: "Implement a prepared spec or set of tickets. Use when the user asks to implement one, or when an orchestrating skill runs it as its implementation subloop."
---

Implement the work described by the user in the spec or tickets.

Write code and tests against the unified code standard in
[`../codebase-design/STANDARD.md`](../codebase-design/STANDARD.md);
independent review happens outside this session.

Prove every change with evidence you observed in this session: a test seen
failing without the change and passing with it, a reproduction that now
passes, or the running app. Run the full typecheck and test suite before
committing. State in the PR description (or the final report when no PR
exists) how each change was proved.

Do not commit while accepted review findings or failing checks remain.
