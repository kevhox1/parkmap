# W4 — Block Detail Sheet on Tap

**Status:** All decisions locked 2026-05-10. Spec ready for `@ios-engineer`. **Do NOT start until W3 follow-up fixes PR (`docs/w3-followup-fixes-spec.md`) is merged.**
**Owner:** @ios-engineer (build), Tech Lead (spec).
**Depends on:** W2 (tile loading + polylines), W3 (rules engine + dynamic color), W3 follow-ups (clean test gate + single-`currentState`-per-render).
**Blocks:** W5 (pin drop reuses this tap pathway), TestFlight AC-3 + AC-4 + AC-6 verification.
**Spec reference:** `docs/ios-mvp-spec.md` §2.1 (in-scope: "Tap a block → block detail sheet"), §6 AC-3/4/6; `docs/design/ios-mvp-palette.md` §4 (block visualization), §5 (accessibility).

---

## 1. Why now

W3 landed the rules engine + dynamic state color. The map shows live colored polylines but tapping does nothing. W4 is the first interactive feature, turning the map from a viewer into an app. It also surfaces AC-3 (label parity) end-to-end for the first time — every tap reveals a `safetyLabel(...)` string that must equal the PWA's `actionableSafetyLabel(...)` output character-for-character at the same wall-clock time.

---

## 2. User story

> *I see a green block on Bowery. I tap it. A sheet slides up showing **"Bowery — North side"** at the top, then a large **"Free until Thu 9:30am"**, then the underlying rules ("Mon-Thu 7:00-9:30 AM · ASP cleaning"). I pull the sheet up to see the full rules list, or swipe it down to dismiss. The block I tapped is visibly highlighted on the map underneath the sheet so I know what I tapped.*

---

## 3. In scope

### 3.1 Tap interaction

- **Single tap on a colored polyline** opens the block detail sheet for that segment.
- **Tap mechanism:** invisible wider polyline overlay (`MapPolyline` with `lineWidth: 20, opacity: 0.001`) rendered above each visible polyline, carrying the tap target. Visible polyline stays at its native width (3pt, or 4pt for metered per palette doc §2.3). Engineer's job to confirm this works in iOS 17 MapKit; if `MapPolyline` tap is unreliable, fall back to `MapAnnotation` at the segment midpoint as a button. Make the call after a ~30-minute spike on a real device.
- **Tap target hit area** is the 20pt-wide invisible polyline — comfortably above the 44pt minimum touch target requirement when summed across the polyline's length. (Palette doc §5.3 mentions 44×44 minimum; for a line target, the "width" is what matters and 20pt × line length gives plenty of hit area.)
- **Long-press is a no-op in W4.** That gesture is reserved for W5's pin-drop entry. Don't wire it now.
- **Tap on empty map** (no polyline within hit area) dismisses any open sheet. (AC-14.)

### 3.2 Sheet style

Use SwiftUI `.sheet(item:)` binding tied to the selected segment, with:
- `.presentationDetents([.medium, .large])` — default `.medium`, user can pull up to `.large` to see full rules list
- `.presentationDragIndicator(.visible)` — Apple's grab handle
- `.presentationBackground(.regularMaterial)` — system blur for native iOS feel
- `.presentationCornerRadius(20)` (iOS 16.4+)

Dismiss paths:
- Swipe-down (default sheet gesture, always available)
- Tap outside the sheet on the map (`.onTapGesture` on a transparent backing view in the sheet's behind-area, OR set sheet's `.interactiveDismissDisabled(false)` which is the default)
- Explicit `✕` close button in the sheet's top-right corner (44×44pt tap target, `Image(systemName: "xmark.circle.fill")` style)

### 3.3 Sheet content

In order from top to bottom:

1. **Severity color band** — full-width strip, 6pt tall, color = `engine.currentStateColor(for: segment, at: .now)`. Pinned to the top edge of the sheet content (under the system grab handle).

2. **Block header** (one line)
   - Display string: `"<StreetName> — <SideLabel>"`
   - `<StreetName>` = `StreetNameNormalizer.canonical(segment.street)`
   - `<SideLabel>` = sentence-cased side from `segment.side` (`"N"` → `"North side"`, etc.). Tiny helper inside the view; not engine-domain.
   - Font: `.title2.bold()`, `.foregroundStyle(.primary)`
   - Below it on a smaller line (`.subheadline`, `.secondary`): `"between <from> and <to>"` from `segment.fromStreet` and `segment.toStreet`, both passed through `StreetNameNormalizer.canonical`.

