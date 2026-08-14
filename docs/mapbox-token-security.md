# Mapbox Token Security — Findings + Kevin's Dashboard Checklist

**Status: investigated 2026-08-13. Resolves open-items.md #16 ("Mapbox token restriction —
bundle-ID / URL scoping").** Written by `@backend-engineer` after Kevin approved the item as a
security-hygiene backlog task carried since the Drive Mode v3 (W8.5a) work.

**Bottom line up front:** the two-token split this repo has quietly relied on since W8.5a
(2026-05-20) is the *correct* architecture, and the code/repo side of it is already adequate — no
code change is needed. The literal task as it has been worded in `HANDOFF.md` and
`docs/drive-mode-scope-spec.md` since W8.5a ("bundle-ID restriction … via Mapbox's iOS SDK token
restriction") describes **a Mapbox dashboard feature that does not exist.** That's very likely why
this item has been re-carried, unresolved, across ~15 HANDOFF entries and 3 months: there is
nothing in the Mapbox dashboard matching that description to click. This doc corrects the record
and replaces it with the checklist that Mapbox's actual token model supports.

## 1. Is the iOS token the same as the PWA's, or separate?

**Separate, by design and by evidence — though only Kevin can give the final confirmation, since
the value lives outside this repo.**

- `tracker-config.js:15` ships the PWA's token in client-side source. Per `HANDOFF.md` ("Mapbox
  token (Drive Mode v3)" bullet under Live infrastructure), it was created 2026-05-01 and is
  **URL-restricted at Mapbox to `kevhox1.github.io` + `localhost:8765`.**
- `ios/WePark/Config.xcconfig` (gitignored — `ios/WePark/Config.xcconfig.example` is the committed
  template) holds the iOS token. It does not exist anywhere in this VPS checkout or in git
  history; it lives only on Kevin's Mac.
- `docs/drive-mode-scope-spec.md` §4 (the spec that scoped W8.5a) explicitly told the engineer
  **not** to reuse the PWA token: *"The existing Mapbox token in `tracker-config.js` … cannot be
  reused for iOS native HTTP calls — the iOS app's requests will not come from those URLs."*
- Every QA pass since W8.5a that touched `RouteService.swift` ran a token-hygiene grep
  (`grep -r "pk.eyJ" ios/`) and consistently found **zero committed token bytes** — see
  `docs/qa/w8.5a-pass-1-2026-05-20.md`, `docs/qa/w8.5b-pass-1-2026-05-20.md`,
  `docs/qa/w8.5c-pass-1-2026-05-23.md`, `docs/qa/w8.5d-pass-1-2026-05-31.md`,
  `docs/qa/community-1.0-ios-pr36-qa.md`, `docs/qa/tier3-pr39-qa.md`, `docs/qa/tier3-pr40-qa.md`,
  and others. `Config.xcconfig` exists on disk (gitignored) but is never staged.
- **Mechanical confirmation that a shared/URL-restricted token would not work here:** Mapbox's own
  troubleshooting docs state that a URL-restricted token returns an error for requests with **no**
  `Referer` header, and separately that *"URL restrictions are only compatible with browser-based
  requests… not in Android, iOS or Navigation SDKs. Adding a URL restriction to a token makes it
  unusable by a mobile application."* `RouteService.swift`'s `URLSession.data(from:)` call sends
  no `Referer` header (native `URLSession` requests never do). If iOS's `Config.xcconfig` held the
  *same* URL-restricted PWA token, every Directions call would 403. The W8.5a HANDOFF entry records
  a **live smoke test returning HTTP 200 with a valid 5.3km/23min route** — direct evidence the
  token in `Config.xcconfig` was not (and structurally could not have been) the URL-restricted PWA
  token at that time.
- **What Kevin should still verify** (5 minutes, can't be done from the VPS): open
  `ios/WePark/Config.xcconfig` on the Mac and confirm the `MAPBOX_ACCESS_TOKEN` value's prefix
  differs from the `mapboxToken` value in `tracker-config.js` (compare first ~20 chars — do not
  paste full tokens anywhere). If they somehow match today, create a new dedicated public token for
  iOS per §3 below and swap it in.

## 2. What restriction is actually appropriate for each token?

| Token | Used for | Appropriate restriction |
|---|---|---|
| PWA (`tracker-config.js`) | Raster tiles (Leaflet `styles/v1/mapbox/navigation-day-v1`), Search geocode suggest/retrieve, Directions — all fired from the browser | **URL restriction** to `kevhox1.github.io` + `localhost:8765`. Already done per `HANDOFF.md`. Browser requests reliably carry a `Referer` header, so this is the correct and effective control. **No action needed.** |
| iOS (`Config.xcconfig` → `RouteService.swift`) | Directions API only, native `URLSession` | **No URL restriction** (would break it — see §1). The correct control for a token embedded in a compiled, distributable binary is **scope minimization**, not app-identity restriction — see §3. |

Mapbox's token model, confirmed against current (Aug 2026) Mapbox documentation
([How to use Mapbox securely](https://docs.mapbox.com/help/dive-deeper/how-to-use-mapbox-securely/),
[URL restrictions for access tokens](https://blog.mapbox.com/url-restrictions-for-access-tokens-5f7f7eb90092),
[Token management](https://docs.mapbox.com/accounts/guides/tokens/)):

- **URL restrictions** exist and are dashboard-configurable, but are documented as web-only —
  explicitly incompatible with native SDKs / native HTTP calls.
- **Scopes** exist and are dashboard-configurable per token: a token can be limited to public
  scopes only (styles/tiles/fonts/datasets read + Directions, which ships under the default public
  scope set) with all secret scopes unchecked. This is the correct lever for a native-app token.
- **There is no "bundle ID" / "application ID" restriction** for Mapbox tokens, unlike (for
  contrast) Google Maps API keys, which do support Android package-name / iOS bundle-ID
  restriction. Mapbox's own docs for open-source iOS/Android apps recommend keeping the token out
  of the public repo (which this repo already does) rather than any app-identity binding, because
  no such binding exists on their platform.

This means the phrase "bundle-ID restriction" in `docs/drive-mode-scope-spec.md` §4 (written
2026-05-18, before implementation) was a factual error at the point it was written, not a
regression — no evidence exists that Mapbox ever offered this and later removed it. See the
correction landed alongside this doc.

## 3. What can be changed in the repo vs. what needs Kevin in the Mapbox dashboard

**Repo side — already adequate, no change shipped in this PR beyond docs:**
- `.gitignore:17` excludes `ios/WePark/Config.xcconfig`.
- `ios/WePark/Config.xcconfig.example` is the committed template with no real token.
- `ios/WePark/WePark/Services/RouteService.swift` reads the token from `Bundle.main` /
  Info.plist only — never hardcoded (see file header comment, unchanged, correct).
- `tracker-config.js` shipping a public `pk.*` token client-side is intended Mapbox usage for a
  URL-restricted token (per Mapbox's own public-token model) — not a leak.

**Kevin's checklist — Mapbox dashboard, both items are new/renamed, not literal continuations of
the old "bundle-ID restriction" phrasing:**

1. Log into the Mapbox account dashboard → Tokens.
2. Confirm the PWA token (prefix `pk.eyJ1IjoibW9zZWhvbnNl…`, matches `tracker-config.js:15`) still
   shows URL restrictions `kevhox1.github.io` and `localhost:8765`. No change — just confirm it's
   still there (tokens can be edited by anyone with dashboard access, so this is a "did it survive"
   check, not new work).
3. Identify the iOS token (the value currently in your local `ios/WePark/Config.xcconfig`, by
   prefix). Rename/label it clearly in the dashboard, e.g. **"WePark iOS — Directions"**, so it's
   distinguishable from the PWA token in your token list going forward.
4. On the iOS token: open its **Scopes** section. Confirm only default **public** scopes are
   checked and **no secret scopes** are checked. (Public scopes cover the Directions API call this
   token is used for — no separate "Directions" checkbox exists; it's part of the public scope
   set.) If the token was created via "quick create" it may already default to public-only —
   just confirm, don't need to recreate unless it's wrong.
5. Do **not** add a URL restriction to the iOS token — per §2 above, that would break every
   Drive Mode Directions call in production. If the dashboard UI offers to add one, decline.
6. There is no bundle-ID / application-ID field to fill in for this token — confirmed absent from
   the current Mapbox dashboard (§2). Don't spend time hunting for it.
7. Optional ongoing hygiene: Mapbox's Statistics page (per-token request graphs) is the practical
   substitute for app-identity restriction on an embedded native token — an unexpected spike would
   be the signal that the token leaked out of the compiled binary. No action needed now; just know
   it's there if `docs/open-items.md` #17-style alerting work ever extends to this.

No token rotation is needed as part of this — nothing here found evidence of a currently-exposed
token. (A one-off incident during W8.5a where a subagent briefly inlined the literal token into a
QA report draft was caught and redacted before any commit — see `HANDOFF.md` "Mapbox token
housekeeping" note from that session. No live leak exists today; confirmed via
`git log --all -p -- '*.md' | grep 'pk\.eyJ'` returning only the one known, intentionally-public
PWA token string.)

## 4. Follow-ups for other agents

None. This is a docs-only backend item; it does not touch `index.html`'s Supabase provider or
`tracker-config.js`'s Supabase fields, and does not touch any Swift source. `@pwa-maintainer` and
`@ios-engineer` do not need to change anything as a result of this investigation.
