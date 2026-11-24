# PR #160 QA: Spot Pass C0 scaffold

**Reviewed:** `feat/spot-pass-c0-scaffold` (PR #160) against `docs/specs/qr-spot-handoff.md` Rev 2 (§5, §8, §12 C0, §14)
**Verdict:** MERGE-WITH-FOLLOWUPS

With the flags at their defaults (false) the existing app is unchanged. I built and ran it on the iPhone 17 sim and checked each flow below. The new route stub returns before touching anything. The App Clip builds, installs and launches. Two things could not be verified in the simulator: token parsing in the clip, and the Associated Domains / App Group entitlements. Both are device or portal items for Kevin (findings 1 and 2).

## Checks

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Route stub inert with flags off | PASS | `SpotPassLinkRouter.handle` has `guard enabled, ...` first and returns false. The only caller is `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` in WeParkApp.swift. No new `@State`, sheet, overlay or observer. The `SpotPassLinkInbox` singleton is lazy and only written when the flag is on. |
| 2 | `wepark://invite` / `.onOpenURL` untouched | PASS | The diff does not touch ContentView. The stub uses a different modifier, so it cannot shadow `.onOpenURL`. No other `onContinueUserActivity` exists in the app (grep). |
| 3 | Flags dark | PASS | `spotHandoffEnabled = false` and `spotHandoffAutoDetectEnabled = false`. The second is read by nothing. |
| 4 | Entitlements and plists well-formed | PASS | App: `applinks:getwepark.com` plus App Group `group.com.kevinhoxha.wepark.shared`. Clip: `appclips:getwepark.com`, `on-demand-install-capable`, parent-application-identifiers, same App Group. Both live-activity plists are valid `widgetkit-extension`. App Info.plist only adds `NSSupportsLiveActivities`. |
| 5 | No version bumps, secrets, or hardcoded config | PASS | All new targets use MARKETING_VERSION 1.0, CURRENT_PROJECT_VERSION 26, deployment target 17.0, SWIFT_VERSION 5.0 and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. These match the existing targets. The clip Info.plist uses `$(SUPABASE_URL)` and `$(SUPABASE_ANON_KEY)`. The built Info.plist resolves them from Config.xcconfig. No keys appear in the diff. Config.xcconfig is ignored by version control and was not committed. |
| 6 | `xcodebuild -list` | PASS | Targets: WePark, WeParkTests, WeParkClip, ClipLiveActivities, WeParkLiveActivities. Schemes: WePark, WeParkClip, ClipLiveActivities, WeParkLiveActivities. |
| 7 | CI builds the new targets | PASS (transitive) | ios.yml builds only the `WePark` scheme (`build-for-testing`). The app embeds `AppClips/WeParkClip.app` and `PlugIns/WeParkLiveActivities.appex`, and the clip embeds `ClipLiveActivities.appex`. So all four build in CI. CI is green. |
| 8 | App scheme builds for the sim | PASS | `BUILD SUCCEEDED` with `CODE_SIGNING_ALLOWED=NO`. WePark.app is 65M (Debug). |
| 9 | Live smoke, flags default (iPhone 17 sim) | PASS | Screenshots read. Cold launch shows the map, ASP banner, locate and Park Until buttons, Report pill, help button and search dock. The gear opens Settings (Help, Notifications, Move-Your-Car sections, no Spot Pass UI). Long-press on the map shows "Park here?" and then the "Park my car" sheet. After Park here the car pin and car toolbar button appear. I did not open the More sheet or the goal rail. |
| 10 | Universal link inertness | PASS | `simctl openurl https://getwepark.com/p#t=abcdefghijklmnopqrstuv` opened Safari (on a Start Page, with a WePark back chevron). The sim does not resolve the AASA, so the app was not claimed. The app process stayed alive (same pid). Returning to the app showed the identical "Park my car" sheet, with no crash and no UI change. The flag-on path is covered only by unit tests (`SpotPassScaffoldTests`, run by CI). |
| 11 | Clip build, install, launch | PASS | `WeParkClip` scheme `BUILD SUCCEEDED`. Built `WeParkClip.app` is 872K (Debug, sim, includes the embedded ClipLiveActivities.appex). Installed and launched with `SIMCTL_CHILD__XCAppClipURL=https://getwepark.com/p#t=...`. It showed the "Pass the spot" placeholder with the generic copy ("Looking for a spot? Open WePark and tap Spot Pass."). |
| 12 | Clip parses the token | NOT VERIFIED | The placeholder shows the token-present copy ("Spot Pass is almost ready.") only when `NSUserActivityTypeBrowsingWeb` is delivered. `simctl launch` with the env var did not deliver it. The generic copy appeared, so the activity either did not arrive or did not parse. I could not tell which. The parser itself (`SpotPassLink`) is covered by CI unit tests. A real invocation needs a device (Local Experience in Settings, or a registered App Clip experience). |

## Findings

### Blocking
None.

### Significant
- **#1: Entitlements need portal setup before any device, TestFlight or archive build.**
  - Where: `ios/WePark/WePark/WePark.entitlements`, `ios/WePark/Support/Clip.entitlements`.
  - What: The main app now requires the Associated Domains capability and the App Group `group.com.kevinhoxha.wepark.shared`. The new App IDs (`.Clip`, `.LiveActivities`, `.Clip.LiveActivities`) must also exist. I did not test signing: sim builds ran unsigned, and I did not use provisioning updates, per instructions.
  - Impact: The first device or TestFlight build from this branch will fail to sign until Kevin registers these in the Apple developer portal. This affects the main app, not only the clip.
  - Owner: Kevin (portal), `@ios-engineer` (note it in the PR or runbook).
- **#2: Token parsing in the clip is not verified end to end.** See check 12. Recommend one device test with a Local Experience before C3 builds on it.

### Minor
- **#3: New Swift 6 mode warnings in `SpotPassLinkRouter.swift:37-38`.** The default arguments `enabled: AppConstants.spotHandoffEnabled` and `inbox: .shared` produce "main actor-isolated ... can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode". This is a warning today with SWIFT_VERSION 5.0. It will break if the project moves to Swift 6. Fix by resolving the defaults inside the function body or marking them `nonisolated`.
- **#4: Clip placeholder never renders the token.** This is intentional (the token is deliberately not shown). It means the only token-present signal is one line of copy ("Spot Pass is almost ready."), which makes the check in #2 hard to eyeball.

### Out of scope (logged)
- The Vercel check failure is expected (branch predates web/).
- The Debug app size (65M) and clip size (872K) are not representative. App Clips have a 15 MB thinned-size limit. Measure the Release thinned size when the clip UI lands (C3).

## Cleanup
Config.xcconfig copy removed. App and clip uninstalled from the sim. Sim shut down. Derived data deleted.
