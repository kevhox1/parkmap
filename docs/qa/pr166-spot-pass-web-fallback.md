# PR #166 QA: Spot Pass web fallback (`/p`)

**Reviewed:** branch `feat/spot-pass-web-fallback` at `5276561e`, against `docs/specs/qr-spot-handoff.md` (Rev 2 5.4, 8, 9) and `docs/design/spot-pass-design.md` (section 4, section 10).
**Verdict:** MERGE-WITH-FOLLOWUPS. No blocking findings. Safe to auto-deploy: Spot Pass is disabled server-side, so the live page can only reach the "isn't live yet" screen. Two significant items should be fixed before Spot Pass is enabled.

## Summary
The page is a single 20.8 KB static file with no third-party requests, no cookies, no `innerHTML`, and a tight CSP. The token is read from `#t=` only and scrubbed. Every state renders correctly at 390x844, 375x667 and 195 px wide (200% zoom equivalent). The depart/extend/cancel flow uses the claim `id` (verified with a mocked backend), and the "open the WePark app" fallback works when `id` is absent. Real-endpoint behavior is as expected: peek and claim return 503 `{"error":"disabled"}` with correct CORS for `https://getwepark.com`. The significant issues are in edge paths that matter once the feature is live (details below).

## Acceptance checklist
- [x] Token from `#t=` only, regex `^#t=[A-Za-z0-9_-]{22}$`. Verified in the code and in the browser: a bad token (`#t=short`) is ignored and shows "isn't active".
- [x] URL scrubbed with `history.replaceState(null,'',location.pathname)`, dropping both hash and query. Verified live: URL is `/p/index.html` after load for every case.
- [x] Token and secrets only sent to `https://jiispshyqerscdoferaw.supabase.co/functions/v1/handoff-*`. CDP network log across all runs shows only those URLs plus localhost.
- [x] `claimer_secret` and `id` live in memory and `sessionStorage` (`wp_sp`) only. `document.cookie` is empty. Fetch uses `credentials:'omit'`, `cache:'no-store'`, `referrerPolicy:'no-referrer'`.
- [x] No analytics and no external fonts or scripts. Grep for `http` finds only the API base and the App Store link (`rel="noopener noreferrer"`).
- [x] All server data goes through `textContent` (alias is sliced to 40 chars, name to 20, and glyph is a lookup table). Grep for `innerHTML|insertAdjacentHTML|outerHTML|document.write|eval(` returns zero hits.
- [x] CSP: `default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src https://jiispshyqerscdoferaw.supabase.co; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`. Not over-broad. `'unsafe-inline'` is justified because the page is a single file with inline script and style. Plus `X-Frame-Options: DENY`, a Permissions-Policy, and `Referrer-Policy: no-referrer` site-wide, with `<meta name=referrer>` and `noindex, nofollow` in the page.
- [x] Smart banner meta has no `app-argument`.
- [x] Fake mode (`?fake=1`) is impossible when a real `#t=` is present (verified: `?fake=1#t=AAAA...` makes a real call attempt).
- [x] Full fake flow: peek, chips, claim, armed, extend (+5 min, "Added 5 minutes."), leave, celebration, report, "Thanks for telling us". Also `state=unavailable|disabled|error|armed|sent`, `name=Maya`, and no-token load. All correct (screenshots below).
- [x] With a mocked backend (CDP Fetch): the depart, extend and cancel bodies carry the claim `id` and `claimer_secret`. Depart sends `source:"manual"`.
- [x] Real endpoint via curl, Origin `https://getwepark.com`: OPTIONS gives 204 with ACAO echoing that origin. POST peek and POST claim give 503 `{"error":"disabled"}` with ACAO. With Origin `http://localhost:8765` there is no ACAO header, so the browser blocks it. In the page that case becomes the "That didn't go through" screen with Try again, not a blank page.
- [x] Size 20.8 KB (< 40 KB). Zero horizontal overflow at 195 px.
- [x] Banned words: no "ping", "claim", "token", "hurry", "free spot", "points" in user copy. Voice is good-neighbor ("Thanks, neighbor", "It's a courtesy, not a promise", "Please don't use your phone while driving"). One exclamation per screen at most.
- [x] No green, orange or red chrome. Palette is indigo, lavender and white.

## Findings

### Blocking
None.

