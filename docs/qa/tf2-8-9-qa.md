# TF2-8/9 — Zoom Re-apply + Sign-Check Sheet — QA Report

**Reviewed:** `ios/tf2-8-9-fixes` @ `8c47e1a` (+ QA-finding fixes in follow-up commit).
**Verdict:** PASS-WITH-NOTES → findings FIXED in-branch before merge. **Tests: 516/0** after fixes.

## Verified
- TF2-8 state machine: one-shot pending flag, clear-before-apply (no loop), driveModeActive guard,
  exit-clear, Recenter doesn't arm it, 25% idempotence threshold.
- TF2-9: ScrollView checklist, sticky CTA, opaque ZStack+ultraThickMaterial background,
  [.medium,.large] detents, ParkConfirmView untouched, a11y labels present.
- #31 invariant; no setRegion on drive path; only 4 iOS files; no PWA/pbxproj/token.

## Findings → resolved before merge
- **SIGNIFICANT #1 (fixed):** the course-heading setCamera (altitude-neutral) fired
  regionDidChangeAnimated and consumed the flag via the idempotence path BEFORE MapKit's async
  follow-zoom — bounce would survive on moving devices. FIX: flag is only CONSUMED by an actual
  zoom-out correction (deviation >25%); within-tolerance events leave it ARMED. Disarm paths:
  user takeover (tracking → .none), drive exit, 6s timeout backstop, +isUserInteracting guard.
- **MINOR #3 (fixed):** user pan during pending window → .none disarm prevents camera yank.
- **NIT #2 (open, low):** SignCheck onConfirm test simulates rather than invokes the closure.

## Kevin's irreducible gate (build 10)
Drive-mode entry WHILE MOVING ends at the tight zoom (no bounce-out); Park-here sheet renders
with no text overlap.
