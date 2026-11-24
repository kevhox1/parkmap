# PR #173 QA: Spot Pass C4 armed-window auto-detect + polish (2026-11-24)

**Reviewed:** `feat/spot-pass-c4-autodetect` at `829a0ba2` (CI green), vs `origin/main` `4d92f297`.
**Verdict:** **MERGE-WITH-FOLLOWUPS** (no blockers; the Info.plist regression check, the highest risk, is clean)
**Env:** iPhone 17 sim iOS 26.5, Debug builds (generic simulator for the plist diff; device-id simulator for the live run). Build only, no tests run by me. Derived data and worktrees deleted.

## Summary

Turning on `INFOPLIST_PREPROCESS` did not change the built app Info.plist at all in the default build: all 83 `plutil -p` lines are byte-identical to main (URL strings, `$(SUPABASE_*)` expansions, apostrophes and the em dash in usage strings all intact), and the clip and both extension plists are identical too. With `SPOT_PASS_AUTODETECT=YES` the only diff is `UIBackgroundModes[1] = location`. Live with the flag on: purpose sheet, opt-in, armed row, walking route (no depart), driving route (one depart, "You just passed a spot"), Turn off (toast, location use stops, opt-in withdrawn), and a backgrounded drive all behaved to spec. Follow-ups are UX and verification gaps, not defects.

## 1. Info.plist regression (merge-blocking): PASS

`plutil -p WePark.app/Info.plist | sort`, main vs PR, default settings (`SPOT_PASS_AUTODETECT = NO`):

```
$ wc -l m.txt p.txt
      83 m.txt
      83 p.txt
$ diff m.txt p.txt && echo IDENTICAL
IDENTICAL
  "UIBackgroundModes" => [ 0 => "remote-notification" ]
  "SUPABASE_URL" => "https://jiispshyqerscdoferaw.supabase.co"      (both)
  "NSLocationWhenInUseUsageDescription" => "... stays on your device — except ..."   (both, em dash and quotes intact)
```

`WeParkClip.app`, `ClipLiveActivities.appex`, `WeParkLiveActivities.appex` Info.plists: `plutil -p` diff main vs PR = identical (all three).

With `SPOT_PASS_AUTODETECT=YES` on the command line, diff of main vs PR:

```
29a30
>     1 => "location"
```

(only line changed; Debug config only. Release uses the same settings in the pbxproj diff, but I did not build Release; the diff shows both configs got identical lines.)

## Acceptance checklist

- [x] Default Info.plist identical to main; clip/extensions untouched (above)
- [x] `SPOT_PASS_AUTODETECT=YES` adds only `location`
- [x] Flag off: `makeLive(enabled:)` returns nil when `spotHandoffAutoDetectEnabled == false` (`AutoDetectLive.swift:148-150`), so no location object; the flow's `autoDetect` is optional. Not launched flag-off live (I only ran the flag-on build), so "no new permission prompt" is code-verified only.
- [x] Purpose sheet appears from the armed-screen offer row, exact copy, 64 pt-class primary button, "Not now" (`purpose-sheet.png`)
- [x] Opt in: armed row becomes "Auto heads-up is on" with 56 pt Turn off; location arrow appears in the status bar (`armed-autodetect-on.png`). The sim does not render the blue pill for a `CLBackgroundActivitySession` while foregrounded (see "not verified").
- [x] Walking (1.4 m/s, about 150 m of route, well beyond 60 m): NO depart, still armed (screenshot at 110 s)
- [x] Driving (10 m/s): departed within about 12 s, "You just passed a spot." screen with confetti (`after-drive-depart.png`). Location indicator was the plain arrow after (the simulated route itself shows the arrow); pill/arrow gone after `simctl location clear`.
- [x] Turn off: "Auto heads-up is off." toast, arrow leaves the status bar with the simulated location held static, row returns to the offer (opt-in withdrawn) (`turn-off-toast.png`)
- [x] Background: home-screen app, Dynamic Island showing the countdown, ran the 10 m/s route while backgrounded, foregrounded to "You just passed a spot." (`backgrounded-island.png`). Updates continue in background.
- [x] No parked car: armed row reads "Auto heads-up needs your car / Save your car's spot on the map first, then come back." (row variant; I did not open the purpose sheet in that state). Not the exact "disabled primary in the sheet" from the design, see finding 2.
- [x] Privacy (code): `grep` finds no `requestAlwaysAuthorization` and no `allowsBackgroundLocationUpdates` call in any Swift file; no `print`/`NSLog`/`os_log`/`Logger` in `AutoDetect/`; anchor reader is memory-only; `SpotPassAutoDetectC4Tests` (74 tests) includes the cap, expiry, extend and no-coordinate request tests (read, not run).
- [x] Cap/expiry/cancel stops: unit tests exist (`testSixtyMinuteCap_closesOnTheNextFix`, `testPassExpiry_beforeTheCap_endsAsExpired`, `testExtension_movesTheExpiryButNeverPastTheCap`, `testToastOnTurnOff_andCap`); not exercised live (no fake-time hook).

