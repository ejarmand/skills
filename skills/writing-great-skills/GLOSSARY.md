# Glossary — Writing Great Skills

The domain model for skills; **Affordance** is the root virtue every term below serves. Disclosed reference for [`writing-great-skills`](SKILL.md).

**Bold terms** in any definition are themselves defined here; find them by their heading.

## Affordance

Direction or capability the model or user would not otherwise have. Two axes: the model's — behaviour distant from training defaults, like interrogating the user or reaching models beyond the native harness — and the user's — leverage, like autonomy, decomposition past human working memory, or faster comprehension. Model-relative and decaying: as models improve, distant behaviour becomes native, and the line that afforded it becomes a **no-op**.

## Predictability

The agent taking the same _process_ every run, not producing the same output. Pursued past what the **destination** needs, it produces **the box**, and it is never a reason to keep a line that fails the **stakes test**.

## The Box

_Failure mode._ Process specified so tightly the model executes the skill's exact path instead of using its judgment, capping performance at the author's imagination.

## Path-Teaching

_Failure mode._ Teaching the route from A to B step by step. The deletion category: when in doubt whether text is destination or route, it's route. Replace it with a **destination**.

## Destination

The endpoint a skill aligns model and user on, stated so the model can tell done from not-done. A vague destination ("understanding reached") affords nothing; a checkable one is the strongest line a skill carries.

## Steps

Ordered actions. A step earns its place only where the order is externally imposed — a protocol, an API's required sequence, a mechanism that only works run in order. The test is the direction of justification: order the world dictated before you wrote the skill is real; an affordance story written after the step exists is **path-teaching**.

## Model-Invoked

The description stays visible to the agent; the human can still type its name — model-invocation always includes user reach.

## User-Invoked

Reachable only by the human typing its name; no other skill can fire it. Its description is one of the few lines graded by what it affords the *user*.

## Context Load & Cognitive Load

The brakes on granularity: every new model-invoked skill spends context load (another description in the window every turn); every new user-invoked skill spends cognitive load (another thing the human must remember). Cognitive load is the price of human agency — worth paying where human judgment matters.

## Router Skill

A user-invoked skill naming your other user-invoked skills and when to reach for each. It can only hint, never fire them: they have no descriptions to fire.

## Context Pointer

A reference held in context naming out-of-context material and when to reach it. The description is the top-level pointer; pointers to disclosed files are the same object one level down. Fix a missed pointer by sharpening its wording before inlining the material.

## Leading Word
A highly valuable inclusion to any skill. A compact concept already in the model's pretraining that effectively anchors behavior in shared concepts (_lesson_, _fog of war_, _affordance_). Highly valuable inclusion to any skill.

## No-Op

_Failure mode._ A line the model already obeys by default. The line-level **affordance** test: does it change behaviour versus the current model's default? Disputes are settled by running the skill, not by debate.

## Stakes Test

Whether a guard earns its place: guard only failures that are frequent or hard to recover from. Rare and hand-recoverable earns no guard — every reader pays for the line.

## Loosening

The default resolution of an open question: delete the constraining text rather than write the clarifying answer. Ambiguity is an acceptable resting state — the model's judgment fills blanks better than pre-written answers.

## Historical Contrast

_Failure mode._ Contrasting the current way with a replaced one. To a reader who never knew the old way it affords nothing — deadest when the old way isn't a live alternative but mere lineage.