3. **Primary safety label** — `engine.safetyLabel(for: segment, at: .now).text`. **This is the AC-3 contract** — character-for-character match with PWA `actionableSafetyLabel(...)`.
   - Font: `.title.bold()` minimum, Dynamic Type enabled
   - Color: `.foregroundStyle(.primary)` — color is conveyed by the band above, not the label itself
   - This must be the **first focusable accessibility element** in the sheet (palette doc §5.1 point 2).

4. **Rules list** (scrollable when sheet is `.medium`, all visible when `.large`)
   - One row per rule in `segment.rules`, ordered by **`Category` priority** (most-restrictive first — reuse the existing `Category.priority` from W2).
   - Each row is a single-line layout:
     - Left: rule.description text in `.body`, ellipsis on overflow
     - Right: small `Category` label badge using `.font(.caption).bold().padding(.horizontal, 8).padding(.vertical, 4).background(category-color.opacity(0.18), in: Capsule()).foregroundStyle(category-color)`
   - If `rule.description` is nil/empty, fall back to a generated string: `"<days> <timeRange> · <category-label>"` (e.g., `"Mon-Thu 7:00-9:30 AM · ASP cleaning"`).
   - Days: convert `[Int]` → compact range string (e.g., `[1,2,3,4]` → `"Mon-Thu"`, `[2,5]` → `"Tue,Fri"`). New small helper in the view file.
   - Time range: format start+end via the same formatter used by `nextRestrictionTimeLabel` — lowercase am/pm, no space, omit `:00`. Same parity rules as the existing engine code.
   - `anytime: true` rules show as the row's only text: `"Anytime · <category-label>"`.

5. **"Park here →" stub button** (palette §5.3 touch-target compliant: 44pt min height)
   - Disabled state: greyed out, `.foregroundStyle(.secondary)`, `.disabled(true)`
   - Caption below it (`.caption2`, `.secondary`): `"Coming next"`
   - This lays out the eventual W5 entry point without wiring any action. Tap = nothing.

### 3.4 Selected-block highlight

When a block is selected:
- That segment's visible polyline snaps to `lineWidth: 6` and `opacity: 1.0`
- All other polylines stay at their normal width and opacity
- Reverts on sheet dismiss (any path: swipe, ✕, tap-outside)

Implementation suggestion: keep a `@State var selectedSegmentID: Segment.ID?` in `ContentView`; the polyline `.stroke(...)`'s `lineWidth` is a ternary on `segment.id == selectedSegmentID`. No re-rendering of all 40k segments needed — only the SwiftUI diff affects the highlighted segment's line.

### 3.5 Accessibility (palette doc §5.1 implementation)

This addresses W3 QA #8, which was correctly deferred to W4.

- Each invisible tap-target polyline gets:
  - `.accessibilityLabel("Parking on \(canonicalStreet), \(sideLabel). \(safetyLabelText). Tap for details.")`
  - `.accessibilityHint("Opens the block details sheet.")`
- Sheet's **safety label is the first focusable element** (just below the color band, which is decorative — mark color band `.accessibilityHidden(true)`)
- Sheet's `✕` close button: `.accessibilityLabel("Close block details")`
- "Park here →" stub: `.accessibilityLabel("Park here. Coming in next update.")` and `.accessibilityHint("Disabled.")`
- Each rule row: combine to one accessibility element with combined text (`.accessibilityElement(children: .combine)`) so VoiceOver reads each row as one announcement, not three separate ones.

### 3.6 R1 stress test (carry-over from W2 QA #6 + W3 QA #10)

**Required before merge.** Run on a real iPhone (not just simulator):

| Test | Pass criterion |
|---|---|
| Pan across Manhattan at zoom 14, all visible polylines + their invisible tap-overlays rendered | ≥30fps sustained, ≥45fps target |
| Tap on a polyline → sheet appears | ≤200ms from tap to sheet visible |
| Selected-block highlight visible | No jank when highlighting; no visible re-render flash |
| Pan with sheet open | Sheet stays put (system behavior); map underneath pans smoothly |
| Tap rapidly between 5 different blocks | No stuck-on-screen sheet; correct content each time |

