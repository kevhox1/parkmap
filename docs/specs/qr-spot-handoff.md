# QR "Spot Pass" (neighbor handoff ping)

Status: DRAFT for Kevin. Author: Tech Lead. 2026-11-23.
Inputs: Kevin 2026-11-23 (verbatim: "the lowest barrier to entry quick action should be a QR code that you allow someone to scan that will notify the owner of the QR code when your car leaves that spot ... make that code sexy though and fun ... good neighbors ... building karma"), `docs/nyc-neighbors-incentives-concept.md` (karma/Good Neighbor layers, section 6 "reward verifiable + durable, not fleeting open spots"), `docs/community-2.0-reconciliation-spec.md` section 2.6 (reputation), `supabase/send-community-push` (APNs pipeline).

Working name: **Spot Pass** ("Pass the spot."). Final name is @designer's call.

## 0. Recommendation and decisions for Kevin (read first)

**Recommendation: build Kevin's direction. The WAITING person owns the QR; the LEAVING driver scans.** Reasoning:
- **Guaranteed delivery.** The one who gets the ping is the QR owner, so they necessarily have the app, an APNs token, and notification permission. The other direction (driver shows QR, waiter scans) lets the receiver be a non-user, and we cannot reliably push to a non-user (iOS Web Push only works for home-screen-installed web apps; SMS needs phone numbers = identity we refuse to hold).
- **Low barrier on the sending side.** The scanner (driver) only needs the plain iOS camera and a one-tap web page. No install, no account. The person who cares about the outcome (the waiter) bears the setup; the person doing the favor does one tap.
- **Consent is the scan.** The driver opts in by scanning and confirming. Nobody can arm a ping on a stranger's car without that stranger's phone tapping a confirm.
- **Growth loop.** The code is a branded object on a dashboard, seen by every driver walking to their car.
- Trade-off accepted: the waiter must be visible/near the leaving driver (code on phone mount or dash). Phase 2 adds the symmetric path (driver-created "I'm leaving" link the waiter scans) only for recipients who already have the app.

