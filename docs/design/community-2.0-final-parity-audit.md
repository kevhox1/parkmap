# Community 2.0 final hero-parity audit — build 20, S13c

**Date:** 2026-09-08
**Scope:** every merged Community 2.0 surface on `main` (through PR #103, `ceb2322b`) vs.
`design/prototype.html` + `design/screenshots/` (target state), plus every accumulated open-items
line (`docs/open-items.md` #12, #14, #15) and the S13c garage-savings decision.
**Method:** every code claim below traces to a specific file/function I read this session (cited
inline); every copy claim was checked character-by-character against `prototype.html`'s literal
markup, not against a paraphrase of it. Where a claim is inherited from a prior QA pass or
open-items entry and I did not independently re-derive it from code this session, it's marked
**(inferred, not re-verified)** rather than stated as fact. `design/screenshots/*.png` were fetched
directly this session (Glob/Grep were unavailable in this environment — permission error on the
underlying `rg` binary — so file discovery was done by reading known filenames cited in code
comments; two names I guessed, `06-away-zone.png` and `14-notification.png`, did not resolve and
are not re-confirmed visually this pass, though their claims are otherwise supported by code).

---

## Summary

Community 2.0's build-20 surface is substantially converged with the prototype — every major
missing section identified in the prior gap inventory (map chrome, block detail, chat, spot
placement, identity, trust loop, leaving-soon) is now built, flag-gated, and copy-verbatim on the
surfaces I could verify. This pass found **1 cluster of 3 related🔴-class deviations** (the
zone-boundary overlay shows all three zones instead of the user's own, mislabels "YOUR SQUARE" for
a zone the user is merely panning through rather than one that's genuinely theirs, and stays
visible in Drive Mode) that were already named in `open-items.md #15` but not yet fixed in code —
confirmed here down to the exact lines. Beyond that, **7 🟡 significant** findings (crew-feed icon
palette still disagreeing with the newly-shipped Map Key legend; the sweeper "heading toward"
picker missing its "Not sure" escape hatch; the enforcement/sweeper taxonomy overlap; the
"0% accurate" false-negative; cramped block-chatter rows; no live-update on block chatter; the
confirm-street below-the-fold discoverability gap) and **4 🟢 polish** items round out a
**13-item fix list**, plus the garage-savings stat (a genuine design+build task, not a bug). My
**top three highest-impact items** are: (1) the zone-box triad — it's the most visible, most
frequently-seen new chrome in the whole feature and currently tells every user a lie about which
neighborhood is "theirs"; (2) the crew-feed/map-key icon-palette mismatch — a user who opens the
"?" legend to learn what a pin means will see a different color/icon for that same pin type
seconds later in the feed; (3) the garage-savings stat, which is the one item on this list that is
new build, not a fix, and needs a derivation decision from Kevin before anyone writes code.

---

## 1. Screenshot-by-screenshot table

| # | Screenshot | Verdict | Notes |
|---|---|---|---|
| 01 | `01-home-collapsed.png` — top-right rail, Report pill, "?" button, ASP banner | ✅ **MATCHES** | Verified in `ContentView.swift`: `communityMapChromeOverlay` (reportPillButton + mapKeyButton, both `.regularMaterial`, hidden during Drive/block-select/spot-placement) + `recenterButtonStack` + `ASPBanner`. Report pill copy "Report" + `flag.fill` matches `prototype.html:78`'s icon+label shape (native SF Symbol, not the prototype's raw SVG — correct per this review's own SF-Symbol bias). |
| 02 | `02-map-key.png` — CURB COLORS + LIVE PINS legend | 🟡 **RULED-EXCEPTION** (presentation) / ✅ MATCHES (curb copy) | `MapKeyLegendView.swift`: presented as a `.medium` sheet via `ActiveSheet.mapKeyLegend`, not a floating anchored popover — correct native mapping, documented in-file (SwiftUI has no first-class anchored-popover-sized-to-content primitive on compact width; `.popover` auto-converts to a sheet anyway). `curbColorEntries` copy is byte-verbatim vs. `prototype.html:1020-1026`. `livePinEntries` deliberately shows the shipped teal/cyan SF-Symbol treatment, not the prototype's orange-ring/emoji `pinLegend` array — this is Judgment Call #1 / locked decision #6's standing exception, correctly applied. Footer copy is adapted, not verbatim, because there is no pulse/fade animation and the car pin is blue, not black — also correctly documented in-file as a deliberate "describe reality" rule. |
| 03 | `03-your-square.png` — dashed zone box + "YOUR SQUARE · NOLITA" label | 🔴 **DEVIATES — 3 related, unfixed gaps** | See Fix List #1–#3. `MapViewRepresentable.syncZoneBoundaries()` (`Views/MapViewRepresentable.swift:1843-1881`) renders **all three** seeded zone boxes unconditionally, not just the user's own (open-items #15①, unfixed). The "YOUR SQUARE" label is driven by `ContentView.communityHomeZoneId`/`resolveHomeZoneId` (`ContentView.swift:2283-2308`), which falls back to the **map viewport center** when no car is parked — so panning to SoHo while your car sits in Nolita, or simply browsing with no car parked at all, labels whatever zone is on screen as "YOUR SQUARE" (open-items #15①'s "label only when genuinely theirs" is not actually implemented — verified, not just repeated from the open-items line). The overlay is also not hidden during Drive Mode: `ContentView.mapRepresentable`'s `showZoneBoundaries: AppConstants.communityEnabled` (`ContentView.swift:2351`) has no `&& !driveModeActive` term, unlike `communityMapChromeVisible`'s sibling gate two properties above it in the same file, which correctly excludes Drive Mode (open-items #15②, unfixed). |
| 04 | `04-feed-half.png` — zone chips + feed + compose bar visible at a half/medium detent | 🟡 **RULED-EXCEPTION** (detent) / ✅ MATCHES (compose bar) | Crew feed mounts only at `.large`, never `.medium` — this is Decision 6 / Judgment Call #2, explicitly locked, not to be re-opened. The "Say something to the square…" compose bar itself (the part of this row that WAS a real gap in the prior audit) is now built: `CrewFeedSection.crewComposeRow` (`Views/CrewFeedSection.swift:611-644`), routed through the identity gate, sends via `ZoneMessageService.sendMessage(zoneId:segmentId:nil,body:)`. |
| 05 | `05-feed-full.png` — tickets-dodged banner, leaderboard, profile row, feed | 🟡 **PENDING** (banner only) / ✅ MATCHES (everything else) | Leaderboard (`CommunityLeaderboard.build`), profile row (`profileRow`), compose bar, and feed all match, verified in `CrewFeedSection.swift`. "Tickets dodged this month" is deliberately absent — the file's own header comment states it was skipped as unfabricatable, replaced per Kevin's 2026-08-31 decision by the garage-savings stat, which is not yet built (see §3 below). This is the one line item in this screenshot still open. |
| 06 | `06-away-zone.png` — "you're browsing this square — posting stays in your home square" note | ❌ **DEVIATES — absent, no owner** | Could not re-fetch this screenshot this session (filename guess didn't resolve), but confirmed by direct code read: `CrewFeedSection.swift` has no string matching this copy anywhere (searched the full file). Zone-switching itself (`zoneChipsRow`) works. This is the same orphaned gap the prior gap inventory named — still nobody's explicit touch point. Small (one `Text`, one boolean: `selectedZone != homeZone`). |
| 07 | `07-block-detail.png` — color band, big status line, rules, LIVE ON THIS BLOCK, BLOCK CHATTER | ✅ **MATCHES**, with 2 polish gaps | `BlockDetailView.swift`'s S13b additions (`liveOnThisBlockSection`, `blockChatterSection`) are shipped, flag-gated, and reuse `CrewFeedSection.PinFeedRow` so reactions can't drift between the two surfaces. Empty-chatter copy ("No chatter yet" / "Be the first — crews form block by block.") is byte-verbatim vs. `prototype.html:881`. Two open, code-verified polish gaps carried from PR #103 QA: block-chatter rows are visually cramped relative to the crew feed's own chat rows (Fix List #8), and the thread has no live-update while the sheet is open — confirmed via `ZoneMessageService.swift`'s own header comment describing `fetchMessages(segmentId:)` as "a SEPARATE one-shot read" (Fix List #9). |
| 08 | `08-report-grid.png` — 2×2 report-type card grid | ✅ **MATCHES**, with 1 known taxonomy gap | `ReportSheet.reportGridSection` (`Views/ReportSheet.swift:985-1027`) is a native `LazyVGrid` with SF Symbols (not a pixel port of the prototype's emoji cards), prototype-exact border tints (`#FF9F0A`/`#30D158`/`#0A84FF`/`#E8730D`), and verbatim copy for all four tiles — checked character-by-character against `prototype.html:361-380`. Taxonomy overlap: "Cleaning truck" is still offered as an Enforcement sub-tag (`subTagPickerRow`) even though "Sweeper passed" is now its own top-level, equally-discoverable grid tile — open-items #12③, NOT resolved (Fix List #6). |
| 09 | `09-report-confirm-street.png` — 4 candidate rows + HEADING TOWARD chips | 🟡 **MOSTLY MATCHES**, 2 verified gaps | Candidate-row structure/copy/all-caps section label (`"Confirm the street"` rendered via `.textCase(.uppercase)`) is correct, per the PR #95 QA fix. Direction picker: the screenshot shows **3** chips — toward-A, toward-B, and a **"Not sure"** third option (`prototype.html:992`, `repDirChips`'s `[null, 'Not sure']` entry) — the shipped `headingTowardPickerRow` (`ReportSheet.swift:766-795`) renders only 2 (`.from`/`.toward_to`), with no escape hatch and no visible fallback state on one-way segments (the picker simply doesn't render at all there — auto-derived silently, per `shouldShowDirectionPicker`'s existing, correct FT-11 logic). This supersedes and narrows open-items #12⑥, whose original phrasing ("shipped sweeper only has the temporal toggle") is now stale — the spatial picker IS wired for two-way sweeper segments; what's actually still missing is the "Not sure" option and one-way visibility (Fix List #5). Separately, the picker's own section label reads "Which way?" (pre-existing FT-11 copy, `.footnote`, sentence case) rather than the prototype's "HEADING TOWARD" (`prototype.html:403`) — now visually inconsistent with the ALL-CAPS "Confirm the street" label directly above it in the same sheet (Fix List, new find, listed with #5). |
| 10 | `10-spot-placement.png` — "Tap the curb where the spot is" hint | ✅ **MATCHES** | `SpotPlacementHintBanner`, `Views/SpotPlacementView.swift:124-150`. Copy byte-verbatim vs. `prototype.html:87-88`. |
| 11 | `11-spot-confirm.png` — "P Spot open — {street} (side)" confirm card | ✅ **MATCHES**, 1 documented deferral | `SpotPlacementConfirmCard` + `SpotPlacementCopy`, verbatim title/subtitle/footer construction vs. `prototype.html:92-103` (`SpotPlacementCopy.confirmFooter` is character-identical to `prototype.html:100`, including the `·` separators). MapKit-POI storefront naming ("in front of The Elk") remains deferred — a named, deliberate scope cut from S7, not a regression. |
| 12 | `12-identity-sheet.png` — "Say hi to the crew" | ✅ **MATCHES**, genuine improvement over the prototype | `IdentitySheet.swift`. Copy, 8-avatar order (🥯☕🚕🌇🦝🍕🗽🐿️), and the pre-filled "MottStRegular"-style handle all verbatim/faithful. The show-once gate (`CommunityIdentityGate`) deliberately fixes a real bug in the prototype's own `needIdentity()` logic (which never latches and would re-prompt every contribution) — correctly documented as an intentional, positive deviation, not a compromise. |
| 13 | proactive "did it pass?" card (best-match screenshot: `13-confirm-prompt.png`) | ✅ **MATCHES** | `ConfirmPromptCard.swift`. Copy is byte-verbatim vs. `prototype.html:106-110`, including the em dash in "did it pass?" phrasing; the static "148" is correctly replaced by the live `pin.confirmCount`. Presentation as a floating overlay (not a modal `.sheet`) is a documented, reasonable judgment call — a proactive, dismissible card the user might be mid-task around belongs with `SpotPlacementConfirmCard`'s floating-card family, not a blocking modal. Shares one predicate (`CommunityPushRelevance.firstUnseenSweeperPassedMatch`) with the background push path — verified in `ContentView.updateConfirmPromptCandidate` (`ContentView.swift:3103-3112`). |
| 14 | in-app "You're clear until Friday" push banner | 🟡 **RULED-EXCEPTION** | System notification banner chrome (app icon, not the prototype's custom colored-square icon) is an iOS platform constraint, not a design choice — a custom rich banner would need a `UNNotificationServiceExtension`, out of scope. Functionally verified working end-to-end on physical hardware per PR #101's QA record (S12 ceremony) — **(inferred from QA doc, not re-verified live this session — no device/toolchain available)**. |
| 15 | `15-my-car.png` — offset chips + swept badge + leaving-soon handoff | ✅ **MATCHES**, 1 tech-debt note | `ParkedCarDetailView.swift`'s S10 additions (`offsetChipsRow`, `sweptBadgeView`, `leavingSoonCard`) all present, flag-gated, copy-verbatim ("Hand your spot to the crew" / "Leaving in N min — tell the crew" both byte-identical to `prototype.html:324-331`, including the em dash). The swept-badge view is duplicated near-byte-for-byte between this file and `BlockDetailView.swift` (Fix List #11) — no behavior risk today, a drift risk going forward. |
| 16 | Park Until sheet | ✅ **CONVERGED** | Pre-existing W7.5 feature, unrelated to Community 2.0. One cosmetic preset-label difference ("Thu 9 AM" vs. a day-of-week label), not touched by this initiative. No action needed. |
| 17 | map with full pin variety + car pin + confirm-prompt overlay | ✅ **MATCHES** | Pin rendering (`PinMarkerAnnotation`), car pin, and the confirm-prompt overlay (row 13) are all live. This screenshot inherits row 03's zone-box gaps (same underlying cause, not double-counted below) — no other new gap found here. |

---

## 2. Consolidated fix list — ordered by user impact

### 🔴 1. Zone-boundary overlay: own-box-only, correct "genuinely yours" gating, hidden in Drive Mode
**Where:** `Views/MapViewRepresentable.swift:1830-1881` (`syncZoneBoundaries`), `ContentView.swift:2259-2308` (`communityHomeZoneId`/`resolveHomeZoneId`), `ContentView.swift:2344-2352` (`mapRepresentable`'s `showZoneBoundaries` argument).
**What:**
- `syncZoneBoundaries` loops `MapViewRepresentable.communityZoneIds` and adds **all three** boxes on the first `enabled == true` call, never fewer. Fix: render 0 or 1 polygon — only the box for `homeZoneId` when non-nil — and rebuild whenever `homeZoneId` changes (today the polygons are added once and treated as immutable; that assumption breaks once this becomes "the one relevant box," which does change).
- `resolveHomeZoneId` falls back to the **map viewport center** when no car is parked, and that same value drives the "YOUR SQUARE" text — so an unparked user, or a parked user who's simply panned elsewhere, gets a false "this is yours" label. Recommend: only show the "YOUR SQUARE" framing when a car is actually parked in that zone; when no car is parked, either show no label at all, or show the zone's plain name without the "YOUR SQUARE" claim, until Kevin decides what "genuinely yours" should mean for a car-less browsing session.
- `mapRepresentable` passes `showZoneBoundaries: AppConstants.communityEnabled` with no Drive Mode exclusion — add `&& !driveModeActive`, matching the sibling `communityMapChromeVisible` gate two properties above it in the same file.
**Why it matters:** this is the single most-visible new piece of map chrome in the whole feature (it's drawn directly on the map, not tucked in a sheet), and today it either clutters the map with all three zones or tells the user something false about which one is theirs — both undercut the "glanceable, 1-2 second read" bias this product is built around.
**Size guess:** ~1 session (all three sub-fixes are the same file/PR; the rendering change is mechanical, the "what counts as genuinely yours" question needs a one-line product decision from Kevin before coding, not a design spec).

### 🟡 2. Crew-feed / block-chatter icon palette still disagrees with the Map Key legend
**Where:** `Views/CrewFeedSection.swift:236-250` (`CrewFeedMerge.icon(for:)`).
**What:** Still returns the prototype's literal 🎫 orange (`#FF9F0A`) / 🧹 green (`#30D158`) rings for `enforcement_active`/`sweeper_passed`, while `MapKeyLegendView.livePinEntries` (built in the SAME S13a session) explicitly documents and ships teal/cyan SF Symbols as the canonical treatment, matching the actual map markers. `BlockDetailView`'s "LIVE ON THIS BLOCK" section inherits whatever `CrewFeedMerge.icon` returns for free (it reuses `PinFeedRow`), so this is now a three-way disagreement across map markers, map legend, and every list-style pin row.
**Why it matters:** a user opens the "?" legend specifically to learn "what does this icon mean," sees a teal circle for Enforcement, then two seconds later sees an orange ticket emoji for the identical pin type in the feed — the legend stops being trustworthy.
**Fix:** change `CrewFeedMerge.icon(for:)`'s enforcement/sweeper cases to `.teal`/`.cyan` with SF Symbols (`person.badge.clock.fill`/`truck.box.fill`), matching `MapKeyLegendView.livePinEntries` and `PinMarkerAnnotation.markerStyle(for:)` exactly.
**Size guess:** ~0.25 session — a values-table swap, no new views, no logic change.

### 🟡 3. Sweeper "HEADING TOWARD" picker: add the "Not sure" option; make the one-way auto-derive visible
**Where:** `Views/ReportSheet.swift:746-795` (`headingTowardPickerRow`), `:987` (`repNeedsDir`-equivalent gate).
**What:** Screenshot 09 shows 3 chips (toward-A / toward-B / "Not sure"); the shipped picker renders only 2, and renders **nothing at all** on a one-way segment (auto-derived silently — correct FT-11 behavior, but invisible: there's no way for a user to tell "the app inferred a direction" from "there's no direction info at all"). This supersedes open-items #12⑥, whose original description ("shipped sweeper only has the temporal toggle") is stale — the spatial picker already works for two-way segments.
**Fix:** add a third "Not sure" chip (maps to `heading_toward: nil`, matching the enforcement picker's existing nil-tolerant payload path); on a one-way segment, show a small read-only label ("Heading toward {street}, inferred") instead of nothing, so the auto-derivation is visible rather than silent.
**Why it matters:** a reporter who genuinely doesn't know which way an agent/sweeper is heading has no honest option today besides guessing.
**Size guess:** ~0.5 session.

### 🟡 4. Taxonomy overlap: drop "Cleaning truck" from the Enforcement sub-tag list
**Where:** `Views/ReportSheet.swift:660-692` (`subTagPickerRow`).
**What:** open-items #12③, still unresolved. "Cleaning truck / Parking agent / Tow truck / Not sure" all still live under "Enforcement active," even though "Sweeper passed" is now its own equally-discoverable top-level grid tile — a user who sees a literal street-sweeper truck has two plausible places to report it.
**Fix:** remove the "Cleaning truck" pill from the enforcement sub-tag row now that Sweeper is first-class; keep "Parking agent"/"Tow truck." Check for any already-written `sub_tag: cleaning_truck` rows before removing the enum case itself — keep it decode-compatible even if the UI no longer offers it.
**Size guess:** ~0.25 session.

### 🟡 5. "0% accurate" still shows for a poster whose reports are merely unconfirmed
**Where:** `Views/CrewFeedSection.swift:340-344` (`ProfileRowFormatting.accuracyLabel`).
**What:** open-items #12⑤, still unresolved. The em-dash guard only checks `total == 0`; a brand-new poster with 1 report and 0 confirms gets a literal "0%," which reads as punitive rather than the honest "not enough confirmed data yet" it actually is.
**Fix:** return "—" whenever `accurate == 0` (not just when `total == 0`) — a user needs at least one CONFIRMED report before a percentage means anything.
**Size guess:** trivial — one function + its existing test file.

### 🟡 6. Block-chatter rows read cramped vs. the crew feed's own chat rows
**Where:** `Views/BlockDetailView.swift:731-759` (`BlockChatRow`) vs. `Views/CrewFeedSection.swift:994-1022` (`ChatFeedRow`).
**What:** Kevin's own S13b-gate finding, now pinned to exact code: `BlockChatRow` uses 4pt vertical row padding and 1pt internal `VStack` spacing with no icon badge; `ChatFeedRow` — visually the same kind of content — uses 11pt vertical padding and a 36×36pt icon badge. Two rows for the same underlying idea ("one chat message") have noticeably different densities for no stated reason.
**Fix:** bring `BlockChatRow`'s padding/spacing up to `ChatFeedRow`'s density (doesn't need the icon badge, just the breathing room).
**Size guess:** ~0.25 session.

### 🟡 7. Block chatter has no live-update while the sheet is open
**Where:** `Services/ZoneMessageService.swift:31-41` (header comment describing `fetchMessages(segmentId:)` as "a SEPARATE one-shot read"), `Views/BlockDetailView.swift:412-419` (`loadChat()`).
**What:** open-items #14, confirmed in code this session (previously only asserted in QA prose). A neighbor's message posted while you're reading the thread needs a close/reopen to appear — only your own just-sent message appends optimistically.
**Fix:** wire the existing `ZoneMessageService` Realtime channel (already subscribed for the zone-wide feed) to also append into `BlockDetailView`'s local `chatMessages` when a new row's `segment_id` matches the open block.
**Size guess:** ~0.5–1 session.

### 🟡 8. Confirm-the-street section can mount below the sheet's visible fold
**Where:** `Views/ReportSheet.swift` — `confirmStreetSection` render position (both grid and list branches).
**What:** open-items #12④. Logic is correct (QA already confirmed this is a discoverability flaw, not a bug), and it's not been touched by any session since. A user who selects a report type may not realize there's more content to scroll to below.
**Fix:** on first render of the confirm-street section after a type is selected, scroll it into view (`ScrollViewReader` + `.id`), or at minimum add a subtle "more below" affordance.
**Size guess:** ~0.5 session.

### 🟢 9. "Which way?" section label doesn't match the new "HEADING TOWARD" visual language
**Where:** `Views/ReportSheet.swift:773` (`headingTowardPickerRow`'s `Text("Which way?")`).
**What:** new finding this pass. Pre-existing FT-11 copy, sentence-case, `.footnote.weight(.medium)` — now sitting directly below the S6-added "CONFIRM THE STREET" label, which IS styled all-caps via `.textCase(.uppercase)` to match the prototype's own `HEADING TOWARD` treatment (`prototype.html:403`). The two adjacent section labels in the same sheet now visually read as two different UI eras.
**Fix:** apply the same `.textCase(.uppercase)` treatment (or rename the string to "HEADING TOWARD") for visual harmony — copy-only, no logic change. Bundle with Fix #3 since it's the same view.
**Size guess:** trivial.

### 🟢 10. Swept-badge view duplicated byte-for-byte across two files
**Where:** `Views/BlockDetailView.swift:289-309` vs. `Views/ParkedCarDetailView.swift:275-499` (`sweptBadgeColor`/`sweptBadgeView(for:)`).
**What:** open-items #14, confirmed in code — both files independently declare an identical private color constant and a near-identical badge view (differing only in a `\u{00B7}` vs. `·` literal, same rendered output). No behavior risk today; a future copy/color change made in one place will silently drift from the other.
**Fix:** extract to one shared `internal` view, mirroring this codebase's own `RuleRow`/`TemporaryRestrictionBanner` precedent for content shared across these exact two files.
**Size guess:** ~0.25 session.

### 🟢 11. `sendMessage`'s 1000-char boundary is untested
**Where:** `Services/ZoneMessageService.swift` — `sendMessage`'s length guard (per PR #103 QA; guard read as correct by inspection, not independently re-verified in code this session — **inferred**).
**What:** open-items #14. No test exercises the exact 1000-char boundary (999/1000/1001).
**Fix:** one boundary test, no behavior change expected.
**Size guess:** trivial.

### 🟢 12. "You're browsing this square" away-note — still nobody's explicit touch point
**Where:** `Views/CrewFeedSection.swift` (absent — confirmed by full-file read, no matching string anywhere).
**What:** screenshot 06's copy ("You're browsing this square — posting stays in your home square (Nolita), where your car sleeps") has no code anywhere. This is the same orphaned gap the prior gap inventory named; still nobody's session explicitly owns it.
**Fix:** one conditional `Text`, gated on `selectedZone != homeZone` (reuse the same `communityHomeZoneId`-style logic once Fix #1 exists — don't build this against the currently-broken "viewport fallback" home-zone logic, build it against the corrected version).
**Size guess:** ~0.25 session, sequence AFTER Fix #1 so it's not built on the buggy foundation.

### ⚪ 13. Long-press report entry flakiness — argue out, don't fix
**Where:** open-items #12①.
**What:** "Long-press report entry takes two attempts to stay up." Kevin/QA already ruled this superseded: the persistent Report pill (verified shipped, Fix List item N/A — this is `communityMapChromeOverlay`, row 01, confirmed MATCHES above) is now the primary, always-visible entry point; the long-press dialog remains only as a legacy shortcut for a user who already knows the gesture. **Recommendation: close this open-items line formally rather than carry it forward — nothing to build.** The pill exists precisely because a driver who doesn't know the long-press gesture had no other way to discover reporting; that discoverability problem is solved regardless of whether the long-press dialog itself is perfectly reliable.

---

## 3. Garage-savings stat — proposal

**The problem tickets-dodged solved (engagement) and why it was cut:** "interesting but so
difficult to verify" (Kevin) — there is no way to know a ticket that *would have* been issued but
wasn't. The replacement must be honestly derivable from data the app actually has.

**Data-gap check (the non-negotiable part):** today, a parked car's `parkedAt` timestamp lives
entirely in `ParkPinService`'s local iCloud key-value store (`Services/ParkPinService.swift`) and
is **never uploaded to the server** — confirmed by reading the file's own header and storage keys.
The "I left — clear pin" action (`ContentView`'s `.parkedCarDetail` → `onClearPin`) discards the
car's state and never records anything about how long it was parked. **There is currently no
accumulator anywhere — client or server — for "total time parked" or "total money saved."**
Building this stat is genuinely new work, not a display change on existing data, and needs exactly
one new piece of state before any UI can show a number.

**Recommended derivation (Option A — most honest, smallest build):**
1. At the moment "I left — clear pin" fires, compute `duration = now - parkedCar.parkedAt`
   (already-available data, zero new fields on `ParkedCar` itself needed for the computation).
2. Convert to dollars via a fixed hourly-equivalent rate derived from the number **this app
   already uses and has already told the user**: `ParkingGuideView`'s own Parking 101 copy cites
   "Manhattan garages run $500–$1,000+ a month." Take the low end of that stated range ($500/mo ÷
   ~720 hours/mo ≈ **$0.70/hr**) so the accumulated total is conservative, not inflated, and is
   traceable to copy the app already shows elsewhere (no new, unsourced constant).
3. Accumulate the resulting dollar amount into a device-local `UserDefaults` running total (same
   storage tier as `hasEverParkedKey`/`ReminderOffsets` — no schema change, no account needed,
   consistent with the product's zero-friction, no-login model). Reset on a calendar-month
   boundary using this codebase's existing no-`Calendar.current` convention (manual month-boundary
   arithmetic against `.nowET`, same style already used elsewhere in this file family).
4. Display the running total in `CrewFeedSection`, inserted between `crewComposeRow`'s `Divider()`
   and `profileRow` — the exact slot screenshot 05's stat-card occupies (before the leaderboard,
   after the compose bar).

**Option B (punchier, needs a heuristic Kevin must explicitly bless):** instead of accruing by the
hour, treat each full parked session as "one avoided day of garage storage" (a flat per-session
credit at a prorated daily rate, ~$16-17/day off the same $500/mo figure), regardless of whether
the car was parked for 40 minutes or 4 days. This produces a bigger, more shareable number faster,
but overstates the savings for a short errand-parking session — flagging explicitly rather than
picking it silently, since "honestly derivable" is the one non-negotiable constraint on this
feature.

**Recommendation:** Option A. It's slower to accumulate into an impressive-looking number, but it
never says something about a specific session that isn't true, and it's directly traceable to copy
Kevin has already approved elsewhere in the app.

**Copy options (for Kevin to pick):**
1. **"Saved vs. a garage: $X this month"** — plainest, most literal, no personality.
2. **"Street money, kept: $X this month"** — a little more voice, still accurate (frames it as
   money that stayed in your pocket, not money "earned" by the app).
3. **"$X back in your pocket this month — no garage needed"** — closest in tone to the Parking 101
   copy's own "roughly $4,800–$12,000 a year back in your pocket" framing, reuses established
   voice rather than inventing new copy.

My pick, if asked: **#3**, because it's the only option that echoes language the app has already
used and Kevin has already approved (Parking 101's "money math" card), rather than inventing a new
voice for the same idea.

---

## 4. New findings (fresh eyes, not previously logged anywhere)

- **The zone-box "genuinely yours" mislabeling (Fix List #1's second half)** is a sharper, more
  precise version of open-items #15①'s prose ("label only when genuinely theirs") — the prior
  ruling didn't diagnose that the current fallback conflates "wherever the map is currently
  centered" with "yours." Worth calling out explicitly so the S13c engineering session doesn't
  treat "just gate on `homeZoneId != nil`" as sufficient — it isn't, `homeZoneId` is non-nil far
  more often than it should be.
- **The crew-feed/map-key icon-palette disagreement (Fix List #2)** is a sharper version of the
  original gap inventory's "crew-feed icon palette fix" recommendation — that inventory only
  compared the crew feed against the map MARKERS; it couldn't have compared it against
  `MapKeyLegendView` because that file didn't exist yet. Now that the legend exists and explicitly
  canonizes teal/cyan, the crew feed disagreeing with it is a more visible, more clearly "which one
  is right?" problem than disagreeing with a marker on the map the user may not be looking at.
- **The "HEADING TOWARD" vs. "Which way?" label mismatch (Fix List #9)** is newly found this
  session — nobody had flagged it because the two labels only started appearing in the same sheet
  once S6 (confirm-the-street) landed above the pre-existing S-era heading picker.
- **Confirmed, not just inferred:** the "no live-update" claim for block chatter (open-items #14)
  is directly supported by `ZoneMessageService.swift`'s own header comment, which describes
  `fetchMessages(segmentId:)` as intentionally "a SEPARATE one-shot read" — this was previously
  only a QA-report claim; it's now traced to the exact design decision in the code's own words.

---

## 5. Post-v1 — genuinely not-now

- **MapKit POI storefront naming** for `open_spot` placement ("in front of The Elk") — deferred
  scope cut from S7, still correctly deferred.
- **True weekly-reset leaderboard ledger** (`reputation_events`) vs. the current live-query
  approximation — worth building only if the leaderboard turns out to matter to retention.
- **True NTA polygon zone geometry** vs. bounding boxes — revisit only if boxes visibly
  misclassify real blocks once more zones exist (S14).
- **Shared identity-gate view modifier** — `ReportSheet`, `CrewFeedSection`, `BlockDetailView`,
  and `ParkedCarDetailView` each independently implement the same ~20-line
  `pendingIdentityAction` + nested `.sheet` pattern. All four are currently behaviorally
  consistent (verified by direct comparison this session), so this is pure maintainability debt,
  not a bug — a good candidate for a `.communityIdentityGated(...)` view modifier the next time
  any of these four files needs a real touch, not a reason to open a session on its own.
- **Option B garage-savings framing** (flat per-session daily credit) — only if Option A's
  accrual feels too slow/small in practice once it's live and Kevin has a gut check on real data.

---

## What's working

The block-detail redesign (screenshot 07) — the single highest-value gap named in the prior
audit — is genuinely, thoroughly done: live pins, chat, and the write path all share one action
model with the rest of the app (`CommunityPin.reactionsRowKind`), so nothing on this new surface
can silently disagree with the crew feed about what a pin means or what you can do with it. The
report-grid restyle (screenshot 08) is a clean example of "match the design's intent, not its
literal HTML" — native `LazyVGrid` + SF Symbols, prototype-exact colors, zero emoji-as-icon drift.
The identity sheet is a rare case where the shipped app is *better* than the prototype it's copying
(fixing a real re-prompt bug in the source design, not just porting it faithfully). And the
push/confirm-prompt pairing (rows 13/14) is exactly the kind of "one shared predicate, two trigger
surfaces" architecture this kind of feature needs — there's no way for the in-app card and the
background push to disagree about what counts as relevant to a given driver.
