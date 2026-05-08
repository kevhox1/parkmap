# WePark — Agent Team

This is the operating manual for the WePark agent team. Read this BEFORE invoking any specialized agent so you understand who does what, who runs in parallel, and who hands off to whom.

The actual agent definitions live in `.claude/agents/*.md`. This document is the human-readable team chart and lifecycle reference.

## The team

| Role | Agent file | Owns | Read-only? |
|---|---|---|---|
| **Tech Lead / Planner** | `tech-lead.md` | Specs at `docs/<feature>.md`, architecture decisions, work-stream breakdown | Read-only on production code |
| **iOS Engineer** | `ios-engineer.md` | All Swift / SwiftUI under `ios/` | Writes iOS code |
| **PWA Maintainer** | `pwa-maintainer.md` | `index.html`, `sw.js`, `manifest.json`, `tracker-config.js` | Writes PWA code |
| **Backend / Data** | `backend-data.md` | Supabase schema + RPCs, `tiles/`, `scripts/build-*.js`, NYC source ingestion | Writes backend + data code |
| **Designer** | `designer.md` | Design reviews at `docs/design/` | **Read-only on source.** Files feedback. |
| **QA / Verifier** | `qa-verifier.md` | QA reports at `docs/qa/` | **Read-only on source.** Files findings. |

The seventh role is **Kevin (you)** — Product / CEO. Decides *what* to build and *whether shipped work is good enough*. Doesn't read Swift line-by-line; that's QA.

## Lifecycle of a feature

```
        [Kevin: "I want X"]
                │
                ▼
        ┌──────────────┐
        │  tech-lead   │  ← writes docs/<feature>.md
        └──────────────┘
                │
                ▼
        [Kevin: approves spec]
                │
        ┌───────┴─────────┐
        │                 │  ◄─ parallel work streams
        ▼                 ▼
┌──────────────┐  ┌──────────────┐
│ ios-engineer │  │ backend-data │  (or pwa-maintainer)
└──────────────┘  └──────────────┘
        │                 │
        └───────┬─────────┘
                ▼
        ┌──────────────┐
        │   designer   │  ← reads UI, files docs/design/<feature>-review.md
        └──────────────┘
                │
                ▼
        [Engineers fix design findings]
                │
                ▼
        ┌──────────────┐
        │ qa-verifier  │  ← reads diff cold, files docs/qa/<feature>-pass-1.md
        └──────────────┘
                │
                ▼
        [Engineers fix QA findings, possibly multiple passes]
                │
                ▼
        [Kevin: pokes at it on phone, ships or pushes back]
                │
                ▼
        [Squash-merge PR to main]
```

## Parallelization rules

- **Work streams in a single feature run in parallel** when independent. If `@tech-lead`'s spec carves a feature into "iOS UI work" and "Supabase RPC work" and they don't depend on each other, invoke `@ios-engineer` and `@backend-data` in the **same message** with multiple Agent tool calls. They'll work concurrently.
- **Different features run in parallel.** Kevin can have iOS Engineer working on Drive Mode port while Backend is applying the tracker schema migration. They're touching disjoint files.
- **What does NOT run in parallel**:
  - Two agents touching the same files (e.g., two iOS Engineer invocations on the same Swift module).
  - QA on a feature whose engineering work isn't done yet.
  - Designer review on UI that hasn't been built yet.
- **The QA invariant**: the QA agent run is a fresh agent, not a continuation of the engineering agent's session. This is the whole point of independent verification.

## When to invoke each agent

### Use `@tech-lead` when
- Starting any feature whose scope isn't obvious (>1 file, >1 codebase, or any user-facing UI).
- A bug fix turns out to be architectural.
- Two work streams might collide and you need the seams designed.

### Use `@ios-engineer` when
- Implementing iOS code per a spec.
- Porting JS logic from `index.html` to Swift.
- Fixing iOS-specific bugs.

### Use `@pwa-maintainer` when
- The live PWA has a bug.
- ASP calendar refresh is due.
- Small UX tweak that's clearly maintenance, not a new feature.

### Use `@backend-data` when
- Supabase schema or RPC changes.
- Tile pipeline runs or refreshes.
- New external data source (NYC 311, etc.).
- Anything cross-cutting that both apps depend on.

### Use `@designer` when
- iOS UI has a working first pass and needs critique before ship.
- New PWA UI that's user-facing.
- Kevin asks "does this feel right?"

### Use `@qa-verifier` when
- An engineering agent says "done" — before merge.
- Before uploading any TestFlight build.
- Before applying any Supabase schema migration to production.

### Direct work (no agent) when
- Editing `HANDOFF.md`, `PROJECT.md`, `PRODUCT.md`, or this `TEAM.md`.
- Trivial typo fixes.
- A conversation where Kevin is thinking aloud and just wants a discussion.

## Anti-patterns to avoid

- **The same agent that built a feature signs off on it.** No. QA is independent.
- **Tech Lead writes code.** No. Tech Lead writes specs and hands off.
- **PWA Maintainer ships big new features.** No. PWA is in maintenance mode; new features go to iOS.
- **Designer modifies code.** No. Designer files feedback; engineers act on it.
- **All six agents invoked for a one-line typo fix.** No. Match the agent fleet to the work size.
- **Pushing to `main` directly.** No, except for SW cache bumps and HANDOFF/PROJECT updates per the existing convention in `HANDOFF.md`.

## Hand-off discipline

When one agent's work creates work for another, the producing agent files an explicit follow-up in their PR description:

> **Follow-ups:**
> - `@ios-engineer`: update Swift Supabase calls for new `tracker_*` RPC signatures (see `SUPABASE_MVP_SCHEMA.md` diff).
> - `@pwa-maintainer`: bump SW cache to `wepark-v31` if this lands before next PWA touch.

This way no work falls between agents.

## Living document

This file evolves. If a workflow keeps breaking, update the rules. If a new role emerges (e.g., a release/ops agent once TestFlight ceremony recurs weekly), add it. Don't let the team chart freeze and become decorative.
