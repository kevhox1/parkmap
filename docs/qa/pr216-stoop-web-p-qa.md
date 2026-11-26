# PR #216 Stoop web /p preview QA — 2026-11-26

**Reviewed:** branch `feat/stoop-web-p-preview` at `c693ebda`, against `web/getwepark/p/README.md` and the PR body
**Verdict:** MERGE-WITH-FOLLOWUPS (no blockers; default page proven unchanged)

## Summary
The default `/p` is byte-for-byte the same behavior and pixel-identical in render. Stoop CSS is all scoped to `html.stoop`; Stoop JS is gated on a flag set only by `?stoop=1` (or the tab-scoped `wp_stoop` key). No new network, resources, cookies or payload changes. Only nits and one preview-environment gap.

## Default-unchanged proof
- Diff read: head script (index.html:14-26) runs always but only reads `location.search` and sessionStorage `wp_stoop`; with no `stoop=1` it returns before adding the class. Unchanged API calls (peek/claim/depart/extend/cancel/report), payloads, `#t=` read, `replaceState` scrub (line ~242, still after the head script), `KEY` sessionStorage use, `credentials:'omit'`. New JS in default mode: `setGlyphs` also writes the hidden `#glyph-s` (st-only, display:none, so not read by AT); `$('cdbox').hidden = nw` on a display:none element; tick stays 20000ms; confetti colors unchanged. Added DOM (`.who`, `.cd`, `.sentat`, `.stamp`) is `.st-only{display:none}` by default.
- Render diff: served `origin/main` and the PR from scratch dirs, headless Chrome 390px wide, 7 fake states (open, open+name, armed, sent, unavailable, disabled, error) x light/dark x 100%/200% root font = 28 pairs, reduced-motion forced, pixel-diffed with PIL. 24/28 byte-identical; the 4 differing (armed, both schemes, both zooms) are confined to the clock-time text, and re-shooting main vs PR within the same minute gave zero diff (minute-roll, not a change).
- Not diffed by pixels: interactive picker and report screens (code paths unchanged by diff; builder's before/after shots show identical).

## Preview switch / CSP / privacy
- [x] `?stoop=1` adds `html.stoop` and sets color-scheme `light dark`; works with `?fake=1`, with `#t=` (dump-dom confirmed); `?stoop=0` removes it; `wp_stoop` is sessionStorage only (never sent).
- [x] URL scrub unaffected (flag read in head before scrub; scrub line unchanged).
- [x] No new fetches or resources; no fonts (system rounded stack); inline `<script>`/`<style>` only, within the existing CSP (`script-src/style-src 'unsafe-inline'`). `getp.innerHTML` assigns a static literal (no XSS surface). `vercel.json` untouched.
- [x] No cookies, analytics, identity, location.

## Stoop mode
- [x] Chips "About 10 min / About 30 min / About 1 hour"; no karma wording (Get card copy replaced); buttons min 60-68px; focus-visible outline; contrast looks fine in light and dark in the screenshots (cream/ink, mu text on surface); countdown aria-hidden; status lines still role=status; reduced-motion rule unchanged (confetti hidden, sparkles shown).
- Viewed screenshots: light waiting, dark armed, light sent, dark picker, light report. Layouts clean.

## Findings
### Significant
none.

### Minor
- **#1 (preview env):** Vercel preview is behind Vercel SSO (302 to vercel.com/sso-api), so criterion 5 was not verified; local fake-mode only. After merge, check `https://getwepark.com/p?fake=1` still default. Not a code issue.
- **#2:** `<meta name="theme-color" content="#0E0F24">` (index.html:8) is not switched in Stoop, so Safari chrome stays dark on the cream light page. Follow-up before making Stoop default.
- **#3:** In the picker screenshot (dark) the time list is clipped mid-row (9:30/9:45) by the scroll container above the primary button; check it is scrollable on device (likely pre-existing max-height).
- **#4:** `.link` "Back" on the report screen is left-aligned while `Not now`/`Not leaving` are centered (index.html:~100). Cosmetic.
- **#5:** sessionStorage is copied into tabs opened via window.open, so a Stoop tab can propagate the key; harmless for a preview.
- Not verified: VoiceOver on a real device; real-token (`#t=`) network flow in Stoop beyond DOM class check.

## Smoke tests run
Local http servers for main and PR; headless Chrome fake-mode screenshots and pixel diff (above); dump-dom for 5 URL variants; `gh pr checks 216` (Vercel pass); curl of the preview (SSO-gated).

## What's working
Tight scoping: the entire feature is additive and gated, with a sensible tab-scoped flag and no new surface.