### Significant
- **#1: Report from the celebration (sent) screen silently fails but tells the user it worked**
  - Where: `index.html` `renderSent()` / `#s-report` click handler.
  - What: `renderSent()` calls `wipe()`, clearing `token`, `id` and `secret`, yet the footer "Report this pass" link stays visible. Reporting from there sends `{"token":null,"reason":"spam"}`. The page does not check the response status (only 503 or 429), so a server 400 still shows "Thanks for telling us / This pass has ended". The report is silently lost. Reproduced with a mocked 400 on an empty body.
  - Expected: report is a safety valve (spec section 9). Either hide Report on the sent screen, or keep `{id, claimer_secret}` until the tab closes, and only show success on `r.status===200`.
  - Repro: mock backend, claim, "I'm leaving now", tap "Report this pass", then "Spam". The page shows success and the last request has no token or id.
  - Owner: `@pwa-maintainer`.
- **#2: "Now" chip claims and departs in one tap, contradicting design F7 and the spec's "manual I'm leaving now only"**
  - Where: `$('go').onclick`, `if (chosen === 0) depart();`.
  - What: tapping Now immediately sends `handoff-depart`, so the seeker gets "pulling out" even if the driver is still walking to the car. The README documents this as intended.
  - Expected: `spot-pass-design.md` F7: "Now arms with `leave_at = now` and lands on the 'Time to go?' state with the big pull-out button. It never sends the ping by itself." Spec 5.4: "manual 'I'm leaving now' only".
  - Owner: `@pwa-maintainer` (or document a deliberate design override).

### Minor
- **#3: Failures on extend and cancel are misreported.** With no `id` (the prod `handoff-claim` not yet redeployed with PR #167), "5 more min" says "There's a limit on extensions", and "Not leaving" shows "No problem / Thanks for letting us know" while the pass is still armed. Cancel and report never check for a non-200. Depart is handled correctly: "We couldn't finish this from the web. Please open the WePark app." Verified with a claim response lacking `id`. This also applies to any 4xx once the id is present. Suggest gating extend, cancel and report on `r.status===200 && ok`. Owner: `@pwa-maintainer`.
- **#4: README "Known contract gap" is stale** since PR #167 (claim now returns `id`). Update it. The page already handles both. Owner: `@pwa-maintainer`.
- **#5: Minor UX.** Stale status text ("Added 5 minutes.") persists on the sent and report screens in the status line. The "peek" no-token case shows stale `sessionStorage` state if the same tab previously held a pass (acceptable). A hash-only navigation on `/p` in the same tab doesn't reload, so a second pass pasted into the same tab isn't picked up (edge case, not a QR path). The 🚧 and ⏳ glyphs carry orange and yellow tones on gray discs, a tiny deviation from "no orange chrome". Fake banner overlaps the footer card (fake mode only).
- **#6: Header scope unverified for `/p/`.** The CSP header `source` is `/p` only. I could not verify on Vercel whether `/p/` (trailing slash) or `/p/index.html` redirect to `/p` under `cleanUrls`. QR URLs are `/p#t=...`, so the primary path is covered. Not verified: recommend `curl -sI https://getwepark.com/p` after deploy and confirm `content-security-policy` is present.

### Out of scope (logged)
- Live `/p` today is a 949 byte placeholder (200, `noindex`). This PR replaces it. No regression risk beyond the replacement itself.
- Supabase edge responses set a Cloudflare `__cf_bm` cookie for `supabase.co`. With `credentials:'omit'` the browser ignores it, so no cookie is stored. Noted only for the privacy-policy wording.
- CORS allows only `https://getwepark.com`. The `www.` host would fail. Already documented in the README.

## Smoke tests run
Chrome 158 headless driven via CDP (no installs), `python3 -m http.server` on 8765, fresh tab per scenario.
- Fake flow, all `state=` variants, `name=Maya`: pass (screenshots 01, 02, 03, st-*).
- No token: "This Spot Pass isn't active". Bad token: same. Real token on localhost: CORS failure, error screen with retry, URL scrubbed.
- Mocked 503 peek: "Spot Pass isn't live yet" (`07-503-live-390.png`). Mocked full flow: request bodies checked for `id` and secret. Reload after armed restores the armed screen.
- Mocked claim without `id`: depart shows the "open the WePark app" fallback.
- Curl against the real functions, as above (peek and claim 503, CORS correct).
- Layout at 390x844, 375x667 and 195 px wide: no overflow. Buttons are at least 56 px (chip 56, primary 64) and links 44 px. Contrast of white and lavender on near-black is high. Headings take focus on each state change, status lines use `role=status`, and the chip group has an aria-label.
- Not verified: VoiceOver on a real device, a real Safari smart banner, reduced-motion rendering (read from CSS only), and the production Vercel headers (pre-merge).
- Local servers (http.server, headless Chrome) stopped.

## What's working
No third-party surface, strict CSP, and `textContent` everywhere. The token never persists after claim. Fake mode is hard-disabled when a real token exists. Failure paths (network, CORS, 503, 429, unavailable) all land on friendly screens. Copy matches the design voice and the dark brand palette. The page is small and fast.

