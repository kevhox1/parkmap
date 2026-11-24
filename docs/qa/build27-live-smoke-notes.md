# Build 27 live smoke: running notes (Kevin + Colleen, 2026-11-24)

Rule: Kevin reviews first. Nothing below gets fixed until he says "live smoke complete. You may proceed".

| # | Finding (Kevin's words, condensed) | Where | Status / notes |
|---|---|---|---|
| 1 | "Zoom in and out is incredibly laggy" | iOS map | QUEUED. Read-only triage: nothing new per camera tick in browse; top suspect = curb-pin placement session re-rendering per snap flip (15 m acquire radius in 27). Need: where it lags (browse / placing pin / drive), and whether build 26 lags too. Instruments trace if unclear. |
| 2 | Scanning the QR without the app sent Colleen to the real App Store | web /p | DONE (#176): "Get WePark" goes to the TestFlight public link (external group, build 25, no Spot Pass); Safari smart banner commented out. Restore both at App Store launch. |
| 3 | Wants the "Leaving now" reminder persistent on the lock screen even without the app | clip / web | EXPLAINED: Colleen was on the web page (she isn't on build 27 yet), and a web page can't use the lock screen. The App Clip does it (Live Activity, 8 h), but a camera scan only opens the clip for an App Store–approved version. In TestFlight the clip opens only from the TestFlight app's "Spot Pass" invocation. Re-test on build 27. |
| 4 | Leave time needs a "pick a clock time" option ("I'm leaving at 4 pm"), simple and straightforward, not just 30 min / 1 hour | web /p AND app/clip | QUEUED. Web /p has only Now / ~10 min / ~30 min / ~1 hour, with NO time option. App/clip already has a 5th "Pick a time" chip (`LeaveChoice.custom`); verify on device that it's obvious and easy, and consider making clock-time selection more prominent. Constraint: server horizon is 4 h (`HANDOFF_MAX_HORIZON_MIN=240`), rounded to 5 min, so the picker must show times from now to now+4 h (e.g. a list of times like 3:45, 4:00, 4:15 … or a wheel limited to that window). |
