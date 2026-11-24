# QR "Spot Pass" (neighbor handoff ping)

Status: DRAFT for Kevin. Author: Tech Lead.
**Revision 2 — 2026-11-23** (Revision 1 was committed to `main` earlier the same day; its git history is the record of the original. Nothing is deleted from it in spirit: sections that did not change are condensed, not dropped.)

Inputs: Kevin 2026-11-23 (verbatim: "the lowest barrier to entry quick action should be a QR code that you allow someone to scan that will notify the owner of the QR code when your car leaves that spot ... make that code sexy though and fun ... good neighbors ... building karma"; then "how close can we get to auto without having auto"; "I really like the lock screen tap reminder idea"; "we are attempting to onboard people through this process as well. Let's think how can we make that an incredible first impression on the app."), `docs/nyc-neighbors-incentives-concept.md` (karma/Good Neighbor layers, section 6 "reward verifiable + durable, not fleeting open spots"), `docs/community-2.0-reconciliation-spec.md` section 2.6 (reputation), `docs/design/first-run-onboarding-design.md`, `docs/specs/address-anchored-parking.md` (address is NOT wired to this), `supabase/send-community-push` (APNs pipeline).

Working name: **Spot Pass** ("Pass the spot."). Final name is @designer's call.

## Revision 2 changelog

