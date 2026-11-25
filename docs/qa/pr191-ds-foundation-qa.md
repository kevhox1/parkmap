# PR #191 Design-System Foundation QA Pass 1 — 2026-11-25

**Reviewed:** branch `feat/design-system-v01-foundation` at `073e36ed`, against `docs/design/wepark-design-system-v0.1/` (DECISIONS, README, tokens) and `docs/design/wepark-round2/README.md`
**Verdict:** 🟡 ship with caveats (MERGE; no blockers, 2 significant follow-ups)

## Summary
With `designSystemV2Enabled == false` every non-DesignSystem hunk is a flag-gated no-op, and the live app on the simulator is visually identical to `main` (dark map, search sheet, gear/Settings). The only intended flag-off differences are the new app icon (all builds) and a DEBUG-only "Developer > Design system v0.1" row. All 4 targets build and WeParkTests is 2943/0. Token values match the CSS. A few part-level fidelity issues (stamp truncation, karma wrap) show up in the gallery renders.

## Acceptance checklist
- [x] Flag default false (`AppConstants.designSystemV2Enabled = false`); guard test passes.
- [x] Flag OFF = no behavior change, by code review of every hunk and by live sim comparison (below).
- [x] 4 targets build (WePark, WeParkClip, ClipLiveActivities, WeParkLiveActivities): BUILD SUCCEEDED each.
- [x] WeParkTests: 2943 passed, 0 failed, 0 skipped (xcresult). All 17 DesignSystemV01Tests cases passed. The builder said 2942; the extra one is the snapshot test.
- [x] Fonts: 4 Fredoka TTFs are present in WePark.app, WeParkClip.app and both appex bundles. UIAppFonts was added to all 4 plists. The new Resources phases in pbxproj are empty. The fonts arrive through the Shared folder, and the built products prove they are bundled.
- [x] Tokens match the CSS (below).
- [x] No-data/unsure never draws solid green; unknown never maps to park (below).
- [x] App icon is opaque, with three variants wired (below).
- [ ] Part fidelity: stamp and karma sticker fail in the gallery (findings 1, 2).

## Flag-OFF diff review
- `WeParkApp`: `.preferredColorScheme(DesignSystemAppearance.preferredColorScheme())` returns `.dark` when disabled. Same as before.
- `ContentView`: `DesignSystemAppearance.apply(...)` has `guard enabled` and does nothing when off. The new `curbLineDetailMode:` argument is inert off. It is declared last, so existing call order is unchanged.
- `MapViewRepresentable`: every new branch is `if AppConstants.designSystemV2Enabled && ...`. `detailModeChanged` is false off, so the overlay-update condition is unchanged. `lastAppliedDetailMode` is only written inside the existing branch. `applyDriveMapStyle` builds the same target config. The renderer branches sit before the old ones but are gated.
- `SettingsView`: a `#if DEBUG` Developer section only. Release/TestFlight are unaffected. A DEBUG flag-off build shows one extra row (see `pr-3-gear-bottom.png`).
- plists/pbxproj: UIAppFonts added, 2 empty Resources phases, `UIUserInterfaceStyle=Dark` untouched.
- Real flag-off differences: the app icon only (the Clip icon too).

## Live sim comparison (iPhone 17 sim, iOS 26.5, Debug, flag off)
Screenshots are in `docs/qa/assets/ds-phase1-qa/`: `main-1-map.png` / `pr-1-map.png`, `main-2-gear.png` / `pr-2-gear.png`, `pr-3-gear-bottom.png`.
- Main map with ASP banner, toolbar and search sheet: identical, dark, no hint of light mode.
- Gear/Settings sheet: identical, dark, same rows.
- Not driven live: goal dock, Drive Mode start/end, My Car, search results. These need a destination or a live route. They are not verified live. By code, these paths only add flag-gated no-ops. I recommend a quick drive-mode smoke on a device before the next TestFlight.
- No curb overlays rendered at the simctl test location, so flag-off polyline drawing was verified by code only.
- PNG byte-cmp differs (clock/animation); visual inspection shows no difference.

## Clip size
Debug sim, WeParkClip.app embedded in WePark.app: main 6,852 KB, PR 7,140 KB, so **+288 KB**. That is 8 font copies (4 in the Clip, 4 in the ClipLiveActivities appex) at about 50 KB each raw. A Release thinned build will be smaller, and it is well within the 15 MB budget. This is not an archive measurement. If the budget ever tightens, the Clip likely needs only Medium and Bold.

## Token fidelity (15+ spot checks vs tokens/*.css, all match)
paper #FBF6E6, ink #241F45, taxi #FFD23F, park #3CCF7A, park-text #17803F, nopark-line #E39A90, nopark-text #B8322A, hairline #A9A7B8, plan #6A4CFF, detail-soon #F2A23A, detail-metered #5B7CFA. Dark bg/surface/lifted/line/shadow are #241F45/#2E2856/#3F3870/#6B64A0/#100D24. Radii 16/20/24/30/48; borders 1.5/2.5/3; raise 3/4/6; targets 48/64/80; type sizes 68/44/34/22. `WP.Hex.darkDivider` = #3F3870 is inferred from `--map-street` (documented in the file).

