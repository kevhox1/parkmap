# Regulars S7 QA Pass 1 — 2026-09-21

**Reviewed:** branch `ios/regulars-s7-invites` at `6e5b0a16` (+ doc commit `06d5f29a`), base `17c46e17`, against `docs/regulars-network-spec.md` (through amendment 2026-09-21b) + `docs/regulars-roadmap.md` row S7.
**Verdict: MERGE-PENDING-MAC-GATE.** Static/adversarial review found zero blocking issues. Code-only review — no Xcode/Swift toolchain in the QA environment; the suite has never actually executed. See the Mac gate checklist below.

## Summary

S7 wires the invite/settings UI on top of S5's model layer. Dark-ship integrity is correctly implemented and traced to the live call sites (not just guard tests): the Settings row is gated by `AppConstants.regularsSettingsRowVisible()` inside `SettingsView`'s actual `if`, and `.onOpenURL` calls `RegularsInviteLink.resolveRedemptionToken(from:)`, whose default parameter is the real flag — with the flag `false`, a tapped `wepark://invite/...` link is a provable no-op. URL parsing is strict and adversarially sound. Wire discipline on the four new service methods matches `07-regulars-schema.sql`'s actual column grants, including `cancelInvite`'s `revoked_at` write (client-writable by grant; only ever consumed as an `IS NULL` check — functionally inert, not an S1-class exploit). The one real gap: "New invite" (regenerate) does not revoke the previous invite, silently leaving two live tokens.

## Findings

### 🔴 Blocking
None found.

### 🟡 Significant
- **#1: "New invite" (regenerate) orphans the previous invite instead of revoking it.** `RegularInviteView.createInvite()` (the "New invite" button) creates a replacement without first calling `cancelInvite(id:)` on the one being replaced. The old token remains fully valid until natural expiry — anyone who saw/screenshotted the old QR can still redeem it, silently, for the rest of its 10-minute window. Contradicts the "single-use invite token" framing at the UX layer. Fix: revoke-before-recreate, or relabel to make non-invalidation explicit. Owner: @ios-engineer.

### 🟢 Minor / nit
- **#2:** `RegularsInviteLink.parse` untested trailing-slash variant (`wepark://invite/<uuid>/` likely parses despite "EXACTLY" framing) — add a test locking the behavior either way.
- **#3:** Invite countdown is device-clock cosmetic vs server enforcement — worth a one-line doc note.
- **#4:** Catch-all error copy imprecise for the not-yet-authenticated case.
- **#5:** Double-deep-link edge: second invite URL while a redemption sheet is open updates the token without resetting sheet @State — stale-phase risk in a rare scenario.
- **#6:** `fetchInvite(id:)` lacks a dedicated wire-level test, unlike its three siblings.

### 💡 Out of scope (verified correctly absent)
Street-label push copy (S9), pin_notes/Scheduled Departure/head-start chip UI (S9/S10/S10b), two-device live QR redemption (S8's gate, post-07-apply).

## Verified clean
Dark-ship gates traced to literal call sites; parse rejects all adversarial variants tried; column grants respected on all four new writes; 3s polling cancelled `onDisappear`; test count 1407→1440 exact; zero community-surface changes; Info.plist valid (plistlib-parsed); `PBXFileSystemSynchronizedRootGroup` rules out unregistered-file compile failures; no banned copy; no supabase/ changes; CoreImage-only QR; docs consistent.

## Mac gate checklist (Kevin)
Context: 07/08/09 are DRAFT, unapplied. Flag-on invite creation therefore shows the honest error state ("Couldn't create an invite") instead of a QR — itself a valid smoke result. To see the full QR/redemption flow live, 07 must be applied first (07 alone is QA-clean; 08/09 stay held) — or defer that half to S8's gate.
1. Pull branch; suite run — expect **1440/1440** (first-ever compile of this branch).
2. Flag-OFF smoke: Settings has NO Regulars row; `xcrun simctl openurl <UDID> "wepark://invite/12345678-1234-1234-1234-1234567890ab"` is a total no-op (no sheet, no crash).
3. Flag ON (sed flip, uncommitted): Settings → Regulars row → Add a Regular (QR or honest error per 07 state); `simctl openurl` with a random UUID drives the redemption sheet: generic confirm copy (ruled, amendment 2026-09-21b) → "This invite isn't available anymore" (or transport-error state if 07 unapplied).
4. Revert flag (`git checkout -- ios/WePark/WePark/Services/Constants.swift`).
Full two-account end-to-end redemption = S8's gate, post-07-apply, pre-flag-flip.