Screenshots: `docs/qa/assets/pr166/`.

## Re-verification after fixes (2026-11-24)

**Reviewed:** `feat/spot-pass-web-fallback` at `95de03e5` (fix commit on top of `5276561e`; only `web/getwepark/p/index.html` and `p/README.md` changed, `vercel.json` untouched so CSP and headers are identical).
**Verdict: MERGE.** All six prior findings are fixed or verified. No new blocking or significant issues.

Method: local `python3 -m http.server` in `web/getwepark`, headless Chrome 158 over CDP at 390x844 with a mocked Supabase backend (CDP Fetch, including CORS preflight) that logs every request body. Server and Chrome stopped afterwards.

- [x] **#1 Report from celebration screen: FIXED.** Report credentials are kept in an in-memory `R` object (not sessionStorage). After claim, depart, then Report > Spam, the request is `handoff-report {"id":<uuid>,"claimer_secret":<22 chars>,"reason":"spam"}`, which matches `handoff-report/index.ts` (`isUuid(id) && isSecret(secret)`, or a valid token). "Thanks for telling us" shows only on HTTP 200 with `ok:true`. Mocked 400 gives "That didn't go through. Check your connection..." on the report screen. Mocked 200 `{ok:false}` gives "We couldn't record that. The pass may have already ended." Neither shows the thank-you. After a reload on the celebration screen the credentials are gone and the Report link is hidden (verified). Reporting an unclaimed pass still sends `{token, reason}`. With no identifiers at all, the code shows "open the WePark app to report" rather than sending an empty body.
- [x] **#2 "Now" chip: FIXED.** Tapping Now then "Tell them when I leave" sends only peek and claim. The screen is "Time to go?" with just "I'm leaving now" and "Not leaving" (countdown and "5 more min" hidden). `handoff-depart` (`source:"manual"`, id and secret present) fires only on the "I'm leaving now" tap, which then shows the celebration. Network log confirmed. Screenshots: `docs/qa/assets/pr166/reverify-now-armed-390.png`, `reverify-sent-390.png`.
- [x] **#3 Accurate failure messages: FIXED.** Extend and cancel with a mocked 400 give the retry copy and the pass stays armed. With 200 `{ok:false}` they say "Can't add more time. The pass may have ended or reached its limit." and "This pass may have already ended. Please open the WePark app to check." With no `id` in the claim response, no extend/cancel/depart request is sent and each says to open the app. Cancel success shows "No problem". Extend success shows "Added 5 minutes."
- [x] **#4 README: FIXED.** The stale "Known contract gap" is replaced with the PR #167 contract note, plus notes on the Now flow and in-memory report credentials.
- [x] **#5 Polish: FIXED.** `show()` clears `st-open`, `st-armed` and `st-report` on every transition, so the stale "Added 5 minutes." is gone (status lines empty on sent and report screens). The orange and yellow glyphs are replaced by a neutral ellipsis on message screens. The fake banner is now in normal flow (`position:fixed` removed). I checked the banner in the diff and CSS only; I did not capture a fake-mode full-page screenshot, so treat it as read, not seen. The same-tab hash-navigation edge case is unchanged (not a QR path).
- [ ] **#6 Vercel header scope:** still not verifiable pre-merge. After deploy, run `curl -sI https://getwepark.com/p` and confirm `content-security-policy` is present.

**Regression (unchanged):**
- Peek 503 shows "Spot Pass isn't live yet". Unavailable, no-token and fake-mode states render as before. Fake mode still works only without a real token.
- Zero hits for `innerHTML|insertAdjacentHTML|outerHTML|document.write|eval(`. The diff adds no new URLs or third-party requests.
- `credentials:'omit'`, `cache:'no-store'` and `referrerPolicy:'no-referrer'` intact. `history.replaceState` still scrubs the URL (every case showed `/p/index.html`). Token dropped after claim. `claimer_secret` and `id` go to sessionStorage only, and `wipe()` removes them.
- CSP and headers identical (`vercel.json` has no diff). Page size 22.2 KB (was 20.8 KB, well under 40 KB).

**New nits (green, not blocking):**
- A claim response without `id` hides the Report link, since identifiers are incomplete and the token has been dropped. Harmless today because prod claim returns `id` (PR #167).
- The report-failure copy for `ok:false` assumes `handoff_report` returns `ok:false` for an already-ended pass. I did not check the RPC. If it does, a late reporter on the celebration screen sees a failure message even though the pass ended. Worth a look when Spot Pass is enabled.

Not verified: real Safari and VoiceOver, and production Vercel headers (post-deploy curl above).
