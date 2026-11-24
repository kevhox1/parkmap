# PR #174 QA: Spot Pass auto-detect follow-ups to #173

**Reviewed:** `fix/spot-pass-autodetect-followups` (CI green), live on iPhone 17 smoke sim (iOS 26.5), unsigned build (no iCloud KV), flags forced on locally (not committed), `SPOT_PASS_AUTODETECT=YES`, fake API.
**Verdict:** MERGE (no blocking or significant findings; one nit)

## Evidence (screenshots in `docs/qa/assets/pr174/`)

1. **Anchor fix: PASS.** Unsigned sim, no car: row reads "Auto heads-up / Save your car's spot to use auto heads-up." (`00-no-car-row.png`). After saving a car (long-press, Park here) and reopening the armed pass: "Auto heads-up / Send an auto heads-up when you drive off. Uses your location on this phone only while this pass is active." (`01-offer-row-with-car.png`). No "needs your car". The in-memory mirror works where the KV store is unavailable.
2. **Opt-in persistence + carried note: PASS.** Opted in (purpose sheet, Turn on), row became "Auto heads-up is on" with Turn off. Ran `simctl location start --speed=10` route: pass went to "You just passed a spot" (depart fired; the fake API gives no count, so "exactly one" was not independently counted, only that the flow completed once). Done. Relaunched with token `BBBB...`, armed, saved a car, reopened via More > Your Spot Pass: row "Auto heads-up is on" plus note "Auto heads-up is on for this pass. Tap Turn off to stop it." (`02-on-with-carried-note.png`). Turn off pill works: toast "Auto heads-up is off." and row returns to the offer (`04-after-turn-off.png`).
3. **Distinct titles / no "ping": PASS.** Rows read "Auto heads-up..." and "Heads-up when your phone connects to your car". Grep of `Views/SpotPass` and `Services/SpotPass` finds no word "ping" outside comments.
4. **Celebration screen: PASS.** "You just passed a spot." shows karma chip and Done only; no car-connect row (`03-celebration-no-carconnect.png`).
5. **Flag-off regression: PASS.** Rebuilt with main defaults (Constants reverted, no `SPOT_PASS_AUTODETECT`). Launched with the Spot Pass injection args: no pass UI (inert), normal map, no crash. Parked a car: normal Park my car sheet, pin saved, nothing new appeared (`05-flag-off-park.png`).

## Findings

### Minor / nit
- **#1 Carried note can be suppressed on a reopened cover (cosmetic).** `AutoDetectRowBody.offeredHere` latches true on the first `.needsSavedCar/.canEnable/.locationDenied` value. In my run, when the pass was armed with no car (row "Save your car's spot...") and the user then saved a car and reopened the cover, the first reopen showed "is on" WITHOUT the note (stale offer from the earlier no-car state); a second close/reopen showed the note. Edge case (arm with no car, opt-in already on). Not blocking; owner `@ios-engineer`.

### Out of scope / harness note
- The carried-over scenario is awkward to reproduce in the unsigned sim: the car does not survive relaunch (no KV) and the pass link only injects at launch, so the car had to be saved after arming. The real iCloud-signed path (car present at arm time) was not exercised; the note logic reads correct in code, and the fresh-row render confirms it.
- Deviation noted in PR (note says "Tap Turn off to stop it." rather than an inline tappable "Turn off"): acceptable, the 56 pt pill is the control.

## Working well
Offer/on/off transitions, the toast, the 56 pt Turn off pill, distinct titles, clean celebration screen, and a truly inert flag-off path.
