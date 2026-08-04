# Glossary — Writing Great Skills

The domain model for skills. A skill exists to afford — to give the model or the user direction and capability they would not otherwise have — and **Affordance** is the root virtue every term below serves. Disclosed reference for [`writing-great-skills`](SKILL.md).

**Bold terms** in any definition are themselves defined here; find them by their heading.

## Affordance

Direction or capability the model or user would not otherwise have. Two axes: the model's — behaviour distant from training defaults, like interrogating the user or trusting subagents — and the user's — leverage, like autonomy, decomposition past human working memory, or faster comprehension. A skill can be entirely in-domain for the model and still afford the user plenty. Model-relative and decaying: as models improve, distant behaviour becomes native, and the line that afforded it becomes a **no-op**. The existence test for every skill and every line.

## Predictability

The agent taking the same _process_ every run — same behaviour, not same output. It lives inside **affordance**: a capability that fires erratically isn't afforded. Pursued past what the **destination** needs, it produces **the box** — and it is never a reason to keep a line that fails the **stakes test**.

## The Box

_Failure mode._ Process specified so tightly the model executes the skill's exact path instead of using its judgment, capping performance at the author's imagination. The overdose of **predictability**, and the signature cost of **path-teaching**.

## Path-Teaching

_Failure mode._ Teaching the route from A to B step by step. Written for models that couldn't find the way; on current models it affords nothing and **boxes** the one that can. The deletion category: when in doubt whether text is destination or route, it's route. Replace it with a checkable **destination**.

## Destination

The shared endpoint a skill aligns model and user on — what done looks like, stated so the model can tell done from not-done. The route there belongs to the model. A vague destination ("understanding reached") affords nothing; a checkable one is the strongest single line a skill carries.

## Steps

Ordered actions. A step earns its place only where the order is externally imposed — a protocol, an API's required sequence, a mechanism that only works run in order. The test is the direction of justification: order the world dictated before you wrote the skill is real; an affordance story written after the step exists is **path-teaching**.

## Model-Invoked

A skill that keeps its description visible to the agent, so it can fire autonomously and other skills can reach it; the human can still type its name. Pays permanent **context load** for that discoverability.

## User-Invoked

A skill with `disable-model-invocation: true`: the description is stripped from the agent, so only the human can fire it and no other skill can. Zero context load, paid for in **cognitive load**. Its description is human-facing — one of the few lines graded by what it affords the *user*.

## Context Load & Cognitive Load

The two costs of invocation. Context load: a model-invoked description sits in the window every turn, spending tokens and attention — the brake on splitting off more model-invoked skills. Cognitive load: a user-invoked skill must be remembered by the human — the price of human agency, worth paying where human judgment matters, and the brake on user-invoked proliferation.

## Router Skill

A user-invoked skill that names your other user-invoked skills and when to reach for each — one skill to remember instead of many. It can only hint, never fire them. The cure for piled-up **cognitive load**.

## Context Pointer

A reference held in context that names out-of-context material and encodes when to reach it. The description is the top-level pointer; pointers to disclosed files are the same object one level down. Wording, not target, decides whether the agent gets there — fix a missed pointer by sharpening its wording before inlining the material.

## Progressive Disclosure

Pushing reference out of SKILL.md behind a **context pointer** so the top stays legible. Disclose what only some runs need; inline what every run needs. Wherever material lands, keep a concept's definition, rules, and caveats co-located under one heading.

## Leading Word

A compact concept already in the model's pretraining that the agent thinks with while running the skill (_lesson_, _fog of war_, _tracer bullets_). Repeated as a token, never as a sentence, it anchors a region of behaviour at minimal cost: in the body it anchors execution, in the description invocation — share the word across your prompts, docs, and code and the skill fires more reliably. A coined word recruits no priors; reach for an existing one.

## No-Op

_Failure mode._ A line the model already obeys by default — load spent to change nothing. The line-level **affordance** test: does it change behaviour versus the current model's default? Model-relative, and the default moves: a line that earned its place last year may be a no-op today. Disputes are settled by running the skill, not by debate.

## Subagent Distrust

A named model default: models re-verify subagent findings and wrap dispatch in defensive scaffolding unless steered otherwise. Deleting distrust text does not recalibrate the default — counter-steer actively: write trust-the-coordinator as the resting posture and treat agent findings as trusted input.

## Stakes Test

Whether a guard earns its place: guard only failures that are frequent or hard to recover from. Rare and hand-recoverable earns no guard — every reader pays for the line; the occasional manual fix is cheaper.

## Loosening

The default resolution of an open question: delete the constraining text rather than write the clarifying answer. Ambiguity is an acceptable resting state — the model's judgment fills blanks better than pre-written answers. The dynamic half of pruning: pruning clears what exists, loosening decides what never gets written.

## Historical Contrast

_Failure mode._ A line contrasting the current way with a replaced one — "we do this now, not what we used to do." To a reader who never knew the old way it affords nothing, and it is deadest when the old way isn't a live alternative but mere lineage. Contrast earns its place only when it disambiguates a fork the model might actually take.
