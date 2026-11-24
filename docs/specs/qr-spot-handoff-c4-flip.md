# Spot Pass C4 (armed-window auto-detect): flip-time checklist

Auto-detect is dark in every build today. Two independent switches must both be turned on; either one off means manual-only (Live Activity, reminder, Start Driving, Shortcut all keep working).

| Switch | Where | Default | Effect when on |
|---|---|---|---|
| `SPOT_PASS_AUTODETECT` build setting | `ios/WePark/WePark.xcodeproj/project.pbxproj`, WePark target, Debug and Release (`SPOT_PASS_AUTODETECT = NO;`) | `NO` | `Info.plist` gains `UIBackgroundModes` -> `location` (via `INFOPLIST_PREPROCESS`, `#ifdef SPOT_PASS_AUTODETECT_YES`) |
| `AppConstants.spotHandoffAutoDetectEnabled` | `ios/WePark/WePark/Services/Constants.swift` | `false` | The controller is built and the armed screen shows the auto heads-up row |

## Turn it on

1. Decide App Review exposure (spec section 0 decision 3). Update the location purpose string if needed (`INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` on the WePark target), add reviewer notes and a demo, update the App Privacy answer (spec section 9 item 11).
2. Set `SPOT_PASS_AUTODETECT = YES;` on the WePark target in both configurations (Xcode: target > Build Settings > User-Defined > `SPOT_PASS_AUTODETECT`), or pass `SPOT_PASS_AUTODETECT=YES` on the `xcodebuild archive` command line for a one-off build.
3. Set `spotHandoffAutoDetectEnabled = true`.
4. Verify the built app: `plutil -p WePark.app/Info.plist | grep -A3 UIBackgroundModes` must list `remote-notification` and `location`. With the setting `NO` it must list only `remote-notification`.
5. Device drive tests (spec section 15): walk away, drive away, GPS drift near buildings, garage, force-quit, minimum and current iOS.

Never add `requestAlwaysAuthorization` or an Always key: auto-detect is When In Use plus `CLBackgroundActivitySession` only.

## Behavior if only one switch is on

- Flag on, setting off: `AutoDetectCapability.backgroundModeDeclared` is false, the offer is `.hidden`, nothing starts, no crash (the app never sets `allowsBackgroundLocationUpdates`).
- Setting on, flag off: the plist declares `location` but no code starts location (App Review would still see the mode: keep both off until ready).
