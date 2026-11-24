# Spot Pass web fallback (`https://getwepark.com/p`)

Single static file, `index.html` (inline CSS and JS, no frameworks, no third-party requests). It is the stranger path
when the App Clip / full app cannot open (spec `docs/specs/qr-spot-handoff.md` section 5.4). Manual "I'm leaving now" only.

## Behavior

1. Reads the pass token from `location.hash` (`#t=<22 base64url chars>`), then scrubs the URL with `history.replaceState`.
   The token is kept in memory and in `sessionStorage` (tab-scoped, cleared when the tab closes, never transmitted) so a
   reload or an iOS tab discard does not lose the pass. The token is dropped from storage once the pass is claimed; the
   claimer secret is kept in `sessionStorage` only.
2. `handoff-peek` -> "<Alias> is waiting for your spot" with a glyph (emoji per the 16 `create_handoff` slugs, pin fallback).
   `{status:"unavailable"}` -> one uniform "This Spot Pass isn't active" screen. HTTP 503 -> "Spot Pass isn't live yet".
3. Chips Now / ~10 min / ~30 min / ~1 hour (max 1 h, well under the 4 h cap) -> `handoff-claim` (no push token).
   "Now" claims and departs in one action. Others show the armed screen: **I'm leaving now** (`handoff-depart`,
   `source:"manual"`), **5 more min** (`handoff-extend`), **Not leaving** (`handoff-cancel`).
4. After depart: "You just made someone's day" (no karma promised; web has no identity) plus the Get WePark card.
5. **Report this pass** (`handoff-report`: harassment / spam / unsafe / other), with `{id, claimer_secret}` once armed,
   else `{token}`.
6. No cookies, no analytics, no identity, no location. `credentials:'omit'`, `Referrer-Policy: no-referrer`, `noindex`.
   The smart-banner meta has no `app-argument` on purpose (the pass URL contains the token).

## Local testing (fake mode, no network)

```sh
cd web/getwepark && python3 -m http.server 8765
```

Fake mode needs `?fake=1` AND no `#t=` token in the URL (a real token always disables it; it never calls the real API).

| URL | Shows |
|---|---|
| `http://localhost:8765/p/index.html?fake=1` | open -> chips -> arm -> extend / cancel / depart (full click-through) |
| `...?fake=1&name=Maya` | opt-in first name headline |
| `...?fake=1&state=unavailable` | "This Spot Pass isn't active" |
| `...?fake=1&state=disabled` | "Spot Pass isn't live yet" |
| `...?fake=1&state=error` | network failure screen with Try again |
| `...?fake=1&state=armed` / `&state=sent` | jump straight to armed / celebration |

Also check: report flow, reduced motion (static sparkles, no confetti), browser text at 200%, VoiceOver reads the status line.

## Real-endpoint checks (safe while `HANDOFF_ENABLED=false`)

Open `https://getwepark.com/p#t=AAAAAAAAAAAAAAAAAAAAAA` (any 22-char token). Peek returns 503 -> "Spot Pass isn't live yet",
and the address bar shows plain `/p`. Open `/p` with no fragment -> "This Spot Pass isn't active". DevTools Network: only
requests to `jiispshyqerscdoferaw.supabase.co/functions/v1/handoff-*`; no cookies set on getwepark.com.

## Backend notes

- CORS: the functions default to allowing `https://getwepark.com` (verified live: OPTIONS and POST echo that origin). The
  `www.` host is NOT allowed unless `HANDOFF_ALLOWED_ORIGINS` is extended.
- No `apikey` header is needed (functions deploy with `--no-verify-jwt`; verified with a live request).
- Known contract gap: `handoff-depart/extend/cancel` require the pass `id`, but `handoff-claim` and `handoff-peek` do not return it.
  The page uses `id` from the claim response when present; until backend adds it, "I'm leaving now" shows a graceful error.
