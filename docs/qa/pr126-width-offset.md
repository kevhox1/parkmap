# QA — PR #126 FT-21 width-offset resurrection — 2026-10-06

**Verdict: code MERGE-THEN-REGEN (safe); docs required a number correction (done in follow-up).**

Code changes (Forsyth allow-list removal + `getStreetCurbOffsetForCanonKey` canonical-key tier fix) verified correct and citywide-safe: all 1,207 streets monotonic (min 6.00m, never worse than today); 24/32 major streets correctly hold 10.0m (no 6m regression); no narrow-street over-offset found; composes cleanly with #116 per-carriageway (no double-counting); all three harnesses pass together (determinism, arrow 26/26, width 41/41); no tiles/ios/supabase shipped.

**🔴 doc-only finding (corrected on main post-merge):** the investigation doc's "today" baseline was computed via the abbreviated canonKey, understating Houston/Delancey. Ground-truthed against shipped tiles: E/W Houston and Delancey are ALREADY at the 10m wide tier today. Real resurrection deltas: **E Houston +2.79m, W Houston +2.49m, Delancey +4.00m** (not +6.79/+6.49/+8.00). Allen +7.40m, Bowery +2.49m, Forsyth +0.00m all confirmed as-documented.

**Consequence for the eventual visual gate:** Houston's real movement (~2.8m) is comparable to Bowery's already-insufficient +2.5m — so a regen may NOT visually resolve the original "Houston floats mid-road" complaint. Allen (+7.4m) will clearly move. Recalibrate gate expectations accordingly; Houston may need Option B (planimetric curb geometry) from the original FT-21 A→B→C ruling.