If frame rate drops below 30fps under the full tap-overlay-doubled polyline count: escalate per `docs/design/ios-mvp-palette.md` §4.2 — zoom-threshold gating first (e.g., hide tap overlays below zoom 13), then opacity wash, then block-center dots. **Document measured FPS in the QA pass.**

---

## 4. Out of scope (DO NOT BUILD)

- **Park-here action / `ParkPinService` / `ParkedCar` model** — W5.
- **Notification rationale sheet / scheduling** — W6.
- **ASP banner** — W7.
- **Settings sheet, mute toggle** — W7.
- **Anything Drive Mode** — out of MVP per `docs/ios-mvp-spec.md` §2.2.
- **Address search** — out of MVP.
- **Long-press for pin drop** — W5.
- **Map zoom-to-block on selection** — defer; the user is already centered on what they tapped.
- **Live PWA-captured parity tests** — separate PR per `docs/ios-mvp-spec.md` HANDOFF carry-over.

---

## 5. Acceptance criteria

- [ ] **AC-W4.1** Tap a colored polyline → sheet appears within 200ms with correct block header, safety label, and rules list.
- [ ] **AC-W4.2** Sheet defaults to `.medium` detent; can be pulled to `.large` to reveal full rules list when many rules; swipe-down dismisses.
- [ ] **AC-W4.3** Selected block's polyline visibly highlights (`lineWidth: 6`); revert on dismiss (all paths).
- [ ] **AC-W4.4** Safety label text matches PWA's `actionableSafetyLabel(...)` character-for-character for at least 10 sample segments at a fixed wall-clock time. Sample includes: bare FREE, ASP_MON_THU free now, ASP_MON_THU active now, ASP_DAILY active now, METERED paid-now, METERED free-now, NO_STANDING, NO_PARKING active-now, block with tomorrow's restriction, block whose next restriction crosses a suspended date.
- [ ] **AC-W4.5** "Park here →" stub button visible, disabled, with "Coming next" caption.
- [ ] **AC-W4.6** ✕ close button in sheet works.
- [ ] **AC-W4.7** Tapping outside any polyline (on empty map area) with a sheet open dismisses the sheet. Tapping outside with no sheet open is a no-op. (AC-14 from main spec.)
- [ ] **AC-W4.8** VoiceOver reads the tap target's accessibility label correctly. Sheet's first focusable element is the safety label.
- [ ] **AC-W4.9** R1 stress test passes per §3.6 — measured FPS attached to QA report.
- [ ] **AC-W4.10** No regressions to W3 test suite — `xcodebuild test` reports **43 passed, 0 failed**.

---

## 6. PR conventions

- Branch: `ios/w4-block-detail`
- Title: `feat(ios): W4 — block detail sheet on tap (#NN)`
- Squash-merged via `gh pr merge --squash --delete-branch`
- Open follow-ups documented in PR description per `.claude/TEAM.md` hand-off discipline.
- `@qa-verifier` files `docs/qa/w4-pass-1-2026-05-10.md` (or accurate date).

### QA pass requirements

The QA agent must verify, beyond AC-W4.1 through AC-W4.10:

- No `Calendar.current` use anywhere added
- No new `import SwiftUI` in `Models/` or pure-service files (`ParkingRulesEngine`, `ASPSuspensionService`, etc.)
- `selectedSegmentID` state correctly clears on **every** dismiss path
- No memory leak from sheet state retaining segment data after dismiss
- AC-W4.4 character-for-character parity is independently verified by the QA agent against the live PWA — at least 5 of the 10 sample blocks should be re-checked from raw tile data through both engines

---

## 7. Sizing

Estimated 1-2 sessions of `@ios-engineer` work. Risk surface:
- (a) MapPolyline tap mechanics in iOS 17 MapKit (engineer's 30-min spike resolves this)
- (b) Selected-block state without expensive per-segment re-render (the `@State` + ternary approach should avoid this; QA verifies)
- (c) R1 stress test on real device (carry-over risk; could trigger escalation to zoom-threshold gating)

---

## 8. Open question for Kevin (non-blocking)

Sheet's `"Park here →"` stub button: I'm assuming this button lives in the W4 PR and is wired to nothing yet. If you'd rather not show a button at all until W5 actually delivers the action, that's also fine — say the word and I'll strike §3.3.5 from this spec before dispatch.

Default: stub button stays.
