# FT-11 iOS (Report Direction) — QA Report

**Reviewed:** branch `ios/ft11-report-direction` @ `b57afb6` vs `docs/ft11-report-direction-spec.md`.
**Verdict:** PASS-WITH-NOTES. **Tests: 466/0** (independently verified; +20 FT-11 tests).

## Make-or-break items — both PASS
- **Graceful absence (AC-3):** `Segment.oneway: Bool?` / `onewayToward: String?` decode optionally (`decodeIfPresent`); absent tile fields → nil, no crash; sweeper falls back to picker. Backward-compatible.
- **#31 safety:** `syncCommunityPinAnnotations` gained a `segments:` param + `resolveBearing` static helper but remains a pure annotation add/remove diff — NO setCamera/setRegion/userTrackingMode introduced in updateUIView. Confirmed by code review.

All ACs 1–23 pass (segment decode, HeadingToward enum, meta decode/round-trip, SegmentBearing math, picker visibility, auto-derive, buildMeta encoding, insert wiring, chevron-present-vs-absent).

## Findings
- **SIGNIFICANT #1 — chevron/picker arrow 90° off compass.** `chevron.forward` points EAST natively; both `PinMarkerAnnotation` (CGContext rotation) and `ReportSheet` (`.rotationEffect`) apply `bearing` without a `-90°` correction → arrow points 90° off (north-street arrows point east/west). Functional selection + `heading_toward` value are CORRECT; only visual orientation is wrong. **Fix before ship:** apply `bearing - 90` in both sites (+ adjust the CGContext offset translation accordingly). → bundled into the build-7 TF2-3 fix.
- **MINOR #2 (deferred):** `resolveBearing` does a linear scan of ~39k segments per new pin. Fine at current pin volume (diff-only, O(10-100) pins); convert to a `[id: Segment]` dict if volume grows.
- **NIT N-1:** extract `shouldShowDirectionPicker(type:segment:)` as a static func for direct testing (tests currently mirror the logic inline).
- **NIT N-2 (informational):** `SweeperPassedMeta` gained explicit CodingKeys — confirmed backward-compatible (`direction` key unchanged).

## Kevin's gate (real tiles + on-device)
Picker orientation (after #1 fix), chevron on a real marker, one-way sweeper auto-derive (needs the deferred tile regen on `data/ft11-oneway-tiles`), off-segment no-picker, legacy-pin no-chevron, overlay-chain visual.
