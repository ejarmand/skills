---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
---

Implement the work described by the user in the spec or tickets.

Capture the fixed point for the eventual review before editing. Then follow this
sequence:

1. Use `/tdd` at pre-agreed seams, working in red → green slices.
2. Once the requested behavior is green, invoke `/cleanup-abstraction` on the
   resulting diff. Apply its simplifications before review.
3. Run focused typechecking and tests for the touched behavior.
4. Invoke `/code-review` against the captured fixed point. Review reports;
   address its Standards and Spec findings in this implementation session.
5. Run the full typecheck and test suite once at the end.
6. Commit the verified work to the current branch.

Do not commit while accepted review findings or failing checks remain.