| # | Change | Why |
|---|---|---|
| 1 | **App Clip promoted from Phase 2 into the MVP**, with a domain Kevin owns (Universal Links, `appclips:` association, AASA). Static web page stays as the fallback. | The lock-screen Live Activity and reminders (steps 3-4 of Kevin's direction) and the thank-you payoff are impossible on a plain web page. See section 5 for verified facts. |
| 2 | **Lock-screen Live Activity with countdown and a one-tap "Leaving now" is the centerpiece** of the driver experience. | Kevin: "I really like the lock screen tap reminder idea." Section 7.2. |
| 3 | **Driver picks a leaving time** (now / 10 / 30 / 60 min / pick a time, cap 4 h); **pass expiry = leaving time + 15 min grace**, no longer a flat 15 min. | The scan can happen well before departure. Section 3. |
| 4 | **Local, actionable reminder notification** at the chosen time (Leaving now / 5 more min / Not leaving). | Section 7.3. |
| 5 | **Armed-window auto-detect for app-user drivers, no Always permission** (When In Use + `location` background mode + `CLBackgroundActivitySession`). Replaces the Phase 2 "Always + region monitoring" design. "Start Driving in WePark" also sends the ping. | Closest thing to auto with no Always prompt. Section 7.4. |
| 6 | **Optional fully-auto path** via an App Intent + a user-built Shortcuts "CarPlay/Bluetooth connects" automation. Honest note: it cannot be one-tap installed. | Section 7.5. |
| 7 | **New section 6: First impression & onboarding funnel**, composed with the existing first-run onboarding (keys, sentinels, flags). | Kevin's onboarding direction. |
| 8 | **Seeker's "Got it, thanks!" sends the driver a thank-you** (one bit, positive outcomes only). | Reciprocity hook, section 6.1 beat 4. |
| 9 | **Hardening:** per-claim secret for depart/extend/cancel (the QR token alone can no longer depart a pass), peek endpoint, push/activity tokens nulled at terminal state. | Longer pass life + a QR visible through a windshield (photographable). Section 8, 9. |
| 10 | MVP vs Phase 2 split, work streams, acceptance criteria, test plan, designer brief, and open decisions all revised. | |

## 0. Decisions for Kevin (read first; only the vital ones)

Direction (waiter owns the QR, leaving driver scans, consent is the scan) is unchanged and is now treated as confirmed by Kevin's follow-ups. Adopted without re-asking: App Clip in the MVP; plain QR (not an App Clip Code); karma defaults in section 10.

1. **Buy a domain (blocks all real App Clip testing beyond a local experience).** Needed for Universal Links, the `appclips:` association and the AASA file. Recommendation: a short domain (a short URL makes a smaller, more windshield-scannable QR). I will use `<domain>` as a placeholder. Hosting stays GitHub Pages with a custom domain (CNAME) unless the AASA content-type/dotfile gotchas in section 5.5 bite, in which case Cloudflare Pages. Kevin's steps are in section 5.5.
2. **Name policy on the pass.** Your example copy was "Maya's waiting for your spot". Revision 1's safety rule 4 says the driver never sees a username. Recommendation: **default = the generated neighbor alias** ("Bodega Cat is waiting for your spot"), plus an **opt-in per-seeker toggle "Show my first name on my pass"** (default off, stored on the pass row only, 24 h purge). Say yes and "Maya" works for those who choose it.
3. **Auto-detect adds the `location` background mode to the app binary.** This is a build-level capability (App Review and a stronger purpose string), not just a flag. It is window-limited and When In Use only (no Always). Recommendation: build it as the LAST MVP stream behind its own flag (`spotHandoffAutoDetectEnabled`) so the rest of the MVP ships and passes TestFlight/App Review even if auto-detect slips or needs a rework. Confirm you are comfortable carrying that review exposure.
4. **Leaving-time horizon cap = 4 hours.** App Clips only get ephemeral notifications for up to 8 h after each launch (section 5.2); 4 h leaves margin. "I'm leaving at 8am" scanned at 10pm is out of the MVP (full-app drivers could do it in Phase 2 with a local notification, which has no such limit). Recommendation: accept.

## 1. Problem and user story

NYC street parking: someone circles; someone else is walking to their car. They never connect.

Seeker: I tap "Looking for a spot" and a Spot Pass card (QR) shows on my phone in the mount. A driver walking to a car sees it, scans with the camera, picks "leaving in about 10 min", and I get a ping the moment they pull out. Both of us earn Good Neighbor karma and the driver gets a thank-you when I take the spot.

Driver, who is often a **non-user meeting WePark for the first time**: I scan, a card appears instantly, "Bodega Cat is waiting for your spot", I tap once, my lock screen shows a countdown with a "Leaving now" button, I tap it as I pull out, and a few minutes later I get "Bodega Cat got your spot. Thanks, neighbor!" That is the entire product pitch delivered in four minutes with no sign-up.

## 2. Scope

**In (MVP):**
- Seeker: create pass, full-screen QR, live state (open, armed with a rounded "leaving in about N min", departed), outcome ("Got it, thanks!" / "Didn't work out"), karma.
- **Driver, app clip (non-user, or user without the app installed):** invocation from the iOS camera on a plain QR, instant card, leaving-time chips, arm, Live Activity countdown, ephemeral reminder notification, "I'm pulling out" button, celebration, thank-you, install CTA (section 6).
- **Driver, full app (user):** the same flow handled by the full app (it replaces the clip and must handle the invocation URL), plus interactive Live Activity button, actionable reminder buttons, "Start Driving sends the ping", the `LeavingNowIntent` App Intent, and the armed-window auto-detect (last stream).
- **Static web fallback** (`handoff.html` on the same domain) for devices/situations where the clip cannot run.
- First-run composition (section 6.3): clip-origin tailored Welcome.
- Server: table, RPCs, edge functions (peek, claim, depart, extend, cancel), push kinds, expiry, one-time use, rate limits, report. Karma through the existing idempotent ledger.
- Designer deliverables (section 11).

**Out (deferred, section 13):** always-on/standing passes; Always location; region monitoring; printable dash card; driver-created pass scanned by waiter; chat/ETA/maps/photos/live location (never); rewards dollars; Android; leaving horizon beyond 4 h; CoreMotion automotive signal; seeker-side Live Activity; Time Sensitive interruption level.

## 3. Core flow and states

Single entity `spot_handoffs`. States:
`created` (seeker made it, TTL 20 min unclaimed) -> `armed` (driver scanned and chose a leaving time; `leave_at`, `expires_at = leave_at + grace`) -> `departed` (ping sent; terminal). Other terminals: `expired`, `cancelled`, `suspended`. (`departing` from Rev 1 is dropped; departure is one atomic transition.)

- **One-time use:** `created -> armed` exactly once (atomic `update ... where status='created'`). A second scan sees "This pass was already used". One active pass per seeker.
- **Leaving time:** driver chooses a bucket (now, ~10, ~30, ~60 min) or a time up to `HANDOFF_MAX_HORIZON_MIN = 240` from now. Stored as `leave_at` rounded to 5 min. **`expires_at = leave_at + 15 min` grace** (`HANDOFF_GRACE_MIN`). "5 more min" in the reminder moves `leave_at` by +5 (max 3 extensions, never past the horizon measured from claim).
- **What the seeker sees:** a coarse relative line, "Leaving in about 30 min", never a clock time, never "driver is walking to car". Copy states it is a courtesy, not a promise. The seeker can "Stop waiting" at any time (releases the pass locally and cancels it; driver gets nothing).
- **Driver cancel / "Not leaving"** is silent to the seeker (no signal about the driver's behavior; no pressure). The seeker's wait is bounded by the countdown they can see plus 15 min; at expiry the pass shows "Pass ended" with no reason.
- **Seeker auto-ends** when the seeker parks (ParkPinService saves a car) or drive mode ends: `cancel_handoff`. A silent push (`handoff_ended`) tells a full-app driver to close the auto-detect window and Live Activity; clip drivers' Live Activity ends on its own stale/expiry rules.
- Server cron purges rows older than 24 h (pattern: `supabase/02d-ingest-cron.sql`). Claimer push/activity tokens and the claimer secret hash are nulled **at the terminal transition**, not at purge.

Sequence (MVP):
1. Seeker taps "Spot Pass" -> `create_handoff()` returns `{id, token, alias, glyph, expires_at}` (token 128-bit random, only its hash stored). QR encodes `https://<domain>/p#t=<token>` (22 base64url chars; whole URL about 40 chars = a low-density QR, good for scanning through glass). Fragment keeps the token out of server logs for the web fallback; the clip reads it from the invocation URL (engineer must verify the fragment survives into `NSUserActivity.webpageURL`; fallback is `?t=`, section 5.5).
2. Driver scans with the camera. Installed full app: Universal Link opens it. Otherwise: App Clip card -> Open -> clip. No clip available: Safari opens the static fallback page.
3. Clip/app calls `handoff-peek {token}` (read-only, no state change) to render "Bodega Cat is waiting for your spot", then the driver picks a leaving time and taps the big CTA -> `handoff-claim` arms it and returns a `claimer_secret`.
4. Live Activity starts; reminder notification is scheduled; (full app) auto-detect window may open.
5. Departure signal: lock-screen/notification "Leaving now", in-app "I'm pulling out", Start Driving, auto-detect, or the Shortcut -> `handoff-depart` -> row `departed` -> `send-handoff-push` kind `departed` to the seeker.
6. Seeker: "Spot opening up. Your neighbor is pulling out now." [Got it, thanks!] [Didn't work out]. "Got it, thanks!" -> `confirm_handoff_outcome` -> `send-handoff-push` kind `thanks` to the driver, and karma.

## 4. What works where (driver-side capability matrix)

Verified against Apple docs in section 5.1 unless marked "device test".

| Capability | Static web page | App Clip | Full app |
|---|---|---|---|
| Instant, no install | yes | yes (card, then clip) | n/a |
| Choose leaving time, arm pass | yes | yes | yes |
| Local scheduled reminder | no | yes, **ephemeral, up to 8 h after each launch**, user can switch it off on the card | yes (normal permission) |
| Remote push to driver (thank-you) | no | yes, within the same ephemeral window; payload needs a `target-content-id` URL | yes |
| Live Activity (countdown) | no | **yes**, via a Live-Activity-only widget extension in the clip target | yes |
| Interactive "Leaving now" button on the Live Activity | no | **assume NO**: the App Intents framework "provides no functionality at runtime" in clips. Fallback: the activity deep-links into the clip's big "I'm pulling out" screen (2 taps). Device test whether `Button(intent:)` happens to work | **yes** (iOS 17 `LiveActivityIntent`) |
| Action buttons on the reminder notification that send without opening the app | no | **device test**; clips cannot do background activity, so assume the action opens the clip | yes |
| Auto-detect departure | no | **no** (no background activity/Background Modes, no continuous location, no CoreMotion, no Always) | yes (last stream) |
| Shortcuts / car-connect automation | no | no (App Intents inert) | yes |
| Start Driving sends the ping | no | no | yes |
| Karma carries over | n/a | anonymous identity stored for the full app | native |

Product truth to accept: **the true one-tap lock-screen button is a full-app capability.** For clip drivers it is lock screen -> tap -> big button (still the fastest honest path). That makes the install CTA after the payoff (section 6.1 beat 5) the natural upsell: "Next time, one tap from your lock screen."

## 5. App Clip: verified facts, decisions, and Kevin's setup

### 5.1 Facts (all from Apple documentation; sources listed at the end)

- **Size.** Uncompressed App Clip binary: 15 MB for iOS 16 and earlier. From iOS 17 up to 100 MB **only if** the clip supports digital invocations only (no App Clip Codes, QR codes, or NFC), people usually have a reliable connection, and it does not support iOS 16-. The App Store Connect demo link also allows 100 MB with physical invocations but cannot carry URL parameters (we need the token), so it is not usable. Apple's table currently also shows a 25 MB row for a future OS (labelled iOS 27.3 and later; treat as unconfirmed). The WWDC23 session describes 50 MB for digital invocations on iOS 17. **Our clip is invoked by QR (a physical invocation), so budget against 15 MB, target at most 10 MB**, with margin (an Apple engineer advised leaving margin; a 14.9 MB clip became unavailable on some devices).
- **Notifications.** With `NSAppClip > NSAppClipRequestEphemeralUserNotification = YES`, the clip can **schedule or receive notifications for up to 8 hours after each launch without a permission prompt**. The card shows a note and the user may switch it off, so code must check `authorizationStatus == .ephemeral`. Returning from a notification launches the clip **without an invocation URL**: persist state. Remote payloads need a `target-content-id` URL matching a registered experience.
- **Location.** Clips cannot request continuous (Always) location; `requestWhenInUseAuthorization()` works and **resets automatically the next day at 4:00 a.m.** `requestAlwaysAuthorization` in a clip fails upload validation (ITMS-90842, developer-forum report). `NSAppClipRequestLocationConfirmation` exists for confirming the user is at a registered place; we do not use it (our places are moving cars).
- **Background.** "App Clips can't perform background activity": no background networking, no Background Modes capability functionality, no BackgroundTasks. CoreMotion and AppIntents "provide no functionality at runtime". Clips cannot include app extensions **except** a widget extension that offers **Live Activities only** (needs the App Clip Extension capability and a bundle id prefixed by the clip's).
- **Live Activities.** Start from the foreground with `Activity.request`; up to 8 h active, up to 12 h on the lock screen; 4 KB data; the activity itself has no network or location; update via ActivityKit or ActivityKit push. Interactive buttons use App Intents (section 4 caveat for clips).
- **Data handoff to the full app.** When the user installs the app, **the full app replaces the clip and receives all invocations**; the full app must handle every invocation URL and provide the clip's functionality (also App Review guideline 2.5.16: all clip functionality must be in the main binary). Share data through an **App Group** container / shared `UserDefaults` (both targets), and the **keychain** (clip items are readable by the full app from iOS 15.4, use distinct `kSecAttrLabel`). Clips cannot use iCloud KVS or private CloudKit; clips cannot read the full app's keychain items. Store only anonymized identifiers, never passwords.
- **Invocations.** Camera/Code Scanner on QR codes, NFC, App Clip Codes, Messages links, Safari banner, etc. QR codes work with every experience type, including the default experience. Advanced experiences support URL parameters and prefix matching (register `https://<domain>/p` once, any `/p#t=...` or `/p?t=...` matches).
- **Default vs advanced.** A **default App Clip experience is required** (header image, subtitle, CTA verb). The default link is `https://appclip.apple.com/id?=<bundle_id>&key=value`: it supports QR but cannot be used for App Clip Codes. An **advanced experience** is needed for custom-domain invocations, Maps, App Clip Codes, and iOS 16.3-. Card title is at most 30 characters, subtitle at most 56, and **the card is static; it cannot be personalized per scan**, so per-pass personalization ("Bodega Cat is waiting") happens in the clip's first screen, not the card.
- **App Clip Code vs plain QR.** App Clip Codes always use Apple's own visual design (colors only), are generated offline by App Store Connect or Apple's CLI tool, and encode a URL of limited length (UUIDs compress badly). **A per-pass, runtime-generated token cannot be an App Clip Code.** A **plain QR code encoding an associated URL does trigger the App Clip** from the iOS camera. **A custom branded QR design still triggers it**: the clip is triggered by the decoded URL, not the artwork, as long as the code decodes reliably (high-contrast modules, quiet zone, error-correction headroom for a center logo). Decision: **plain, branded QR**, never an App Clip Code. (Corollary: the camera shows the generic Apple App Clip card, not our design, so the first branded moment is the clip's first screen.)
- **Testing and release.** Local experiences (Settings > Developer > Local Experiences) test QR scans and the card **without a domain or AASA** and launch clips signed for Development/Ad Hoc/TestFlight. **TestFlight experiences** (up to 3 per build) require the domain association, and **the App Clip card does not appear in TestFlight**; testers launch from the TestFlight app. **Real strangers can only scan into the clip after the app (with the clip) is released on the App Store.** Default/demo links also require App Store release. Pre-release, the static web fallback is the only stranger path, which is why stream D stays MVP-critical.
- **App Review / background location (full app).** Guideline 2.5.4 lists location as a legitimate background service; 5.1.5 requires location to be directly relevant, with consent and an in-app purpose explanation. `CLBackgroundActivitySession` (iOS 17) lets a When In Use app keep receiving location in the background with the **blue status-bar pill**; you must create and hold it (WWDC23 "Discover streamlined location updates"). Review exposure: a new `UIBackgroundModes = location` entry (today only `remote-notification`, per Rev 1 section 5.3) needs a clear purpose string, in-app disclosure and reviewer notes with a demo; it is the one MVP piece with real rejection risk, hence section 0 decision 3.
- **Shortcuts.** Personal automations triggered by CarPlay or a Bluetooth device "Is Connected" can be set to run without asking (current Apple guidance: Ask Before Running off; older pages said Bluetooth always prompted, so device-verify). Automations are per-device and **cannot be created or imported programmatically or via a shared link**: the app can only guide the user.

### 5.2 Constraints this puts on the design (the sharp edges)

1. Clip reminders exist only within 8 h of the last launch: horizon cap 4 h.
2. Clip location is foreground-only and expires at 4 a.m.: the "your block" value moment (6.1 beat 2) is a foreground tap, once.
3. The clip cannot ship the 32 MB bundled `tiles/` (`HANDOFF.md`): the block card fetches the **single** tile for the coordinate from the hosted tile set (avg about 29 KB; same files the PWA already serves, ideally also served from `<domain>`), computes rules on-device with a small shared rule evaluator. Only a coarse tile id leaves the device.
4. Clip Live Activity button likely inert: design the 2-tap fallback as a first-class design, not a patch.
5. Clip pushes use the clip's own APNs topic (`com.kevinhoxha.wepark.Clip`), not the app's; ActivityKit pushes use `<bundle id>.push-type.liveactivity`. Backend must send to the right topic per token (`claimer_topic` stored with the token).
6. Everything the clip does must also exist in the full app (guideline 2.5.16): share code via a common source folder compiled into both targets.

### 5.3 Default and advanced experiences we register

- Default experience: header image, title "Pass the spot" (13), subtitle "Tell a neighbor when you're leaving" (35), CTA "Open". Invocation URL `https://<domain>/p`.
- One advanced experience: `https://<domain>/p` (prefix matching covers every pass token). No App Clip Code, no per-location experiences, no Maps association.
- Both the clip and the full app handle `https://<domain>/p` with and without a token (generic landing: "Looking for a spot? Open WePark and tap Spot Pass").

### 5.4 Fallback matrix

| Situation | Behavior |
|---|---|
| iPhone, clip available | Camera card -> clip |
| iPhone with full app | Universal Link opens full app (in-app driver flow; auto-detect available) |
| Clip cannot run (iOS below clip minimum, App Clips disabled in Settings, card dismissed, airplane-mode failure to fetch the clip, pre-App-Store-release) | Safari opens the static page `https://<domain>/p`: manual "I'm leaving now" only, plus "Get WePark" smart-banner |
| Non-iPhone camera | Static page |

### 5.5 What Kevin must do (checklist; engineers cannot do these)

1. **Buy the domain** (registrar of choice) and point DNS: for GitHub Pages with a custom domain, an apex `A`/`AAAA` set or a `CNAME` for the subdomain, then enter the domain in the repo's Pages settings and enable "Enforce HTTPS". (If AASA serving problems appear, move to Cloudflare Pages/Netlify; no code change.)
2. In the Apple Developer portal: confirm **Associated Domains** and **App Groups** capabilities for `com.kevinhoxha.wepark`, and create the clip App ID `com.kevinhoxha.wepark.Clip` and the clip's widget-extension App ID (`com.kevinhoxha.wepark.Clip.liveactivities` or similar) and the app group id (suggested `group.com.kevinhoxha.wepark.shared`; the entitlements file today has no app group). Xcode automatic signing can create most of this once the targets exist.
3. **Publish the AASA** at `https://<domain>/.well-known/apple-app-site-association` with the `appclips` block (`apps: ["ZAA4UCS6CH.com.kevinhoxha.wepark.Clip"]`) and `applinks`/`webcredentials` for the app. Requirements per Apple: HTTPS, no redirects, valid JSON, allow the `AASA-Bot` and `CFNetwork` user agents. GitHub Pages gotchas: without an empty `.nojekyll` file the `.well-known` folder is not served, and the extensionless file may get a non-JSON content type; confirm both. Backend/PWA agent writes the file; Kevin verifies in App Store Connect ("View Status" / "Load Debug Status").
4. In **App Store Connect** (after the first build containing the clip is uploaded): create the **default App Clip experience** (header image from @designer, title, subtitle, CTA) and the **advanced experience** for `https://<domain>/p`; for TestFlight add up to 3 testing experiences; on device use Settings > Developer > Diagnostics and "Clear Experience Cache" after changes.
5. For stranger-facing launch: release the app version containing the clip on the App Store (App Review covers the clip).
6. Update the privacy policy / App Privacy answers (Kevin owns the submission; section 9 item 11 has the content).

## 6. First impression & onboarding funnel

Goal: the driver's four minutes with us is the best product demo we have. They arrive with no context, do a good deed, and leave wanting the app. Design rules: **one screen at a time, human words, nothing asked before value is delivered, every ask is earned.**

### 6.1 The arc (refined)

**Beat 0: the scan.** The camera shows Apple's card (static; our copy is "Pass the spot" / "Tell a neighbor when you're leaving", CTA "Open"). Nothing we can personalize; keep it warm and short.

**Beat 1: instant, human, one decision.** Clip opens on a branded full-bleed screen; the alias and glyph come from `handoff-peek` (skeleton for under 1 s; if the network is slow show the generic copy first and swap in the alias, never block). Headline "Bodega Cat is waiting for your spot" (or the opted-in first name), subline "Leaving soon? Let them know with one tap. They won't see who you are or where you are." Leaving-in chips (Now / ~10 min / ~30 min / ~1 hr / Pick a time) with **~10 min preselected**, then one big CTA **"Ping Bodega Cat when I leave"** (CTA text updates with the chip). Large touch targets (Kevin's standing preference). No sign-in, no notification prompt (the ephemeral permission is already on the card), no location prompt before this tap. Tapping the CTA arms the pass and starts the Live Activity.

**Beat 2: immediate personal value, with the ask earned.** Right after arming, the same screen shows a quiet card: **"Want to know what the rules are on this block? [Show me]"**. Refinement of your "zero ask": this single, explained tap triggers the standard When In Use prompt (clip location resets at 4 a.m.), then fetches the one hosted tile for that spot and renders, from WePark's real data, a true useful line about the block they are standing on: "Street cleaning on this side: next Tuesday 8:00-9:30 am" plus the green/red status in plain words. If they decline, nothing is lost and nothing nags. This proves the core product ("the map does the thinking", `first-run-onboarding-design.md` section 1) in context, and it is the first permission the person has reason to grant. Copy must say "this block" (not "where you're parked": we do not know where their car is). Reuse the existing `ParkingRule` evaluator and curb snapping logic via the shared source folder; **no map view in the clip** (size).

**Beat 3: the lock-screen countdown.** The Live Activity (countdown ring, "Leaving in 9:42", and "Leaving now") is the centerpiece. App users: a real one-tap button. Clip users: tapping it deep-links into the clip's big **"I'm pulling out"** screen (two taps, still lock screen to sent in a few seconds). The reminder notification fires at the chosen time with Leaving now / 5 more min / Not leaving.

**Beat 4: payoff.** On departure: a celebration moment ("You just passed a spot. A neighbor is pulling in because of you.", haptic, confetti under Reduce Motion rules) with **karma shown as pending until the seeker confirms** ("+5 karma when they get it", never a promise of points that do not exist). When the seeker taps **"Got it, thanks!"** the driver receives a thank-you (Live Activity final update, or the ephemeral push if within window): "Bodega Cat got your spot. Thanks, neighbor!" and karma becomes real. If the 8 h window has lapsed (clip), the thank-you and karma wait for the next launch of the app (App Group payload / server state).

**Beat 5: the install ask, at peak emotion.** Never before the payoff. After the celebration and again with the thank-you, show the clip's install overlay: **"Keep your karma, and get a heads-up when a spot opens near you."** Secondary line for the interesting reason: "Next time, leave from your lock screen in one tap." Dismissible, never repeated within the session.

### 6.2 Carry-over: clip to full app

- **Identity.** The clip does an anonymous Supabase sign-in (same mechanism the full app uses for its anonymous account today; engineer confirms) at claim time. The session's refresh token goes in the keychain with a distinct `kSecAttrLabel` (`wepark-appclip`), and a small non-sensitive payload goes to the shared App Group `UserDefaults`:
  `clipHandoffContext = { v:1, userId, firstPassAt, passesHelped, passesPendingKarma, lastAlias, origin:"clip" }`.
  Never store passwords or the claimer secret in shared defaults (Apple guidance: only anonymized identifiers).
- **Adoption.** On first full-app launch the app reads the context; if the full app has **no** existing session it adopts the clip's (karma, `helped_count` and the good deed carry over because they live server-side on that uid). If it already has a session (rare: reinstall, or a user who used the clip before signing in), MVP leaves the clip identity as is and shows no tailored welcome; a `merge_anon_identity` RPC is Phase 2.
- Pending karma settles server-side on seeker confirmation regardless of whether the app was installed in the meantime.

### 6.3 Composition with the existing first-run onboarding

Existing pieces (`docs/design/first-run-onboarding-design.md`): Tier 1 `OnboardingStoryView` (3 cards), Tier 2 `LocationPrimingCard` (only if `.notDetermined`, after Tier 1), Tier 3 coach marks; keys `hasSeenOnboardingStory`, `hasSeenOnboardingCoach`, sentinel `hasLaunchedWeParkBefore`, flag `onboardingStoryEnabled` AND-ed with `driveModeDefaultEnabled`; story cards never request a permission (section 4.3 invariant, kept).

| Launch type | Detected by | Experience |
|---|---|---|
| Organic fresh install | `hasLaunchedWeParkBefore == false`, no clip context | Unchanged: story deck -> Tier 2 -> coach |
| **Clip-origin fresh install** | `hasLaunchedWeParkBefore == false` **and** `clipHandoffContext` present | **Tier 1' "Welcome, neighbor"** (one screen, replaces the 3-card deck) -> Tier 2 unchanged -> Tier 3 coach unchanged |
| Existing install (upgrade) | `hasLaunchedWeParkBefore == true` | Unchanged (coach only); a Spot Pass scan opens the full app straight into the in-app driver flow |
| Existing install, scan while onboarding flags off | | Same: the driver flow always wins; no onboarding on a Universal Link open |

**Tier 1' content:** headline "Welcome, neighbor." line "You've already helped 1 person park." (count from the context, "1 person" / "N people"; if karma pending: "+5 karma lands when they confirm"), karma chip, one primary button **"Show me around"** (goes on to Tier 2 then coach marks) and a quiet **Skip**. Mirrors the deck's mechanics (fullScreenCover, no permission request, selection haptic). New keys in standard `UserDefaults` (same BackgroundNoteGate convention): `onboardingOrigin` (`"clip"|"organic"|"existing"`, set once at the sentinel check), `hasSeenClipWelcome`. On Tier 1' completion or Skip: set `hasSeenOnboardingStory = true` (the deck never shows afterwards) and leave `hasSeenOnboardingCoach` false so Tier 3 still runs. Gating: Tier 1' depends on `AppConstants.spotHandoffEnabled` and presence of the context only (not on `onboardingStoryEnabled`); Tier 3 keeps its existing flags. Replay ("How WePark works" in More) still plays the standard deck (`first-run-onboarding-design.md` section 3), unaffected.

**Permissions earned, not front-loaded.** Location: the existing Tier 2 card, unchanged and still after the welcome (the person already granted a clip prompt if they tapped "Show me", so it reads as familiar). Notifications: **not asked at launch**; the existing `NotificationRationaleView` is invoked at the first action that needs it (creating a Spot Pass as a seeker, enabling auto-detect, or enabling spot pings), never from the welcome. Always location: never asked.

### 6.4 Funnel instrumentation (no SDK, no third party)

App Store Connect App Analytics already reports App Clip launches/installs; the `spot_handoffs` table gives status counts (created/armed/departed/thanked) and `depart_source` mix. No device identifiers, no new analytics SDK (consistent with Rev 1 section 6.11).

## 7. Notification delivery and departure detection

### 7.1 What exists today (grepped in Rev 1, unchanged)
Remote push is wired (`WeParkApp.swift:143-165`, `PushRegistrationService.swift`, `device_push_tokens`, `send-community-push`/`send-regular-push` with `APNS_*` secrets and `_shared` signer, `UIBackgroundModes = remote-notification`). Today's pushes are **silent**; Spot Pass needs **visible alert pushes** (new payload shape in the same pipeline) plus a silent kind for `handoff_ended`. Notification permission flow exists (`NotificationRationaleView`, `NotificationScheduler`). Today location is **When In Use only** with no background mode, no region monitoring, no CoreMotion (`project.pbxproj`). No new Apple key needed.

New push kinds from `send-handoff-push`:
| Kind | To | Channel |
|---|---|---|
| `armed` | seeker | alert: "A neighbor will be leaving in about 30 min." |
| `departed` | seeker | alert: "Spot Pass: your neighbor is pulling out now." |
| `thanks` | driver | ActivityKit push (update + end) and, if a token exists, ephemeral/regular alert: "A neighbor got your spot. Thanks!" (no alias beyond what the driver already saw) |
| `handoff_ended` | full-app driver | silent, closes the auto-detect window and Live Activity |

### 7.2 Lock-screen Live Activity (centerpiece)
- Started in the foreground at claim (`Activity.request`, `pushType: .token`), so ActivityKit pushes can end it when the seeker cancels or confirms.
- Lock Screen presentation: glyph + "Leaving in 9:42" (system timer text, no polling), a countdown ring, and one oversized button **"Leaving now"** (full app: `Button(intent: LeavingNowIntent(passId))` as a `LiveActivityIntent`; clip: deep-link to the clip's pulling-out screen). Compact/expanded Dynamic Island versions required by ActivityKit (compact: glyph + timer; expanded: button).
- Intent behavior (full app): sets `authenticationPolicy = .alwaysAllowed` (a one-bit event with no personal data) so it works from a locked screen; **device test** whether the OS still forces an unlock; unlock-then-send is the acceptable degraded path. The intent calls `handoff-depart` with `source: "live_activity"`; no app launch UI.
- States: counting down; "Time to go?" when `leave_at` is reached (stale-date driven, with an alert-configured update); "Sent. Your neighbor has been told" (no undo: the ping is one instant bit, and the tap is the confirmation). After send: celebration state until dismissed; ends on thanks, cancel, expiry.
- Hard constraints: Live Activities cannot access network or location themselves, 4 KB state, 8 h active limit (we cap at 4 h plus grace), users can disable Live Activities per app (`areActivitiesEnabled` false: the reminder notification is the fallback and the UI says so).
- Visible-by-design: an active pass is always visible on the driver's lock screen with a clear Cancel/"Not leaving" affordance (safety item 12).

### 7.3 Reminder notification at the chosen time
- Local (`UNUserNotificationCenter`), scheduled at `leave_at` (and a second "last call" at `leave_at + 10`). Clip: ephemeral authorization, check `.ephemeral`, set `targetContentIdentifier`. Category `SPOT_PASS_LEAVING` with actions: **Leaving now** (sends), **5 more min** (extend), **Not leaving** (silent cancel). App: actions are background-capable. Clip: expect each action to open the clip (device test); the clip then performs the action immediately on open and shows a confirmation, no second tap.
- Tapping the notification body (any mode) opens straight to the pulling-out screen.
- Copy: "Time to go? Bodega Cat is waiting." Never mentions location.

### 7.4 Armed-window auto-detect (full-app drivers only; last MVP stream, own flag)
How close to auto without Always: **start location in the foreground when the driver accepts a pass, keep it alive in the background only for the armed window, detect departure, ping, stop.**
- API facts: When In Use authorization + `UIBackgroundModes` `location` + iOS 17 `CLBackgroundActivitySession` held for the window, with `CLLocationUpdate.liveUpdates()` (or `CLLocationManager` updates). The system shows the **blue status-bar pill** for the whole window (a feature: transparency). Session must be created from the foreground and retained; invalidate it at the end. If the user force-quits the app, updates stop (document it; the Live Activity and reminder remain the fallback). Developer-forum reports of background delivery stopping after a few minutes on the newest OS: **device-test on the minimum and the current OS before trusting it**, and keep the reminder path independent of it.
- **Window opens** when the driver accepts a pass **and** `leave_at` is within 30 min (so the pill runs about 45 min at most), or when the driver foregrounds the app / taps the "Heading out?" reminder later (because the session needs a foreground start). Never open it for a pass more than 30 min out at accept time.
- **Anchor:** the driver's saved `ParkedCar` coordinate (iCloud KVS via `ParkPinService`). No ParkedCar saved: auto-detect is not offered (the driver still has Live Activity, reminder, Start Driving, and the Shortcut).
- **Departure rule:** two consecutive fixes with horizontal accuracy at most 65 m, **more than 60 m from the anchor, with speed at least 3 m/s (about 7 mph) sustained 5 s**. Walking away (more than 60 m at under 2 m/s) does nothing. Optional CoreMotion automotive confirmation is deferred (it adds a Motion permission). Then: `handoff-depart` with `source: "auto"`.
- **Window ends** at the first of: depart, driver cancel/not leaving, seeker cancelled/parked (`handoff_ended` silent push), `expires_at`, or a **hard 60 min cap**. On end: invalidate the session, stop updates, clear the anchor. The Live Activity says "WePark is checking for your departure" while the window is open and clears when it ends.
- **No location leaves the device:** the only network call is the depart event, carrying `{id, claimer_secret, source}`. The anchor and fixes are never stored, logged, or sent.
- False positives: a drive-off from a different spot than the saved car (the pass pings; costs the seeker one glance), GPS drift (accuracy gate + two fixes), garages (copy says street parking only). Seeker's "Didn't work out" sends nothing to the driver.
- Battery: bounded to the armed window; standard accuracy (not best-for-navigation) while stationary near the anchor; stop on any terminal.
- **"Start Driving in WePark = sends the ping":** when a pass is armed and the driver taps the existing Start Driving bar, `handoff-depart` with `source: "start_driving"` fires (with a one-line confirm toast "Told your neighbor you're leaving"). Cheap, no new permission, works in the same session as everything above.

### 7.5 Optional fully-auto: "when my phone connects to my car"
- Ship `LeavingNowIntent` as an App Intent with an `AppShortcutsProvider` phrase ("I'm leaving, WePark"). It no-ops quietly (returns "No active Spot Pass") when nothing is armed or the pass is outside its window.
- **Honest limitation:** a personal automation cannot be created, imported, or shared by link; the app can only guide. Provide a "Set up car auto-ping" screen with the 4 steps (Shortcuts > Automation > CarPlay or Bluetooth > Is Connected > Run Immediately > add the WePark action) and an `Open Shortcuts` button. No location permission involved. Per Apple's current guidance CarPlay/Bluetooth automations can run without asking; older pages say Bluetooth prompts: device-verify. This is a Phase-2-polish item for the guided screen; the intent itself is MVP because the Live Activity button shares it.

## 8. Architecture

| Codebase | What |
|---|---|
| Backend | Migration `supabase/<next>-spot-handoffs.sql` + test script; RPCs `create_handoff`, `cancel_handoff`, `confirm_handoff_outcome`; edge functions `handoff-peek`, `handoff-claim`, `handoff-depart`, `handoff-extend`, `handoff-cancel` (token/secret-gated, anonymous-callable with rate limits), `send-handoff-push` (service role, reuses `_shared` APNs signer; per-token topic: app, clip, or ActivityKit). Extend `10-account-deletion.sql`. Kevin applies SQL and deploys functions; agents write files and stop. |
| iOS app | Seeker flow; driver flow (arm, Live Activity, `LeavingNowIntent`, reminders, Start Driving hook, auto-detect); Tier 1' Welcome; clip-context adoption; Universal Link handling for `https://<domain>/p`; entitlements (Associated Domains, App Groups); `UIBackgroundModes += location`; flags `spotHandoffEnabled`, `spotHandoffAutoDetectEnabled` (both default false). |
| iOS App Clip target (new) | `WePark Clip` target (`com.kevinhoxha.wepark.Clip`), Live-Activity-only widget extension, ephemeral-notification + `NSAppClip` plist keys, `appclips:<domain>`, App Group, shared source folder `ios/WePark/Shared/SpotPass/` (models, API client, countdown, minimal rule evaluator) compiled into both targets. Budget at most 10 MB. |
| PWA | Static `handoff.html` fallback at `https://<domain>/p` (no cookies, no third-party scripts, `Referrer-Policy: no-referrer`), the AASA file, `.nojekyll`. Does not touch `index.html`. |
| Designer | Section 11. |

Data model (sketch; Rev 2 additions marked +):
```
spot_handoffs(
  id uuid pk, token_hash bytea unique, seeker_id uuid fk,
  alias text, glyph text, +seeker_display_name text null,   -- opt-in first name, purged with row
  status text check in (created,armed,departed,expired,cancelled,suspended),
  created_at, +leave_at, expires_at, armed_at, departed_at,
  claimer_anon_id uuid null,        -- never shown to seeker
  +claimer_secret_hash bytea null,  -- gates depart/extend/cancel; nulled at terminal
  +claimer_push_token text null, +claimer_activity_token text null, +claimer_topic text null, -- nulled at terminal
  +depart_source text null,         -- manual|live_activity|notification|auto|start_driving|shortcut
  +extensions smallint default 0,
  outcome text null                 -- got_spot | no_luck
)
handoff_reports(id, handoff_id, reporter text, reason, created_at)
```
No coordinates, addresses, plate, or username on the row. RLS: seeker selects own rows (status only); everything else via security-definer RPCs/edge functions.

API contract (so streams build against fakes):
- `create_handoff(show_name bool) -> {id, token, alias, glyph, expires_at}`
- `POST handoff-peek {token} -> {status:"open", alias, glyph, display_name|null} | {status:"unavailable"}`. Read-only, identical response for bad/expired/used.
- `POST handoff-claim {token, leave_at, push_token?, activity_token?, topic?} -> {status:"armed", id, leave_at, expires_at, claimer_secret} | {status:"unavailable"}`
- `POST handoff-depart {id, claimer_secret, source} -> {ok:bool}`; `handoff-extend {id, claimer_secret} -> {ok, leave_at, expires_at}`; `handoff-cancel {id, claimer_secret} -> {ok}`
- `cancel_handoff(id)` (seeker), `confirm_handoff_outcome(id, outcome)` (seeker; `got_spot` triggers the `thanks` push and karma).
- Errors indistinguishable for bad/expired/used token or secret.

## 9. SAFETY AND PRIVACY (non-negotiable) — re-checked for Rev 2

Threat unchanged: "notify a stranger when this car leaves" can reveal when someone leaves home, or help stalking. Rev 2 lengthens pass lifetime (up to 4 h plus grace instead of 15 min) and adds a background-location window and push/activity tokens. Each Rev 1 control is re-checked below; items 12-16 are new.

| # | Control | Rev 2 status |
|---|---|---|
| 1 | Explicit opt-in per handoff by the car owner | **Kept.** Nothing arms until the driver picks a time and taps the CTA ("A neighbor will be told when you pull out. That's all they will know."). Auto-detect and Start Driving only act on an already-armed pass. Auto-detect requires a second, explicit enable (full app, once, with a plain-language purpose screen) before the first window ever opens. |
| 2 | Short expiry; one-time | **Re-scoped honestly.** Seeker pass unclaimed TTL stays 20 min. Armed lifetime is now user-chosen leave time (cap 4 h) plus 15 min grace: it is longer, but it is a time the driver stated, is visible to them on their lock screen, and is bounded. The seeker sees only a coarse relative window, never a clock time. Server enforces the cap. |
| 3 | Driver can cancel anytime, silently | **Kept**, now from four places: Live Activity ("Not leaving"), notification action, in-app, web page. |
| 4 | No identity shared | **Kept, tightened.** Seeker sees nothing about the driver. Driver sees alias + glyph; **first name only if the seeker opts in** (decision 2). Claimer is a random anon id; seeker never sees it. |
| 5 | The ping carries no location | **Kept.** `armed`, `departed` and `thanks` payloads are text only. No address, block, side, car, coordinates. `address-anchored-parking.md` still NOT wired. The clip's "your block" card is computed on-device from a public tile and shown only to the driver. |
| 6 | No tracking after departure; no location stored | **Kept and extended to the new window.** The armed-window location session: opens only after an explicit enable and an armed pass; **no location ever leaves the device**; the only outbound call is the depart event with `source` (a string enum, not a place); anchor/fixes not persisted or logged; window ends at the first of depart/cancel/seeker-cancel/expiry/60 min cap and the session is invalidated; the blue pill shows throughout; clips never run background location. No Always permission, anywhere. |
| 7 | Anti-stalking structure | **Kept.** The code is created by the person who gets the ping and must be scanned and confirmed on the victim's own phone. New exposure: a longer window and a visible QR that could be photographed. Mitigations: the **QR token alone cannot depart, extend or cancel** (item 12); a victim socially-engineered into arming sees the Live Activity on their lock screen for the whole window with a one-tap Cancel; the seeker learns only "about N min", never when the person is actually at the car; seeker pass still dies when the seeker parks. Printable static codes remain deferred. |
| 8 | Rate limits | **Kept**, plus: peek 30/hour/IP, depart/extend/cancel 20/hour/id, max 3 extensions/pass. |
| 9 | Abuse reporting | **Kept** on the web page, the clip, the full app driver screen, and the seeker ping screen. |
| 10 | Security basics | **Kept**: 128-bit token, hash at rest, constant-time compare, identical error responses (peek included: no oracle), no PII in payloads, CORS to our origin, kill switch `HANDOFF_ENABLED` plus the app flags. Added: token in the fragment where the surface allows (web) and never logged. |
| 11 | Privacy policy / App Privacy | **Updated content:** a one-bit "leaving now" event, an approximate leave window the driver chose, an anonymous id, optionally a push/activity token, all deleted at terminal state and purged within 24 h; an on-device location window (When In Use, background only while a pass is armed, never transmitted); one public tile request from the clip (coarse tile id only). App Privacy "Location" answer: not collected (processed on device). Kevin updates the submission. |
| 12 | **New: per-claim secret** | `handoff-claim` returns a `claimer_secret` (128-bit, hash stored). Depart/extend/cancel require it. Without it, anyone who photographed the QR through the windshield could spoof a departure or cancel the pass. Secret lives in the keychain (full app) / the clip's own keychain item; never in shared defaults. |
| 13 | **New: tokens nulled at terminal** | Push token, activity token, topic, and secret hash are cleared when the row goes terminal, not at the 24 h purge. Exception (the fuse): where a push to the driver must still be sent after the terminal transition (`handoff_ended` after seeker cancel/suspension, <= 2 min; `thanks` after `departed`, <= 30 min), tokens are kept until the push completes or the sweep fuse fires; the secret hash is always cleared immediately. |
| 14 | **New: thanks is one bit, positive only** | `thanks` fires only on `got_spot`; "Didn't work out" sends nothing; it reveals only that the seeker took a spot, after the driver already left. |
| 15 | **New: visible-by-design** | Armed state is always shown on the driver's own lock screen (Live Activity) and, with auto-detect, the system blue pill. If Live Activities are disabled, the reminder notification and in-app banner carry the same transparency. |
| 16 | **New: clip data minimization** | Clip stores only the anon session (keychain, labeled) and the non-sensitive context in the shared container; it does not collect device name or vendor id (both are blank for clips by platform design). |

## 10. Karma

Reuses the existing reputation system: `profiles.reputation`, `helped_count`, idempotent append-only `reputation_award_log` (`supabase/03-community-2.0-schema.sql`, spec section 2.6). Concept language: "Good Neighbor", "You've helped 41 neighbors park" (`docs/nyc-neighbors-incentives-concept.md` section 4). Defaults (Kevin may retune; no response needed):
- **Driver (helper)** +5 reputation and `helped_count` +1 when the seeker confirms "Got it, thanks!". Clip drivers have an anonymous uid, so karma accrues and carries into the full app (section 6.2). Karma is **shown as pending** until confirmed.
- **Verified-departure fallback:** if the departure came from `auto` or `shortcut` and the seeker never confirms within 30 min, driver gets +2 (caps below apply). Never full credit without the seeker.
- **Seeker** +1 for confirming either outcome, +2 extra on "Got it, thanks!".
- Badge counters: "Spots passed" (driver), "Spots caught" (seeker).
Anti-gaming (unchanged): karma only on seeker-confirmed outcome from a different user (seeker id != claimer id; claimer nonce != any seeker device token); 3 rewarded handoffs/user/day; same pair once per 24 h; ledger key `(handoff_id, role)`; self-scan rejected ("That's your own pass"); farming rings bounded by caps and listed on the post-launch watch-list (`docs/regulars-network-spec.md:876-888`); karma is points only, not redeemable cash (concept doc section 6).

## 11. "Sexy and fun" brief for @designer (expanded)

Tone: warm, NYC, good neighbors. Playful, never begging or transactional. No money.
Deliverables to `docs/design/` (light/dark where applicable, AX5, VoiceOver labels, Reduce Motion, large touch targets everywhere, drive-mode surfaces roomy):
1. **Spot Pass badge (seeker).** Pass/ticket card: WePark mark, alias + glyph (rotates per pass, unlinked to username), karma tier chip, line ("Looking for a spot near you"), **branded QR as hero**: rounded modules, WePark color, center logo that stays reliably scannable. Hard requirements: scans from the plain iOS camera at 1-1.5 m through a tinted windshield in glare on a phone mount; at least 7:1 module contrast; correct quiet zone; error-correction headroom for the logo; auto-max brightness; portrait/landscape; the URL is about 40 chars (low density). QR contrast test results required. Modes: full-screen, compact card in the map sheet, share image. Live states: countdown ring, "A neighbor scanned: leaving in about 30 min", pulse, ping celebration.
2. **App Clip card art + clip first screen.** Header image for the Apple card (static, title <=30, subtitle <=56). The clip's first screen: full-bleed brand moment, alias hero ("Bodega Cat is waiting for your spot"), chips, one huge CTA, reassurance lines, skeleton states, the "Show me this block" card and its result (street-cleaning line, green/red in plain words, curb-color palette from `ParkingColors` in the existing design language), the offline/slow state. Must feel instant; no map.
3. **Live Activity.** Lock Screen, Dynamic Island compact/minimal/expanded, StandBy; states: counting down, "Time to go?", sent/celebration, thanks, cancelled/ended; the huge "Leaving now" button (app) and its deep-link variant (clip); "WePark is checking for your departure" auto-detect note; accessibility labels and AX layout within the 160 pt height limit.
4. **Reminder notification** (copy, category actions Leaving now / 5 more min / Not leaving, thread grouping, sound).
5. **Celebration and thank-you.** Driver's "You passed a spot" moment (pending karma), the thank-you moment, install overlay copy and placement, seeker's "Spot opening up" and "Got it, thanks!" interactions, karma +N animation, confetti and haptics honoring Reduce Motion.
6. **Tailored first-launch screen (Tier 1').** "Welcome, neighbor. You've already helped 1 person park." with karma chip, "Show me around"/Skip, matching the story-deck mechanics in `first-run-onboarding-design.md` section 1.5 (progress not needed for one card), plus empty/zero-karma variant and plural copy.
7. **Fallback web page** (`handoff.html`): same language, three reassurance lines, big [I'm leaving now] / [Not now], Report, Get WePark.
8. **Car-connect auto-ping setup screen** (4 numbered steps with Shortcuts screenshots).
Name/alias glyph set; opt-in "Show my first name" toggle copy.

## 12. Work streams

Merge-conflict note: `project.pbxproj`, entitlements, and Info.plist are shared by C0-C3. **C0 serializes first** (one small PR); C1-C3 then run in parallel on disjoint folders.

| # | Stream | Owner | Depends on | Parallel? |
|---|---|---|---|---|
| A | Migration, RPCs, RLS, test script, account-deletion cascade, ledger awards | @backend-data | none | yes |
| B | Edge functions peek/claim/depart/extend/cancel + `send-handoff-push` (app, clip, ActivityKit topics, silent `handoff_ended`) | @backend-data | A's contract (this section 8) | parallel with C-D after the contract |
| C0 | **Scaffold PR:** clip target, Live-Activity widget extension (app + clip), App Group, Associated Domains, `UIBackgroundModes` (location only if Kevin confirms decision 3), flags, `Shared/SpotPass/` folder, Universal Link route stub, CI build of all targets | @ios-engineer | Kevin step 5.5.2 (IDs) for device signing; simulator build needs none | **serial, first** |
| C1 | Seeker flow: create, QR render, states, ping handling, outcome, karma display | @ios-engineer | C0, contract | yes |
| C2 | Full-app driver flow: arm, Live Activity + `LeavingNowIntent`, reminders, Start Driving hook, Tier 1' Welcome + context adoption | @ios-engineer | C0, contract | yes |
| C3 | **App Clip target:** invocation handling, peek/claim, chips, Live Activity (deep-link variant), ephemeral reminders, pulling-out screen, "show me this block" (single-tile fetch + minimal rule evaluator), celebration/thanks, install overlay, context writer; size budget at most 10 MB | @ios-engineer | C0, contract | yes |
| C4 | Armed-window auto-detect (flag-gated, **last**) + purpose screen | @ios-engineer | C2 | after C2; droppable without blocking others |
| D | Static fallback `handoff.html`, AASA file, `.nojekyll`, optional hosted-tile path on `<domain>` | @pwa-maintainer | contract | yes |
| E | Design brief to mocks and assets, brand pass (section 11) | @designer | none | yes, feeds C1-C3 polish |
| H | Domain, DNS, Apple Developer IDs, App Store Connect experiences (section 5.5) | Kevin | none | start now, it has lead time |
| F | QA: backend script, device pass (windshield scan, clip invocation via local experience then TestFlight experience, Live Activity, notification actions, auto-detect drives), safety checklist | @qa-verifier | A-D | after |
| G | Privacy-policy section (section 9 item 11) | Tech Lead doc | none | yes |

Dispatch note for every iOS stream: cite the project's standing Swift compile-failure classes list (blind-build gotchas, including qualifying `WePark.Category` in test targets). Each concurrent build/launch agent needs its own simctl device. The clip target adds a new class of failure: unavailable frameworks compile in a clip but return inert values at runtime (section 5.1), so QA must exercise the clip build, not only compile it.

Realistic timeline (question-scope note): backend about 1 week, seeker about 1 week, clip plus full-app driver about 2-3 weeks including device testing, auto-detect about 1 week plus drive tests. Strangers can use the clip only after an App Store release (not TestFlight), so the first public milestone is "web fallback live + app released"; clip becomes the primary path from that release.

## 13. Phasing

- **MVP:** everything in section 2 In: seeker, clip + web fallback, full-app driver (Live Activity centerpiece, reminders, Start Driving, intent), karma + thanks, onboarding funnel, safety controls, then auto-detect last behind its own flag.
- **Phase 2:** guided car-connect setup polish and any Shortcuts content; `merge_anon_identity`; Time Sensitive alerts; seeker-side Live Activity; symmetric driver-created pass for app-installed waiters; printable dash card with live toggle; horizon beyond 4 h for full-app drivers; CoreMotion automotive confirmation; localized card/clip.
- **Phase 3:** neighborhood leaderboards / "Mayor of" tie-in; sponsor-locked rewards (only with verification).

## 14. Acceptance criteria

General
- [ ] Flags off: app and PWA behavior unchanged; edge functions return disabled; clip target builds and does nothing harmful if invoked while disabled.
- [ ] Safety checklist in section 9 walked item by item (all 16) by @qa-verifier.

Seeker and server (carried from Rev 1, updated)
- [ ] QR scans from the iOS camera at 1.5 m through a tinted windshield on a mounted phone, portrait and landscape, daylight and glare; the branded QR decodes as reliably as a plain one.
- [ ] Scan -> arm -> seeker device gets the `armed` alert; "Leaving now" -> `departed` alert within 10 s on production APNs (TestFlight) and sandbox (debug).
- [ ] A second scan shows "already used"; bad/expired/used token or secret return indistinguishable responses (peek and claim included).
- [ ] Unclaimed pass expires at 20 min; an armed pass expires at `leave_at + 15 min`; leave time above 240 min is rejected; extend is capped at 3 and never passes the horizon; expired passes cannot depart; purge removes rows after 24 h.
- [ ] Depart/extend/cancel without the correct `claimer_secret` fail even with a valid token; claimer secret hash is null at every terminal transition; claimer push/activity tokens are null immediately for expired / driver-cancel / no_luck / claimer-report, and on a short fuse only where a push to the driver must still go out (seeker cancel or suspension: <= 2 min; `departed`: <= 30 min so the `thanks` push can be sent), cleared earlier by seeker confirmation or `send-handoff-push` completing, backstopped by the minute sweep (`claimer_tokens_until`); never past 30 min after a terminal.
- [ ] Seeker sees only "Leaving in about N min" (no clock time); seeker "Stop waiting", seeker parking, and driver cancel behave as specified; driver cancel sends the seeker nothing.
- [ ] No location, address, plate, username, or device identifiers beyond APNs/ActivityKit tokens appear in payloads or table dumps.
- [ ] Rate limits and 3-report suspension work; self-scan rejected; karma only on seeker-confirmed outcome from a different user, caps and pair cooldown enforced, duplicate confirm idempotent; account deletion removes handoff rows and reports.
- [ ] Notification permission denied for the seeker: clear in-app state.

App Clip and invocation
- [ ] Local experience: scanning the plain QR from the iOS camera launches the clip (card shown) with the token available; the full-app Universal Link path opens the app and runs the in-app driver flow. Verify the fragment `#t=` survives into the invocation URL, or the `?t=` fallback is in place.
- [ ] TestFlight experience (domain associated, AASA validated in App Store Connect) launches the clip from the TestFlight app.
- [ ] Clip build size at most 10 MB per device variant (hard fail above 14 MB); clip starts to interactive first screen in under 2 s on a mid-range device on LTE (skeleton counts as not interactive).
- [ ] Clip works with the ephemeral notification permission switched on and degrades cleanly when the user turns it off on the card (Live Activity and in-app state still work; copy says reminders are off).
- [ ] Clip never calls `requestAlwaysAuthorization`, uses no background modes, no CoreMotion, no AppIntents buttons it depends on.
- [ ] Web fallback works on iOS Safari with no install, no cookies, no third-party scripts, `Referrer-Policy: no-referrer`; reached when clip cannot run (clips disabled in Settings, card dismissed).

Driver experience
- [ ] Chips (Now/~10/~30/~1 hr/Pick) arm the pass; the CTA text matches the selection; ~10 preselected; leave time rounded to 5 min.
- [ ] Live Activity starts at claim; counts down; shows the "Leaving now" button; app: tap sends `source: live_activity` with no app UI and works with the screen locked or degrades to unlock-then-send (document which); clip: tap opens the pulling-out screen, one more tap sends. Ends on thanks, cancel, expiry.
- [ ] Reminder fires at `leave_at` with three actions; app: actions work without opening the app; clip: actions open the clip and complete without a second tap (record actual behavior).
- [ ] "Start Driving" with an armed pass sends the ping once (idempotent with other sources); the confirm toast appears.
- [ ] `LeavingNowIntent` runs from Shortcuts, no-ops with no armed pass, and works from a CarPlay/Bluetooth personal automation (device test, record whether Run Immediately is honored).
- [ ] Celebration appears on depart with karma shown as pending; the seeker's "Got it, thanks!" delivers the thank-you (Live Activity update or ephemeral/regular push) and makes karma real; "Didn't work out" sends the driver nothing.

Onboarding funnel
- [ ] Clip-origin fresh install: first launch shows Tier 1' ("Welcome, neighbor. You've already helped N people park.") instead of the 3-card deck, then the unchanged Tier 2 and Tier 3; `hasSeenOnboardingStory` set, `hasSeenOnboardingCoach` still false until the coach completes; karma/`helped_count` equal the server values for the adopted uid.
- [ ] Organic fresh install and upgrade-install paths are byte-for-byte unchanged versus `first-run-onboarding-design.md`; "How WePark works" replay unaffected; story cards still never request a permission.
- [ ] No notification prompt at first launch for any path; the rationale appears at the first action that needs it; location prompts only via the clip's explicit "Show me" tap and the existing Tier 2 card.
- [ ] Beat 2: "Show me" -> When In Use prompt -> correct next-cleaning line for a known test block (compared with the main app for the same coordinate); decline leaves no nag; data fetched is a single tile.
- [ ] Install overlay appears only after the celebration/thank-you, is dismissible, and is not shown twice in a session.

Auto-detect (own flag, last)
- [ ] With flag on and a saved `ParkedCar`: accept a pass with leave time within 30 min -> blue pill appears -> driving away (over 60 m, at least 3 m/s for 5 s) pings once with `source: auto`; walking away never pings; the window and pill end on depart, cancel, seeker cancel (silent push), expiry, and at the 60 min cap.
- [ ] Network traces show no location or coordinates in any request during the window; no logs contain coordinates.
- [ ] `UIBackgroundModes` includes `location` only if decision 3 was approved; no Always key or request exists in the binary.
- [ ] Accessibility: VoiceOver for the pass card (label includes the state/expiry), Live Activity, reminder, clip screens, Welcome; AX5 layouts; Reduce Motion respected; big touch targets.

## 15. Test plan
- Backend script (pattern `supabase/04-community-push-test.sh`): state machine, atomic single claim under concurrent calls, expiry via manipulated clock columns, horizon/extension caps, secret gating, token nulling at terminal, RLS, rate limits, ledger idempotency, cascade on deletion. Kevin applies the SQL; QA runs against staging/prod with throwaway users.
- iOS unit: service fake per state; countdown/expiry logic; chip-to-`leave_at` rounding; deep-link and invocation-URL parsing (with and without token, fragment and query forms); push handler routes handoff kinds and does not disturb the silent community/regular path; onboarding gate matrix (organic / clip-origin / existing x flags); context adoption (no session vs existing session); auto-detect state machine with synthetic fixes (walk, drive, drift, accuracy gate, window end conditions).
- Clip: build-size check per variant in CI; run the clip target on device; `_XCAppClipURL` for debugging, local experience for the card flow, TestFlight experience for the domain-associated flow.
- Device: windshield/glare scan tests; Live Activity locked-screen tap; notification actions in both app and clip; airplane-mode failure copy; Live Activities disabled; ephemeral notifications switched off on the card; Focus modes; real APNs on TestFlight; auto-detect drive tests (walk away, GPS drift near buildings, garage, app force-quit, minimum and current iOS).
- Public-launch rehearsal (post App Store release only): strangers' phones scan the code and reach the clip.

## 16. Out-of-scope follow-ups
- Always location / region monitoring: not needed given the armed-window design; revisit only if drive tests show the window is unreliable.
- CoreMotion automotive confirmation: adds a Motion permission for marginal gain.
- Horizon beyond 4 h: needs full-app local notifications (no clip 8 h limit) and a fresh safety review (longer exposure).
- `merge_anon_identity` RPC for clip/app identity collisions.
- Printable dash card: static tokens widen the abuse surface; revisit with live-toggle design.
- Seeker-side Live Activity ("waiting for a spot"): nice, not needed.
- Sharing address/block in the ping: rejected on privacy grounds; revisit only with explicit per-pass opt-in.
- Rewards dollars for handoffs: fraud magnet until departures are verified (concept doc section 6).
- Garage/off-street handoffs: no signal; out.
- App Clip Codes (custom Apple design): cannot encode per-pass tokens; plain branded QR chosen.

## Sources (Apple documentation, fetched 2026-11-23)
- Choosing the right functionality for your App Clip: https://developer.apple.com/documentation/appclip/choosing-the-right-functionality-for-your-app-clip
- Enabling notifications in App Clips: https://developer.apple.com/documentation/appclip/enabling-notifications-in-app-clips
- Offering Live Activities with your App Clip: https://developer.apple.com/documentation/appclip/offering-live-activities-with-your-app-clip
- Sharing data between your App Clip and your full app: https://developer.apple.com/documentation/appclip/sharing-data-between-your-app-clip-and-your-full-app
- Configuring App Clip experiences: https://developer.apple.com/documentation/appclip/configuring-the-launch-experience-of-your-app-clip
- Creating App Clip Codes / Encoding a URL in an App Clip Code: https://developer.apple.com/documentation/appclip/creating-app-clip-codes , https://developer.apple.com/documentation/appclip/encoding-a-url-in-an-app-clip-code
- Associating your App Clip with your website: https://developer.apple.com/documentation/appclip/associating-your-app-clip-with-your-website
- Responding to invocations: https://developer.apple.com/documentation/appclip/responding-to-invocations
- Testing the launch experience of your App Clip: https://developer.apple.com/documentation/appclip/testing-the-launch-experience-of-your-app-clip
- Displaying live data with Live Activities: https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- App Store Review Guidelines (2.5.4, 2.5.16, 5.1.5): https://developer.apple.com/app-store/review/guidelines/
- WWDC23 "Discover streamlined location updates" (CLBackgroundActivitySession, blue indicator): https://developer.apple.com/videos/play/wwdc2023/10180/
- WWDC23 "What's new in App Clips" (50 MB digital invocations): https://developer.apple.com/videos/play/wwdc2023/10178/
- Shortcuts automations (run without asking): https://support.apple.com/guide/shortcuts/apdfbdbd7123/
- Forum reports (unofficial, treated as risk flags): ITMS-90842 `requestAlwaysAuthorization` in a clip https://developer.apple.com/forums/thread/662724 ; clip size margin https://developer.apple.com/forums/thread/740061 ; background location behavior https://developer.apple.com/forums/thread/844579