Decisions needed (only the vital ones):
1. **Confirm direction** (waiter owns the QR) as above.
2. **A domain for the link.** Universal Links/App Clip need an `apple-app-site-association` file at a domain root; `kevhox1.github.io/parkmap/` is a project page and cannot host it. MVP works without it (QR opens a static page on GitHub Pages, which offers "Open in WePark" via the existing custom URL scheme plus a no-install "I'm leaving" button). OK to ship MVP that way and buy a domain for Phase 2 App Clip? Recommended yes.
3. **Auto-detect departure needs "Always" location** (new permission, new background mode, App Store review justification). MVP is manual "I'm leaving" tap only; auto-detect is Phase 2. Confirm manual-first. Recommended yes (matches Kevin's "you can send the ping yourself").
4. **Karma amounts** (section 8). Defaults proposed; ignore unless you object.

## 1. Problem and user story

NYC street parking: someone circles; someone else is walking to their car. They never connect. Story: I am circling near Houston St. I open WePark, tap "Looking for a spot", and a Spot Pass card (QR) appears on my phone in the mount (or I hold it up). A driver walking to a car sees it, scans with the camera, taps "I'm leaving", and a minute later my phone buzzes: "Your neighbor is pulling out. The spot's opening up." Both of us earn Good Neighbor karma.

## 2. Scope

In (Phase 1 MVP):
- Seeker creates a Spot Pass in-app (20 min live), shows QR full-screen.
- Driver scans with iOS camera -> static web page `handoff.html` (or app if installed) -> confirm -> arms; driver taps "I'm leaving now" (manual) -> seeker receives an alert push.
- Server: table + RPCs + edge function; expiry, one-time use, cancel, rate limits, report.
- Karma (section 8) via the existing idempotent ledger.
- Branded neighbor-badge design (section 9).

Out (deferred):
- Auto departure detection / region monitoring (Phase 2, section 5.3).
- Printable dash card (needs token-rotation story, section 6.7), App Clip (Phase 2, needs domain).
- Driver-created pass scanned by waiter (Phase 2 symmetric).
- Chat, ETA sharing, maps, photos, live location of either party (never).
- Rewards-dollars / partner redemption (karma only).
- Android / web seeker.

## 3. Core flow and states

Single entity, `spot_handoffs`. States:
`created` (seeker made it, TTL 20 min) -> `armed` (driver scanned and confirmed; TTL resets to 15 min) -> `departing` (driver tapped "I'm leaving" or Phase 2 auto) -> `departed` (push sent; terminal) . Other terminals: `expired` (TTL hit in created/armed), `cancelled` (seeker or driver cancelled), `suspended` (abuse).
- One-time use: a code transitions `created -> armed` exactly once (atomic update `where status='created'`); a second scan sees "This pass was already used" and nothing else. One active pass per seeker (creating a new one cancels the old).
- Expiry: seeker pass 20 min unclaimed; once armed 15 min to depart; after `departed` the row holds no live data. Server cron purges rows older than 24 h (pattern: `supabase/02d-ingest-cron.sql`).
- Seeker can cancel at any time; the driver can cancel at any time before departing (page/app button "Never mind"). A driver cancel is silent to the seeker (no signal about the driver's behavior); the seeker just sees the pass expire. Rationale: no coercion or pressure on the driver.
- Seeker auto-ends when the seeker parks (ParkPinService saves a car) or the app detects a drive-mode end: `cancel_handoff`.

Sequence (MVP):
1. Seeker taps "Spot Pass" -> `create_handoff()` returns `{id, token}` (token 128-bit random, only its hash stored) -> QR encodes `https://kevhox1.github.io/parkmap/handoff.html#t=<token>` (fragment never reaches server logs).
2. Driver scans -> page calls edge function `handoff-claim` with token -> page shows confirm screen: "A neighbor is hoping for your spot. Tap when you're about to pull out and we'll let them know. They won't see who you are or where you are." [I'm leaving now] [Not now].
3. `I'm leaving now` -> `handoff-depart` -> row `departed` -> edge function `send-handoff-push` -> APNs alert to seeker.
4. Seeker app: "Spot opening up. Your neighbor is pulling out now." Buttons: [Got the spot] [Didn't work out].

## 4. Architecture (touches)

| Codebase | What |
|---|---|
| Backend | Migration `supabase/13-spot-handoffs.sql` (use the next free number), `13-spot-handoffs-test.sh`; RPCs `create_handoff`, `cancel_handoff`, `confirm_handoff_outcome`; edge functions `handoff-claim`, `handoff-depart` (token-gated, callable anonymously with rate limits), `send-handoff-push` (service role; reuse `_shared` APNs signer from `send-community-push`); extend `10-account-deletion.sql` to cascade. Kevin applies SQL himself and deploys functions; agents write files and stop. |
| iOS | Seeker flow (create, QR screen, receive ping, outcome), karma display, deep link `wepark://handoff?t=`, alert-push handling; flag `AppConstants.spotHandoffEnabled = false`. Phase 2: driver-in-app flow, region monitoring. |
| PWA | New static `handoff.html` (driver landing, no install) hosted at the existing Pages site. Does not touch `index.html`. |
| Designer | Section 9 brief. |

Data model (sketch):
```
spot_handoffs(
  id uuid pk, token_hash bytea unique, seeker_id uuid fk,
  status text check in (created,armed,departing,departed,expired,cancelled,suspended),
  created_at, expires_at, armed_at, departed_at,
  claimer_anon_id uuid null,   -- anonymous supabase uid or random device nonce; never shown to seeker
  outcome text null            -- seeker-confirmed: got_spot | no_luck
)
handoff_reports(id, handoff_id, reporter text, reason, created_at)
```
No coordinates, no addresses, no plate, no driver token on the row. RLS: seeker can select own rows (status only); everything else via security-definer RPCs/edge functions.

## 5. Notification delivery and departure detection

### 5.1 What exists today (grepped)
- Remote push: yes, partially. `AppDelegate` registers for remote notifications (`WeParkApp.swift:143-165`); `PushRegistrationService.swift` stores tokens in `public.device_push_tokens` (RLS-fixed in `supabase/05`); Edge Functions `send-community-push` and `send-regular-push` sign APNs requests with the `APNS_*` secrets (Key ID, team, `.p8`, topic `com.kevinhoxha.wepark`, per-token sandbox/production). `Info.plist` has `UIBackgroundModes = remote-notification`.
- BUT today's pushes are SILENT (content-available); the client decides on-device whether to show a local notification (privacy design in `send-community-push`: the server never learns the parked blockface). Spot Pass needs a visible ALERT push, a new payload shape in an existing pipeline. The notification permission flow already exists (`Views/NotificationRationaleView.swift`, `NotificationScheduler`); seekers must be authorized for alerts.
- Minimum new infra: one table + 3 RPCs + `send-handoff-push` reusing the existing APNs secrets and signer. No new Apple key. Optional: Time Sensitive interruption level (needs the Time Sensitive Notifications capability) so the ping breaks through Focus; Phase 2.

### 5.2 Non-user scanner (driver): web page vs App Clip vs SMS
| Option | Verdict |
|---|---|
| Static web page, one-button, anonymous token call | **MVP.** No install, works from the camera app's Safari banner. Manual "I'm leaving" only. No location. |
| App Clip | Phase 2. Better branding and can offer install, but needs domain + AASA + Clip target (15 MB cap), and Clips cannot do Always location, so still manual. |
| SMS | Rejected: needs phone numbers (identity), cost, spam risk. |
| Web Push to the driver | Not needed; the driver is the sender, not the receiver. |
If the driver HAS the app, the page's "Open in WePark" uses `wepark://handoff`, giving the in-app flow (Phase 2 adds auto-detect there).

### 5.3 Departure detection on the driver's phone (Phase 2 auto)
Today: location is **When In Use only** (`INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` in `project.pbxproj`; no Always, no `CLCircularRegion`/`CLMonitor`, no significant-change, no CoreMotion usage; `UIBackgroundModes` has only `remote-notification`; grep found none). Parked car state: `ParkedCar` lat/lon + segment, iCloud KVS via `ParkPinService`. So nothing detects departure today.
- **MVP: manual only.** The "I'm leaving now" tap is the departure signal; it is also the most accurate moment ("pulling out" not "walked away"). Zero new permissions. This satisfies Kevin's "you can send the ping yourself".
- **Phase 2: auto-ping, app-installed drivers only.** Region monitoring (`CLMonitor` / `CLCircularRegion`, radius about 75 m) centered on the driver's `ParkedCar` coordinate, armed only while a claimed handoff is `armed`. Needs "Always" authorization to relaunch in the background; ask in context ("Let WePark ping your neighbor automatically. Only while a Spot Pass is active. Turn off anytime"), with the "While Using" manual path remaining fully functional if declined. Region exit alone is not enough: require exit + speed above about 4 m/s sustained 5 s (CoreMotion automotive is an alternative but adds a Motion permission); else treat as a walk-away and do nothing.
- The departure call is one HTTPS request from the relaunched app; the region is on-device only; the server never sees the parked coordinate.
- False positives: walking away from the car (speed gate), GPS drift (exit radius + two consecutive fixes), dead zones (garage: not supported; copy says street parking only). After 15 min with no departure the pass expires silently. A mistaken ping costs the seeker one glance at the car; the seeker's "Didn't work out" sends no signal to the driver.
- Battery: region monitoring is the low-power API; only armed for at most 15 min; disarmed on depart/cancel/expire. No continuous GPS.

## 6. SAFETY AND PRIVACY (non-negotiable)

Threat: "notify a stranger when this car leaves" can reveal when someone leaves home, or help stalking. Controls:

1. **Explicit opt-in per handoff by the car owner.** Nothing is armed until the driver taps Confirm on the explicit screen ("A neighbor will be told when you pull out. That's all they will know."). No default-on, no standing permission, no "always notify X".
2. **Short expiry.** Seeker pass 20 min; armed 15 min; one-time. No persistent tokens in MVP (printable cards deferred, 6.7).
3. **Driver can cancel anytime**, silently (the seeker is not told who/why; the pass just expires).
4. **No identity shared.** Seeker sees: nothing about the driver. Driver sees: a generic alias card ("a neighbor"), never username, karma name, or photo. Server stores only an anonymous claimer nonce, deleted with the row (24 h purge).
5. **The ping carries no location.** Payload text only: "Spot Pass: your neighbor is pulling out now." No address, block, side, car, or coordinates. Decision: not even the address. Rationale: the seeker met the driver in person (they scanned the seeker's screen), so the seeker already knows which car; adding any server-known location would make the pipeline able to leak one. Phase 1 address feature (`address-anchored-parking.md`) is explicitly NOT wired to this. If the seeker later wants "which spot", they look at who scanned; Kevin can revisit.
6. **No tracking after departure.** The depart call terminates monitoring; the row stores no location ever; region is on-device only and removed on any terminal state. No location history is collected for this feature.
7. **Anti-stalking structure.** A watcher cannot subscribe to a target car: the code is created by the person who gets the ping and must be physically scanned by the driver's phone with a confirm tap. Risk: social-engineering a victim into scanning a code left on their windshield. Mitigations: the scan screen only says what will happen and requires the tap; ping contents reveal only "now leaving" for a 15-minute window the victim started; the victim can cancel; seeker passes are 20-min and die when the seeker parks. Printable static codes would widen this surface, so they are deferred until a "pass is only live while the seeker toggles it on" design is reviewed.
8. **Rate limits** (server, per seeker and per anon claimer/IP): seeker max 3 passes/hour, 10/day, 1 active; claim attempts max 10/hour per IP; pass creation blocked if the seeker has 3 unresolved reports.
9. **Abuse reporting.** Landing page and the seeker ping screen both have "Report this pass"; stored in `handoff_reports`; 3 reports on a seeker suspends creation (`suspended`) pending Kevin's review. Block-seeker: driver page "Don't show me passes from this neighbor" is stored client-side only (no identity).
10. **Security basics.** Token 128-bit random, hash-at-rest, constant-time compare, fragment-only in the URL, `Referrer-Policy: no-referrer`; edge functions return identical responses for invalid/expired/used tokens (no oracle); APNs payload has no PII; CORS limited to the Pages origin; kill switch env `HANDOFF_ENABLED` on the edge functions in addition to the app flag.
11. **Privacy policy/App Store**: add a Spot Pass section (what is shared: a one-bit "leaving now" event; retained 24 h). Anonymous account model unchanged (`docs/privacy-policy.md`).

## 7. Karma

Reuses the existing reputation system: `profiles.reputation`, `helped_count`, idempotent append-only `reputation_award_log` keyed uniquely per event (`supabase/03-community-2.0-schema.sql`, spec section 2.6; confirm awards +2/+5/+1). Concept language: "Good Neighbor", "You've helped 41 neighbors park" (`docs/nyc-neighbors-incentives-concept.md` section 4).
Proposed (Kevin may retune):
- **Driver (helper)** +5 reputation and `helped_count` +1 when the seeker confirms "Got the spot". (Only possible for drivers with accounts: anon web drivers do have an anonymous Supabase uid via the page; if the page is used without auth, no karma accrues, and that is fine. Phase 2: "Open in WePark to claim your karma" is the install hook.)
- **Seeker** +1 when they confirm the outcome either way (rewards closing the loop), +2 extra on "Got the spot" (thank-you).
- Kindness badge counters: "Spots passed" (driver), "Spots caught" (seeker); neighborhood "Mayor of Mott St" later (concept doc).
Anti-gaming:
- Karma only on seeker-confirmed outcome from a different user (seeker id != claimer id; claimer nonce != any device token of the seeker).
- Caps: 3 rewarded handoffs per user per day; same seeker/claimer pair earns once per 24 h; ledger unique key `(handoff_id, role)`.
- Self-scan: rejected if claimer shares the seeker's device token or auth uid; scanning your own code from the same phone shows "That's your own pass".
- Farming rings (two friends alternating) is the known risk (see `docs/regulars-network-spec.md:876-888` watch-list); daily caps plus pair cooldown bound it; add to Kevin's post-launch watch-list.
- Consistent with concept doc section 6: karma is points only, not redeemable cash, since open-spot events are cheap to fake. Keep this OUT of any rewards-dollars economy until verification exists.
- Phase 2 verification boost: auto-detected departure (region exit + speed) upgrades the driver award to the full amount without needing seeker confirmation as the only source of truth.

## 8. "Sexy and fun" brief for @designer

Goal: the Spot Pass is a WePark-branded neighbor badge, not a bare QR square. A person should WANT to show it; a driver should smile and scan.
- Tone: warm, NYC, good neighbors helping with parking. Playful copy ("Pass the spot", "Heading out? Make a neighbor's day", "Spot's yours, neighbor"). Never begging or transactional; no money.
- Form: a pass/ticket card: WePark mark, a fun neighbor alias + glyph (generated per pass, rotates; e.g. "Bodega Cat", "Stoop Sitter"; unlinked to the username), the karma tier chip ("Good Neighbor . 41 spots shared"), a short line ("Looking for a spot near you"), and the QR as the hero with a branded quiet-zone treatment (rounded modules, WePark color, center logo) that stays reliably scannable.
- Scannability (hard requirements): must scan from the plain iOS camera at 1-1.5 m through a windshield on a phone mount in glare; QR module size and quiet zone at spec; no gradients that reduce contrast below 7:1 between dark/light modules; test through a tinted windshield; auto-max brightness while shown; landscape and portrait.
- Modes: full-screen "show to a neighbor" (primary, on-screen), a compact card inside the map sheet, and a share image. Printable dash card: design the artwork now, ship later (token issue in 6.7).
- Live feedback: countdown ring (20 min), pulse when armed ("A neighbor scanned"), celebratory micro-moment on the ping and on "Got the spot" (confetti, haptic), karma +N animation. Respect Reduce Motion and larger text; touch targets large (Kevin prefers big buttons; drive-mode surfaces roomy).
- What the scanner sees (`handoff.html`): same visual language; headline "A neighbor is hoping for your spot"; three lines of reassurance (not who you are, not where you are, only "leaving now"); big [I'm leaving now] and [Not now]; small "Report" and "Get WePark" links; success screen "Thanks, neighbor" with a karma teaser for app users.
- Seeker ping: lock-screen alert title "Spot Pass" body "Your neighbor is pulling out now" (no location), custom sound optional.
- Deliverables to `docs/design/`: card in light/dark, AX5, VoiceOver labels, landing page mocks, alias/glyph set, QR contrast test results.

## 9. Work streams

| # | Stream | Owner | Depends on | Parallel? |
|---|---|---|---|---|
| A | Migration 13 + RPCs + RLS + test script; extend account deletion; ledger awards | @backend-data | none | yes |
| B | Edge functions `handoff-claim`, `handoff-depart`, `send-handoff-push` | @backend-data | A shape (agree the RPC contract in this spec first) | after A's contract, parallel with C/D/E |
| C | Seeker flow in iOS: create, QR render, countdown, ping handling, outcome, karma display, deep link, flag | @ios-engineer | contract only (can use a fake service protocol before backend lands) | yes |
| D | `handoff.html` driver landing | @pwa-maintainer | contract only | yes |
| E | Design brief to mocks and assets, brand pass | @designer | none | yes, feeds C/D polish |
| F | QA: backend script, device pass, scan-through-windshield test, safety checklist | @qa-verifier | A-D | after |
| G | Privacy-policy section | Tech Lead doc | none | yes |
API contract (so C, D can build against fakes): `create_handoff() -> {id, token, expires_at}`; `POST handoff-claim {token} -> {status:"armed", expires_at} | {status:"unavailable"}`; `POST handoff-depart {token} -> {ok:true}|{ok:false}`; `cancel_handoff(id)`; `confirm_handoff_outcome(id, outcome)`. Errors are identical for bad/expired/used tokens.
Conflict avoidance: backend touches only `supabase/**`; iOS only new files under `Views/SpotPass/` and `Services/SpotHandoffService.swift` plus flag + one entry point + AppDelegate push branch; PWA only `handoff.html`. Merge order is free; Kevin applies SQL and deploys functions before device QA.

## 10. Phasing
- **Phase 1 (MVP)**: seeker flow, web-page driver, manual depart, alert push, karma via seeker confirmation, safety controls 1-11. Flags: `AppConstants.spotHandoffEnabled = false` (iOS) and `HANDOFF_ENABLED` (edge functions).
- **Phase 2**: domain + App Clip + Universal Links; in-app driver flow with auto-detect (Always, region + speed gate); Time Sensitive; symmetric driver-created pass for app-installed waiters; printable dash card with live toggle.
- **Phase 3**: neighborhood leaderboards / "Mayor of" tie-in, sponsor-locked rewards (only with verification).

## 11. Acceptance criteria
- [ ] Flags off: app and PWA behavior unchanged; edge functions return disabled.
- [ ] Seeker creates a pass; QR scans from the iOS camera at 1.5 m through a tinted windshield on a mounted phone, portrait and landscape, in daylight.
- [ ] Scan -> confirm -> "I'm leaving now" -> seeker device receives an alert push within 10 s on production APNs (TestFlight build) and sandbox (debug build).
- [ ] A second scan of the same pass shows "already used"; expired, used, invalid tokens return indistinguishable responses.
- [ ] Pass expires at 20 min unclaimed and 15 min armed; expired passes cannot depart; purge job removes rows after 24 h.
- [ ] Seeker cancel and driver cancel work; driver cancel sends nothing to the seeker.
- [ ] Seeker parking (saving a car) cancels the active pass.
- [ ] Push payload and DB rows contain no location, address, plate, username, or device identifiers beyond the APNs token; verified by inspecting payload and table dump.
- [ ] Rate limits: 4th pass in an hour rejected; claim brute force limited; 3 reports suspend creation.
- [ ] Self-scan (same account / same device) rejected; karma awarded only on seeker-confirmed outcome from a different user; caps (3/day, pair cooldown) enforced; duplicate confirm is idempotent (ledger unique key).
- [ ] Account deletion removes the user's handoff rows and reports.
- [ ] Notification permission denied: seeker sees clear in-app state ("Turn on notifications to get the ping") and the create button explains why it is limited.
- [ ] VoiceOver for the pass card (label includes expiry), the ping, and the confirm screen; AX5 layout; Reduce Motion respected; big touch targets.
- [ ] Landing page works on iOS Safari with no install and no cookies; no third-party scripts; `Referrer-Policy: no-referrer`.
- [ ] Safety checklist in section 6 walked item by item by @qa-verifier.

## 12. Test plan
- Backend script (pattern `supabase/04-community-push-test.sh`): state machine, atomic single claim under concurrent calls, expiry via manipulated clock columns, RLS (seeker sees own status only; others nothing), rate limits, ledger idempotency, cascade on account deletion. Kevin applies the SQL; QA runs against staging/production with throwaway users.
- Unit (iOS): service protocol fake for each state; countdown/expiry logic; karma display; deep-link parsing; push handler routes handoff alerts and ignores others (does not disturb the silent community/regular push path).
- Device: real push on TestFlight, scan tests (windshield, glare, dark mode, brightness), airplane-mode failure copy, permission-denied path.
- Phase 2 only: region exit false-positive drive tests (walk away, GPS drift near buildings, garage).

## 13. Out-of-scope follow-ups
- Auto-detect: needs Always permission and review justification; manual satisfies the ask now.
- Printable dash card: static tokens widen the abuse surface; revisit with live-toggle design.
- App Clip and Universal Links: need a domain and Clip target.
- Sharing the address or block in the ping: rejected for MVP on privacy grounds; revisit only with an explicit per-pass opt-in.
- Rewards-dollars for handoffs: fraud magnet until departures are verified (concept doc section 6).
- Garage/off-street handoffs: no region signal; out.
