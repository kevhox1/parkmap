# FT-15 / TF2-15 Stream B1 (iOS models) QA Pass 1 — 2026-08-11

**Reviewed:** branch `ios/ft15-block-scoped-restrictions-models` at `0cec595f`, against
`docs/ft15-tf215-temporary-block-restrictions-spec.md` §4.3, §5, §7, §9.2, §10, §12 (AC-I1–I4)
**Verdict:** 🟡 ship with caveats — code reads as compile-safe and decode-safe by careful manual
review, but **a Mac `xcodebuild build` + `xcodebuild test` pass is still a required gate before
merge**, not a formality this review replaces. Two non-blocking findings should be resolved
before or shortly after merge (see below). One finding is outside this PR's scope (Stream A) but
is a real blocker for the feature as a whole and should be raised now, before Kevin applies the
migration.

This is a **static/manual review only** — there is no Swift toolchain in this environment. I did
not compile or run anything Swift-related. Everything below is "what a compiler and a careful
human would catch reading this cold," not a substitute for either.

---

## Summary

Stream B1 adds `Segment.blockfaceKey` (pure, additive, direction-agnostic — verified it performs
**zero** street-name normalization, matching the spec's core anti-FT-14 premise) and extends
`CommunityPin` with `startsAt`, `reportGroupId`, `hasEvidencePhoto`, plus widens
`FilmingMeta.permitId` to optional. All three new `CommunityPin` fields decode via
`decodeIfPresent`, so they're safe against today's live `pins_with_author` view, which has none
of these columns. I found no non-exhaustive switches, no `CodingKeys`/`encode`/`init(from:)`
mismatches, no duplicate test-symbol collisions, and no other call site in `ios/` broken by the
`permitId` optionality widening beyond the three the builder already identified — confirmed those
three compile against an existing, working precedent (`ConstructionMeta.permitId`, already
`Optional<String>`, already compared the identical way at `CommunityPinTests.swift:224`).
`project.pbxproj` is untouched and the new test file correctly falls under the existing
`PBXFileSystemSynchronizedRootGroup` for `WeParkTests` (verified at `project.pbxproj:33-37`, no
exception sets exclude anything). `CURRENT_PROJECT_VERSION` is still 15 in all four build configs.
`PinDetailSheet.swift`'s diff is comment-only — confirmed no functional line changed.

Two things need engineering attention: `hasEvidencePhoto` is speculative scope-creep against the
spec's own explicit deferral (§7) with a guessed wire key and a live landmine for the future
PostgREST write path; and (separately, out of this PR's file scope but load-bearing for the
feature) Stream A's migration does not recreate the `pins_with_author` view, so the two real new
`pins` columns this PR exists to consume will not actually appear in that view's output even
after the migration applies — see Finding #3.

---

## Acceptance criteria checklist (AC-I1–AC-I4, §12)

- [x] **AC-I1** — `Segment.blockfaceKey` is direction-agnostic. Verified by reading the
      implementation (`(lo, hi) = fromStreet <= to ? (fromStreet, to) : (to, fromStreet)`) — this
      is a pure function of the two string values, order-independent by construction, and covered
      by `testBlockfaceKey_directionAgnostic_fromToSwapped`. Not run, but the logic is trivially
      correct: for any two strings A, B, swapping which one is passed as `fromStreet`/`to` cannot
      change which one sorts lower, so `(lo, hi)` is identical either way.
- [x] **AC-I2** — differs by side. Verified by reading (`side` is the 4th interpolated component,
      unconditionally included) + `testBlockfaceKey_differsBySide`.
- [x] **AC-I3** — `startsAt` decodes present/null without error, is `Date?`. Verified by reading
      `decodeIfPresent(Date.self, forKey: .startsAt)` + 3 tests covering present / null / key-absent.
- [x] **AC-I4** — no `Calendar.current` in any new/modified file. Verified by direct grep against
      the PR diff for all 4 touched files — zero occurrences (only comments referencing the
      invariant by name).
- **Not literally an AC, but load-bearing for the whole feature — verified independently (see
  §"Claim 1" below):** zero street-name normalization anywhere in `blockfaceKey`. Confirmed via
  grep of the diff for `uppercased|lowercased|trim|normal|alias|replacingOccurrences` — zero hits
  outside doc comments.

All 4 literal ACs for this stream check out by static read. **Not independently verified: whether
this actually compiles and whether the 16 new tests actually pass** — no toolchain here. That
remains a required Mac gate (see Verdict).

---

## Findings

### 🔴 Blocking (scope: Stream A / backend migration — does NOT block this PR's merge)

**#1: `pins_with_author` is never recreated after the new columns are added — `starts_at` and
`report_group_id` will not appear in the view Stream A's own migration adds them to**

- Where: `supabase/02f-block-scoped-restrictions.sql` (Stream A, PR #69) — `alter table
  public.pins add column if not exists starts_at ...` / `report_group_id ...` (lines ~44-45 in
  the version I read on the `feat/backend-block-scoped-restrictions-schema` branch at `40f04315`).
  `supabase/02-pins-schema.sql:274` defines `pins_with_author` as `create or replace view
  public.pins_with_author as select p.*, pr.username as author_username, pr.reputation as
  author_reputation from public.pins p left join ...`.
- What: PostgreSQL expands `SELECT *` inside a view definition into the explicit column list that
  exists **at `CREATE VIEW` time** and stores that expanded list, not a live wildcard. Adding
  columns to the base table via `ALTER TABLE ... ADD COLUMN` afterward does **not** cause them to
  appear in a pre-existing `SELECT *`-based view — the view must be recreated (`CREATE OR REPLACE
  VIEW`) to pick up new columns. I read the full `02f-block-scoped-restrictions.sql` file
  (including its own explicit comment at line ~121: "`pins_with_author` ... is NOT modified
  anywhere in this migration") and confirmed there is no `create or replace view
  public.pins_with_author` statement anywhere in it, in either the original or the "hardened"
  revision (`40f04315`).
- Expected: after Stream A's migration applies, `pins_with_author` rows should include `starts_at`
  and `report_group_id` so Stream B1's new `CommunityPin.startsAt`/`.reportGroupId` fields — and
  downstream, Stream B4's entire consumption path (AC-C1, AC-C3) — actually receive real data.
- Repro (would need a live/staging Supabase project, not available here): apply
  `02f-block-scoped-restrictions.sql`, insert a `pins` row with a non-null `starts_at`, then
  `select starts_at from pins_with_author where id = ...` — expect this to error ("column does not
  exist") or, if the client instead does `select *`, for `starts_at` to simply be absent from the
  returned row shape.
- Impact if unfixed: `CommunityPin.startsAt`/`.reportGroupId` will silently and permanently decode
  as `nil` in production (Stream B1's `decodeIfPresent` degrades gracefully — no crash, which is
  good — but also no signal that anything is wrong). The entire FT-15/TF2-15 feature's read path
  (map marker + `BlockDetailView`/`ParkedCarDetailView` banner) would never surface a single
  block-scoped report to any user, indefinitely, with zero error visible anywhere. This is exactly
  the class of cross-stream gap the FT-14 join-drop investigation and this spec's own §3.4 callout
  ("Without Channel 3, this entire feature would silently insert rows the app never fetches") were
  written to guard against — same failure shape, different layer.
- Owner: `@backend-data` — needs a `create or replace view public.pins_with_author as select
  p.*, ...` (or an explicit column list) added to `02f-block-scoped-restrictions.sql` before Kevin
  applies it. This is exactly the kind of thing the spec's own "Supabase migrations are applied to
  production BY KEVIN, MANUALLY... it goes through QA; Kevin runs it" gate exists to catch — I'm
  flagging it now, before that apply happens, per that gate's purpose.
- **Scope note, explicit:** this is not a defect in PR #70 (this Stream B1 PR) and does not block
  its merge — B1's model code is correct and safe regardless of whether the view is ever fixed.
  It's filed here because I found it while performing the "decode safety against live/future
  `pins_with_author`" check this QA pass was specifically asked to do, and it directly determines
  whether B1's two new fields (and B4's entire consumption feature) will ever do anything in
  production. Recommend this be independently re-confirmed against the actual Supabase project
  (I could not query it from here) before treating it as certain, but the `SELECT *`-view-doesn't-
  auto-update-on-ALTER-TABLE behavior is standard, well-documented PostgreSQL semantics, not a
  guess.

### 🟡 Significant

**#2: `hasEvidencePhoto` contradicts the spec's own explicit phase-1 deferral (§7), has an
unconfirmed wire key, and its unconditional `encode(to:)` is a real landmine for Stream B3's write
path**

- Where: `Models/CommunityPin.swift` — `let hasEvidencePhoto: Bool` (new stored property),
  `CodingKeys.hasEvidencePhoto = "has_evidence_photo"`, decode:
  `try container.decodeIfPresent(Bool.self, forKey: .hasEvidencePhoto) ?? false`, encode:
  `try container.encode(hasEvidencePhoto, forKey: .hasEvidencePhoto)` (unconditional, not
  `encodeIfPresent`).
- What: Spec §7 says, in full: *"If a UI affordance is wanted to show 'Evidence photo attached ✓'
  (a reasonable trust signal), that's a `count(pin_evidence) > 0` boolean computed server-side,
  never the photo bytes — **explicitly flagged as an out-of-scope follow-up, not built in this
  pass**, to keep phase 1 minimal."* That's an unambiguous scope-out. Separately, §10's B1
  work-streams row does list "add `hasEvidencePhoto: Bool`" as in-scope — an internal
  contradiction inside the spec doc itself. The builder read the §10 table as the more current
  instruction and built it, which is a defensible call, but their own PR description (item #2 in
  "Flagging for orchestrator review") acknowledges they are *guessing* the wire key name
  (`has_evidence_photo`) since it "is not defined anywhere in the Stream A schema sketch." I
  independently confirmed against Stream A's actual migration (PR #69,
  `supabase/02f-block-scoped-restrictions.sql`) that `pins_with_author` gains **no**
  evidence-related column at all — the migration's own comment says so explicitly ("`pins_with_author`
  ... is NOT modified anywhere in this migration"). So today, and for the foreseeable future until
  someone builds it, this field can only ever decode as `false`.
- Expected: per the spec text as written, this shouldn't exist in phase 1 at all; OQ-5 ("should
  this boolean be visible in phase 1?") is listed as non-blocking-but-unresolved in §13, with no
  Kevin ruling recorded anywhere (the "Read this first — Kevin's rulings" section at the top of
  the spec only closes OQ-1; OQ-5 is untouched).
- Why this matters beyond "spec says no": the `encode(to:)` unconditionally writes
  `has_evidence_photo: false` for **every** `CommunityPin`, every time it's encoded. Today's
  `insertCrowdPin` write path builds its payload as a hand-written `[String: Any]` dictionary
  (verified at `CommunityPinService.swift:707-719`), not via `JSONEncoder().encode(pin)`, so this
  isn't live-fire yet. But Stream B3 (the next stream, per §10's table, "Write path + evidence
  upload") is explicitly building the insert path for this exact feature. If a future engineer
  reaches for `CommunityPin`'s `Encodable` conformance instead of hand-rolling a dict (a completely
  reasonable instinct — it's right there, it's the "proper" Codable way), PostgREST will reject the
  insert outright: an unknown key in an INSERT payload against a real Postgres table (no
  `has_evidence_photo` column exists) returns a 400 with "column ... does not exist." That's a
  landmine planted now for a stream that hasn't started yet.
- Recommendation: **remove `hasEvidencePhoto` from this PR** until (a) Kevin actually rules on
  OQ-5, and (b) if the answer is yes, land it in the same PR/session as the Stream A column/view
  addition that actually backs it, with a confirmed wire key name — not ahead of that, on a guess.
  This mirrors how OQ-1 was handled (explicit Kevin ruling recorded at the top of the spec before
  engineering proceeded on it). If Kevin wants to keep it now as intentional forward-compat, that's
  a legitimate call too — but it should be an explicit decision, not an artifact of the spec's own
  internal §7-vs-§10 contradiction being resolved by whichever engineer read it first. At minimum,
  if it stays, drop it from `encode(to:)` (make it decode-only) to remove the PostgREST landmine
  without needing a product decision to do so.
- Owner: `@ios-engineer` (removal or decode-only fix), `@tech-lead` (reconcile §7 vs §10 in the
  spec doc so this doesn't reoccur), Kevin (OQ-5 ruling).

### 🟢 Minor / nit

**#3: `typed-pin-schema-spec.md` §4.3 still says `permit_id` is required — not updated to reflect
this PR's widening**

- Where: `docs/typed-pin-schema-spec.md:156` — `| filming | { permit_id: string, ... } |
  permit_id |` (required-fields column).
- What: This PR widens `FilmingMeta.permitId` from `String` to `String?`, well-justified in code
  comments (crowd-authored filming reports genuinely have no permit number) and acknowledged in
  the PR description. But the actual source-of-truth spec doc this struct was originally built
  against still states `permit_id` is required, and this PR doesn't touch that doc. The
  contradiction is acknowledged in-code (`CommunityPin.swift`'s new doc comment on `FilmingMeta`
  explicitly references `docs/typed-pin-schema-spec.md` §4.3 and explains the divergence) — so
  this isn't a *silent* break — but the doc itself is now stale for anyone who reads it without
  also reading the FT-15 spec's amendment.
- Impact: documentation drift only. No behavioral risk.
- Owner: `@ios-engineer` or `@tech-lead` — one-line edit to `typed-pin-schema-spec.md` §4.3's
  filming row: `permit_id` → "none (open-data permit_id or crowd report with no permit)" or
  similar, with a forward pointer to the FT-15 spec.

**#4: `Segment.blockfaceKey`'s doc comment says the key is "uppercase," but nothing in the
implementation enforces that**

- Where: `Models/Segment.swift`, new `blockfaceKey` doc comment: "Direction-agnostic blockface
  identity: `STREET|MIN(FROM,TO)|MAX(FROM,TO)|SIDE`, uppercase."
- What: The implementation reads `street`/`fromStreet`/`to`/`side` verbatim with zero
  transformation — there's no `.uppercased()` call anywhere. The "uppercase" claim is true today
  only because the upstream tile-build pipeline guarantees `Segment.street` etc. are already
  all-caps (documented at the top of `Segment.swift`: "Street name in all-caps"). This is factually
  accurate today and *should* stay that way (the whole point of §4.1 is verbatim, zero-touch
  reads), but the doc comment reads slightly misleadingly as if `blockfaceKey` itself does the
  uppercasing, which it deliberately does not.
- Impact: none functionally; a future reader could be misled into thinking case normalization is
  happening here when it isn't (which is the *correct* behavior, per spec §4.1 — just worth the
  comment being unambiguous about *why* it's uppercase, i.e. "because the tile source is always
  uppercase," not "because this function uppercases it").
- Owner: `@ios-engineer` — one-clause comment tweak, non-blocking.

**#5: No test coverage for `blockfaceKey`'s empty-string or same-string edge cases**

- Where: `WeParkTests/FT15ModelTests.swift`, `SegmentBlockfaceKeyTests`.
- What: The task brief specifically asked me to verify `blockfaceKey` "produces identical keys
  for swapped from/to, including edge cases (equal strings, empty strings, case differences in the
  underlying tile data)." I verified by code-reading that the sort logic (`fromStreet <= to ? ... :
  ...`) is correct and total for all these cases — `fromStreet == to` degenerates harmlessly (both
  branches produce the same pair), empty strings sort deterministically like any other string, and
  case differences would produce *different* keys for what a human considers "the same" street
  name differently-cased (this is expected/correct given the tile-data-is-always-uppercase
  guarantee, and is the direct, honest consequence of the "verbatim, no normalization" design). None
  of these three edge cases has an explicit test, though — the 6 `SegmentBlockfaceKeyTests` cover
  the "normal" swapped-direction and differs-by-side/street/from-to cases well, but not the
  degenerate ones.
- Impact: low — the logic is simple enough that I'm confident in it by inspection, and a real tile
  never has `fromStreet == to` or an empty street name. This is defensive-coverage nice-to-have,
  not a correctness gap.
- Owner: `@ios-engineer`, optional/low-priority — 2-3 more test cases if there's a natural moment
  (e.g. when B2 lands and touches this same test file's neighborhood).

### 💡 Out of scope (logged, not fixed)

- Everything in AC-R1–R9 (B2), AC-C1–C5 (B4), AC-T1 (TF2-15 proof), AC-S1–S8 (Stream A) — not this
  PR's scope, correctly excluded from this PR's own claimed coverage per its description.
- Stream A's `pin_evidence`/rate-limit/hard-ceiling/auto-resolve extension correctness — reviewed
  only the one specific point relevant to Finding #1 (the view), not a full Stream A QA pass (a
  separate QA report for that stream already exists in the working tree as of this review:
  `docs/qa/ft15-a-block-scoped-schema-qa.md`, written by a different, concurrent QA pass — I did
  not read or rely on it, to keep this review independent).

---

## Things I specifically verified per the task brief

1. **`Segment.blockfaceKey` is pure, additive, and direction-agnostic with zero normalization** —
   confirmed. Grepped the diff for any casing/trimming/alias transform: zero hits outside doc
   comments. Confirmed `street`/`fromStreet`/`to`/`side` are all plain `String` on `Segment` (no
   enum-interpolation hazard). Confirmed the sort produces identical `(lo, hi)` regardless of which
   physical direction a given row stores `from`/`to` in, including the equal-string and
   empty-string degenerate cases (by code inspection — see Finding #5 for the test-coverage gap).

2. **Decode safety against today's live `pins_with_author` view** — confirmed safe. All three new
   `CommunityPin` fields use `decodeIfPresent`/`?? false`, never `decode`. A row from today's live
   schema (no `starts_at`/`report_group_id`/`has_evidence_photo` columns at all) decodes without
   error, with all three new fields taking their documented "absent" defaults (`nil`, `nil`,
   `false`). Verified this is exercised by `testDecode_startsAt_keyAbsent_isNil`,
   `testDecode_reportGroupId_keyAbsent_isNil`, `testDecode_hasEvidencePhoto_keyAbsent_defaultsFalse`.
   **Separately** (Finding #1), decode safety against the *future* view (post-Stream-A-migration)
   is a different question, and that one has a real gap — but it's a gap that manifests as
   "field is always nil/false," not a crash, so the CommunityPin decode layer itself remains safe
   either way.

3. **`hasEvidencePhoto`** — my judgment: this should come out, or at minimum be made decode-only.
   See Finding #2 for full reasoning. Not a crash risk, not a compile risk — a scope/product-process
   risk plus a real (if currently dormant) write-path landmine.

4. **`reportGroupId` added beyond the literal B1 field list** — assessed as sound. AC-C1/AC-C3
   (§9.2's own matching predicate: `pin_type in (filming, construction)`, `report_group_id != nil`,
   `segment_id == viewedSegment.blockfaceKey`) genuinely require `CommunityPin` to carry
   `reportGroupId` as a Swift property — `segment_id` matching alone can't distinguish a
   block-scoped grouped report from some hypothetical future non-grouped `filming`/`construction`
   pin. I independently re-checked the spec's §10 table for B2/B3/B4's file lists: none of them
   list `Models/CommunityPin.swift`. So the builder's reasoning — "B1 is the only place this field
   could land without a later stream reopening a file it doesn't otherwise own" — holds up. This
   was flagged in the PR description, not silently added. No finding filed against this.

5. **`permitId` widened to optional** — confirmed sound for the crowd path. Swept all of `ios/`
   for `.permitId` usage: exactly 3 sites, all in `CommunityPinTests.swift`
   (`XCTAssertEqual(m.permitId, "...")`), all using the identical `Optional<String>`-vs-string-
   literal comparison pattern the same file already uses today for `ConstructionMeta.permitId`
   (already `Optional<String>` pre-PR, e.g. line 224 `XCTAssertEqual(m.permitId,
   "DOT-2026-789")`), which is existing, presumably-already-compiling code. This is strong
   evidence (not just an assumption) that the pattern compiles — it's not a novel construct this
   PR introduces, it's the same construct already live elsewhere in the same file. No memberwise
   `CommunityPin(...)` or `FilmingMeta(...)` call sites exist anywhere in `ios/` outside `Codable`
   decode paths (grepped for `CommunityPin(` and `FilmingMeta(` — zero non-decode construction
   sites), so there's no risk of the widened optionality breaking a manual initializer call
   elsewhere. `typed-pin-schema-spec.md` §4.3's "required" claim is contradicted but acknowledged
   in-code (not silently broken) — see Finding #3 for the doc-staleness nit.

6. **`PinDetailSheet.swift` is comment-only** — confirmed. `git diff` shows exactly one hunk,
   entirely within the header comment block; the file's actual reactions-row gate
   (`pin.lifespan == .ephemeral && pin.source == .crowd`, around line 55) is byte-identical to
   before. No behavior changed.

7. **`project.pbxproj` untouched, new test file auto-discovered, build version unchanged** —
   confirmed. `git diff main...0cec595f -- ...pbxproj` is empty. `WeParkTests` is declared as a
   `PBXFileSystemSynchronizedRootGroup` with `path = WeParkTests` (lines 33-37) and no membership
   exception sets exist anywhere in the file (grepped for `ExceptionSet`/`membershipExceptions`:
   zero hits) — so `WeParkTests/FT15ModelTests.swift` sits directly under the synced path exactly
   like every other test file in that directory (`CommunityPinTests.swift`,
   `FT11DirectionTests.swift`, etc.) and will be picked up automatically on the Mac.
   `CURRENT_PROJECT_VERSION = 15` confirmed unchanged in all 4 build configurations (it couldn't
   have changed anyway, since the file is untouched).

---

## Compile-plausibility checks performed (in place of a real compiler)

- No new `PinType` enum case added by this PR — every `switch` over `PinType`/`PinMeta`
  (`PinMeta.decode(pinType:from:)`, `PinMeta.encode(to:)`) remains exhaustive with the pre-existing
  10 cases untouched.
- `CommunityPin.CodingKeys` additions (`startsAt`/`reportGroupId`/`hasEvidencePhoto`) are present
  and correctly wired in all three of: the enum, `init(from:)`, and `encode(to:)`. No mismatch.
- `Segment`'s `CodingKeys` is untouched (the new `blockfaceKey` is a computed property in an
  extension, not a stored/decoded field, so it needs no `CodingKeys` entry — correct).
- No new stored property lacks a default and is also constructed anywhere via a memberwise
  initializer (checked: `CommunityPin`'s only initializer besides the synthesized memberwise one
  is the `Codable` `init(from:)` declared in an extension, which does **not** suppress the
  synthesized memberwise init — but since zero call sites anywhere in `ios/` construct
  `CommunityPin` via memberwise init, outside of `Codable` decode, this is a non-issue in practice,
  not something the compiler would even need to catch).
- `import Foundation` already present in both modified model files; no new import needed (`UUID`,
  `Date`, `Bool` are all already available).
- No access-level changes, no name collisions with existing members.
- Test file: no duplicate top-level type/function names against any other file in `WeParkTests`
  (checked `SegmentBlockfaceKeyTests`, `CommunityPinStartsAtTests`, `CommunityPinReportGroupIdTests`,
  `CommunityPinHasEvidencePhotoTests`, `FilmingMetaCrowdReportTests`,
  `CommunityPinFT15RoundTripTests`, `ft15Decoder`, `ft15PinFixture`, `decodeSegment` — all unique
  or correctly scoped as `private` instance methods on their own class, no collision). `@MainActor`
  usage on the `CommunityPin`-decoding test classes matches the established project convention
  (`CommunityPinTests.swift`), and its absence on `SegmentBlockfaceKeyTests` matches the
  established precedent for `Segment`-only tests (`FT11DirectionTests.swift`'s
  `FT11SegmentDecodeTests`, also no `@MainActor`).

None of this substitutes for an actual build. It's the best a careful read can do.

---

## Smoke tests run

None — no Xcode/Swift toolchain in this environment, no simulator. This is a pure static/manual
code review. No `xcodebuild`, no test run, no live-UI smoke was performed or is claimed. This PR
does not touch `MapViewRepresentable.swift`, `ContentView.swift`, or any `DriveMode*`/
`.safeAreaInset` overlay code, so the mandatory live-UI-smoke gate for mount-chain PRs does not
apply to this specific stream — but the general "Mac compile + test" gate still applies and is
unmet.

---

## What's working

- The core design premise — block identity read verbatim off tile data, zero on-device
  normalization — is faithfully implemented exactly as specced, and this is the single most
  important thing to get right in this stream (it's the whole reason the spec avoids re-solving
  FT-14 on-device). Confirmed clean by direct inspection.
- Decode-safety discipline is consistently applied: every new field uses `decodeIfPresent` (or
  `?? false`), matching the project's established pattern for additive schema evolution (same
  shape as W7's `ParkedCar.notifyOnRestriction` precedent this PR's own comments reference).
- The `reportGroupId` scope addition is well-reasoned and transparently disclosed in the PR
  description rather than silently added — good practice, consistent with the project's
  post-W8.5c-polish spec-fidelity norm.
- `hasEvidencePhoto`'s spec contradiction is also transparently disclosed (not silently
  substituted) — I disagree with the resolution (see Finding #2), but the process of flagging it
  for review rather than guessing silently is exactly right.
- Test coverage is thorough for what's in scope: 16 fixture-based tests cleanly map to the 4
  literal ACs plus reasonable defensive cases (regression test for the pre-existing open-data
  `permit_id` path, a full round-trip test). No network/DB dependency, consistent with B1's stated
  scope.
- `project.pbxproj` discipline (verify-don't-touch) and the honest "COMPILE-UNVERIFIED" framing at
  the top of both the PR description and the test file header are exactly the right posture for
  VPS-authored Swift work — this makes independent verification meaningfully easier.
