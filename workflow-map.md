# Skills workflow map — the two delivery loops

**Color = provenance:** blue = Pocock (unmodified) · purple = Pocock, forked by you · green = yours · amber = the open decision · red = coverage gaps (grill fodder).

```mermaid
flowchart TD
    IDEA(["idea"]) --> GRILL

    subgraph SHAPE["Shaping — one unbroken context window"]
        GRILL["/grilling<br/>(+ /domain-modeling paper trail, opt-in)"]
        SPEC["/to-spec<br/>conversation → spec on tracker"]
        TICKETS["/to-tickets<br/>tracer-bullet slices<br/>SIZES work to one context window"]
        GRILL --> SPEC --> TICKETS
    end

    PROTO["/prototype · /research<br/>detours via /handoff"] -.answers.-> GRILL
    WAY["/wayfinder<br/>fog → decision map"] -->|way clear| SPEC
    TRI["/triage<br/>incoming issues → agent-ready"] --> FORK
    TICKETS --> FORK

    FORK{{"ready ticket<br/>WHICH LOOP?"}}

    subgraph LOOPA["Loop A — Pocock inner loop: CONFORMANCE"]
        IMPL["/implement"] --> TDD["/tdd<br/>red → green at agreed seams"]
        TDD --> CLEAN["/cleanup-abstraction<br/>inline the indirection"]
        CLEAN --> CR["/code-review<br/>Standards + Spec axes<br/>own-model sub-agents"]
        CR --> COMMIT["full checks → commit<br/>(no PR machinery)"]
    end

    subgraph LOOPB["Loop B — your delivery loop: DEFECTS"]
        PP["/pr-ping-pong<br/>worktree · branch · draft PR"] --> NIMPL["native implementer<br/>(persistent session)"]
        NIMPL --> PUSH["verify + push"]
        PUSH --> REV["/codex-agent + /cursor-agent<br/>defect hunt · VERDICT contract"]
        REV --> TRIF["triage findings"]
        TRIF -->|accepted blocking, max 3 rallies| NIMPL
        TRIF -->|clean| MERGE["merge gate"]
    end

    FORK --> IMPL
    FORK --> PP
    COMMIT -. "splice point:<br/>A's review→commit tail<br/>= where B's rally begins" .- PP

    XPR["/cross-provider-review<br/>= one rally of Loop B, standalone"] -.-> REV

    GAPA["GAP: nobody hunts defects"]:::gap -.- LOOPA
    GAPB["GAP: reviewers never see spec or standards<br/>GAP: nothing sizes work if /to-tickets is skipped"]:::gap -.- LOOPB

    DIAG["/diagnosing-bugs"] -->|post-mortem: no good seam| ARCH["/improve-codebase-architecture<br/>survey → deepening candidates"]
    ARCH -->|picked candidate = new idea| GRILL

    classDef pocock fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
    classDef forked fill:#ede9fe,stroke:#8b5cf6,color:#4c1d95
    classDef mine fill:#dcfce7,stroke:#22c55e,color:#14532d
    classDef gap fill:#fee2e2,stroke:#ef4444,color:#7f1d1d
    classDef decision fill:#fef3c7,stroke:#f59e0b,color:#78350f

    class GRILL,SPEC,TICKETS,WAY,TRI,TDD,PROTO,DIAG pocock
    class IMPL,CR,ARCH forked
    class CLEAN,PP,NIMPL,PUSH,REV,TRIF,MERGE,XPR mine
    class FORK decision
    class COMMIT pocock
    class GAPA,GAPB gap
```

Not drawn, running underneath everything: `/codebase-design` + `/domain-modeling` (vocabulary layers) and `/handoff` (session bridge).

## Three things to hold in memory

1. **One of your skills already lives inside his loop** — `/cleanup-abstraction` (green) sits mid-pipeline in Loop A. The merge you're contemplating has already happened once.
2. **The loops review disjoint things** — A checks conformance (standards + spec) with the model that wrote the code; B hunts defects with providers that didn't. Running either alone means the other axis never runs.
3. **The splice point** — A ends where B begins (review → commit ≈ rally start). That seam is where "one loop" would be stitched.

## The decisions the grilling has to settle

1. **One loop or two?** Splice B onto A's tail, keep both routed by work-type, or let B absorb A's review axes?
2. **Where does the conformance axis (spec/standards/smells) live in your delivery path?**
3. **Does `/to-tickets` survive as the sizing step, or does ping-pong learn to size/refuse oversized issues?**
4. **Fate of `/cross-provider-review`** — standalone second opinion, or a single-rally mode of ping-pong?