## Findings

### 🟡 Significant

- **#1: Opt-in persists across passes after a depart; the second explicit opt-in is only per Turn off.**
  - Where: live run. After the auto depart, tapping Done and arming a NEW pass showed "Auto heads-up is on" immediately, with no purpose sheet.
  - Expected: spec section 9 describes a second explicit opt-in before the first window; whether it must be repeated per pass is not specified, and the PR text says only Turn off withdraws it. This is consistent with the PR as written but means location starts for every future pass (when within 30 min of leave time) without a fresh prompt.
  - Owner: `@ios-engineer` / product call. Decide and record the intended policy before flipping the flag (App Review reviewers will ask).

- **#2: Two rows both titled "Auto heads-up ..." on the armed screen.**
  - Where: armed screen shows the new C4 row ("Let WePark tell them when you drive off" / "Auto heads-up is on") directly above the pre-existing C2 car-connect row ("Auto heads-up when you start your car"). The new no-car state is also titled "Auto heads-up needs your car", which reads like the row below.
  - Expected: design 5.4 treats auto-detect as one concept; two rows with the same prefix and different mechanisms (location vs car Bluetooth/CarPlay) will confuse. The offer row's title also doesn't use the "auto heads-up" phrase while its on-state does.
  - Owner: `@ios-engineer` + `@designer`.

### 🟢 Minor / nit

- **#3:** On the departed screen the C2 "Auto heads-up when you start your car" row remains as a pill button with no explanation (pre-existing; just noting it sits next to the new feature).
- **#4:** Sim shows the location arrow, not the blue background-activity pill, when foregrounded. The pill only appears when the app is backgrounded or just launched (seen once, blue circle behind the arrow at relaunch). This is simulator behavior, not a finding against the PR; real-device check required.

### 💡 Not verified / out of scope

- **Polish AX5 row and clip install card:** I did not run AX5 or the clip. Not verified live. Armed-screen "Lock-screen countdown is off" copy and the "countdown is there, with a Leaving now button" copy both rendered correctly in the full app, showing both branches of the activity-started rule exist in the full app; the clip install card itself was not exercised. Recommend a follow-up screenshot at AX5 and a clip install-card check before the flag flip.
- **Flag-off live launch and "no new permission prompt":** code-verified only.
- 60-minute cap, expiry, cancel and seeker-ended live; no fake-time hook, covered by unit tests only.
- "No coordinates in any request" verified by code and test reading, not by network trace.
- Device-only (not run, as scoped): real drive test (Kevin), battery, App Review.

## Test-environment gotcha (not a PR defect)

A `CODE_SIGNING_ALLOWED=NO` simulator build has empty entitlements, so the iCloud key-value store is unavailable and a saved car never persists: the app then always shows "Auto heads-up needs your car". `ParkedCarAnchorReader` reads `NSUbiquitousKeyValueStore` directly (`AutoDetectLive.swift:127`), so on a real device with iCloud KV disabled or unavailable, the anchor would likewise be missing and the feature would silently degrade to the "needs your car" row even though the car pin is in memory. Worth confirming the anchor should come from `ParkPinService` (the in-memory source of truth) instead of re-reading the KV store. I filed this as a follow-up under #2's owner.

## What's working

- The plist switch is clean and tested the right way (full-key diff), and the `#ifdef` plus `-traditional` combination did not mangle `//`, `$(VAR)`, apostrophes or the em dash.
- Detection rule behaves as specified live: walking never fires, driving fires exactly once, and backgrounded driving still fires.
- Turn off and withdrawal work end to end, with the exact toast copy.
- Purpose sheet copy matches the design and is roomy (large touch targets).

Evidence screenshots: `docs/qa/assets/pr173/`.