## Round-2 parts (renders in docs/qa/assets/ds-phase1)
- Verdict block (7 kinds): correct radius and padding, park fill, dashed coral with #B8322A over-line, dotted blue, 2pt grey no-data, plan ring. Good in light and dark. "Soon" matches b4-soon.png (dashed amber outline).
- Choice chip: radius 20, chosen = taxi + raise 4. OK.
- Switch: 56x34, knob 22, green on / #E4E3EC off. OK.
- Limit row: 3pt dashed coral, 48pt fix button. OK.
- List card: OK.
- Stamp: FAIL, truncates. Karma sticker: wraps. See findings.
- Trip tag/frame: OK at standard size. At AX5 in the gallery, the second tag is clipped top and bottom (finding 3).
- Raised is used only for pressable/earned (chosen chip, karma sticker, buttons). Verdict, stamp, hollow token, limit row and cards are flat. OK.
- Touch targets: chip/button/pill heights are 48-80 per `WP.Control`. OK.

## Findings

### 🟡 Significant
- **#1: Stamp text truncates ("SPOT PA...")**
  - Where: `WPSpotPassedStamp` in `WPCoachTripParts.swift`; render `stamp-token-karma-light.png` (light, dark and AX5).
  - What: no `fixedSize`/`lineLimit(nil)` on the Text, so in a narrow HStack the critical "SPOT PASSED" is cut.
  - Expected: critical text never truncates. The verdict block does this right with `fixedSize`.
  - Owner: `@ios-engineer`
- **#2: Karma sticker wraps "+5 / karma" onto two lines**
  - Where: `WPKarmaSticker`, same render.
  - What: the label has no `fixedSize`. The spec shows one line, "heart +5 karma".
  - Owner: `@ios-engineer`

### 🟢 Minor
- **#3:** The gallery trip-frame demo clips the tag at AX5 (`trip-frame-light-ax5.png`). It is likely a fixed-height demo container. Confirm the real `wpTripFrame` tag grows rather than clips.
- **#4:** The Live Activities Resources phases are empty. The fonts arrive via the synced Shared folder. Confirm in a Release archive that all 4 fonts are in both appex bundles (not verified for Release).
- **#5:** `freeButRestrictionSoon` draws solid green in the default 2-state mode ("free right now"). That is defensible and matches today's green. It is still a green line that stops being valid soon, while detail mode shows amber. Confirm intent with the owner against the "green must nest" rule.

### 💡 Out of scope
- Flag-on screens are not adopted yet. The flag-on map, browse light/dark and polyline drawing were not run live.

## Accuracy rules
- `CurbLineStyleV2.kind`: `.unknown` -> `.dont` (default) or `.noData` (detail, 2pt grey solid). Never park.
- `WPVerdictKind.kind(for:isPlan:)`: only `.freeComfortably` yields a park kind. `.unknown` -> `.nodata` / `.plandont`. Covered by tests.
- Metered in default mode -> dashed coral (not green). Good.

## App icon
- All three PNGs are 1024x1024 with `hasAlpha: no` (opaque). Contents.json wires universal + dark + tinted (luminosity appearances) for both the app and the Clip catalog.
- It matches A2.1: ink-violet field, yellow token with a dark car block, a green solid curb turning into coral dashes. The composition is left/bottom-weighted with a large empty right side, same as the reference. At 60 pt the token and the green/coral band still read, and the car block inside the token becomes a small dark blob. Dark and tinted are nearly identical in file size to light (30.8 KB vs 30.5 KB), so check the tinted one is truly grayscale on a device.
- Opinion: acceptable as the placeholder the design sheet calls it ("final glyph should be drawn properly"). The car glyph is the weak part.

## Builder notes, my opinion
1. **Soon = dashed amber outline vs README "amber fill":** I agree with following the part file and b4-soon.png. A dashed outline fits rule 3 and the long-dash amber curb line. Fix the README text.
2. **Flag-on browse may resolve dark from the plist key:** a real risk. `INFOPLIST_KEY_UIUserInterfaceStyle = Dark` forces windows dark, and `.unspecified` hands control back to that key. Fix it before the flag flips (drop the key, force dark at the window when the flag is off). It is not blocking here because it would change flag-off launch behavior.

## Smoke tests run
- Built the 3 secondary targets plus WePark, and ran the full test suite (xcresult 2943 pass / 0 fail).
- Built `main` from a clean `git archive` copy and compared the Clip sizes.
- Installed the main and PR builds on a dedicated sim and read screenshot pairs of the map and Settings.
- Read the verdict, switch, limit row, stamp, chips, AX5 trip-frame and icon renders, and read the A2 reference.

## What's working
Flag isolation is clean, commented and tested. Colors, radii and sizes are exact. The accuracy rules are encoded and unit-tested. The gallery is DEBUG-only and the render pipeline is repeatable.
