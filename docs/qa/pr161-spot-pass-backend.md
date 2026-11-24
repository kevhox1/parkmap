# PR #161 Spot Pass backend QA — 2026-11-23

**Reviewed:** branch `feat/spot-pass-backend` at `610a741f`, against `docs/specs/qr-spot-handoff.md` Rev 2 (§3, §8, §9, §10, §14, §15)
**Scope:** `supabase/13-spot-handoffs.sql`, `13-spot-handoffs-test.sh`, edge functions `handoff-peek|claim|depart|extend|cancel|report`, `send-handoff-push`, `_shared/handoff*.ts`, `README-handoff.md`
**Verdict:** ✅ **APPLY-READY** with the flag seeded OFF (it is). Three 🟡 findings must be fixed **before `HANDOFF_ENABLED` is flipped to true** (they are `create or replace` / one-file fixes; re-running 13 is idempotent, verified). No 🔴.

## Summary
The schema is safe to paste into production: RLS and column grants hold under adversarial probing, secrets/tokens are stored only as sha256 hashes, every service RPC is `service_role`-only, `delete_my_account()` keeps every statement from migration 10, and 13 re-applies cleanly over live data without flipping the flag. The weaknesses are in abuse resistance, not exposure: the driver's cancel/depart can be locked out by the seeker through a rate bucket keyed on the (seeker-known) pass id; the 3-report suspension counts rows, not distinct reporters; and the IP rate limit trusts the client-controllable first `X-Forwarded-For` hop. Nothing here leaks location, identity, or tokens. Real APNs, pg_net, Vault and platform edge logging cannot be verified until after deploy (listed below).

## Test-run evidence
- `df -h /` = 15 GiB free before start (above the 8 GiB bar).
- Throwaway cluster: Homebrew `postgresql@16` (16.x), initdb under `~/Library/Caches/wepark-qa161-pg`, port 55461, unix socket only. **Stopped and the directory deleted; no process or directory remains.**
- `supabase/13-spot-handoffs-test.sh` (migrations 01-06 + 10 on the stub, 13 applied twice): **`RESULT: 182 passed, 0 failed`, exit 0** (matches the PR's claim; I counted 182 `PASS:` lines).
- `deno test supabase/functions/_shared/handoff_test.ts` (Deno 2.7.4): **11 passed, 0 failed**.
- `deno check` on all 7 entrypoints (`handoff-peek|claim|depart|extend|cancel|report`, `send-handoff-push`): **clean, rc 0 each**.
- My own probes (`probe.sh`, `probe2.sh`, scratch DB only, run as real `anon`/`authenticated`/`service_role` roles with a JWT-sub GUC): results in "Smoke tests run".

## Acceptance criteria checklist (spec §14, backend-relevant rows)
- [x] Flags off: functions return disabled — peek/claim/depart/extend/cancel/report RPCs return `{"disabled":true}` (-> 503); `create_handoff` raises 55000. Verified in test + probe2.
- [x] Second scan "already used"; bad/expired/used token or secret indistinguishable — peek/claim collapse to `{"status":"unavailable"}` 200; depart/extend/cancel to `{ok:false}` 200; verified by code read + probe (bad token, self-claim, used, expired armed row all `unavailable`/`ok:false`). Rate limit is the only distinguishable status (429, same body shape).
- [x] Unclaimed expiry 20 min; armed = `leave_at + 15`; >240 min rejected (241 min -> `invalid_leave_at`, 240 -> armed); extend cap 3 and horizon-from-claim; expired passes cannot depart (probe2: `ok:false` with stale-`armed` expired row and no sweep); purge 24 h (sweep step 4).
- [x] Depart/extend/cancel need the secret even with a valid token — `handoff_gate` (row lock, status armed, not expired, constant-time hash compare). Verified.
- [~] "Claimer tokens/secret are null once the row is terminal" — **secret: yes, always. Tokens: NOT literally** (30 min after `departed`, 2 min after seeker-cancel). Documented deviation, see Concern 1 and finding #5. Acceptable but the spec text must be amended.
- [x] No location/address/plate/username columns — column list dumped (`alias glyph seeker_display_name ... depart_source ...`); only opt-in first name.
- [~] Rate limits and 3-report suspension work; self-scan rejected; karma only on confirmed outcome from different user; caps/cooldown/idempotency; deletion removes rows — all work as coded (probes P4-P8, P16). Abuse-resistance gaps in #1-#3.
- [x] Account deletion removes handoff rows, reports, pair log, ledger rows (probe P16: 0|0|0).

## Findings

### 🔴 Blocking
None.

### 🟡 Significant (fix before flipping HANDOFF_ENABLED)

- **#1: Seeker can lock the driver out of Cancel / Depart / Extend (spec §9 #3 "driver can cancel anytime")**
  - Where: `13-spot-handoffs.sql:639`, `:661`, `:680` — `internal.handoff_rate_hit('depart'|'extend'|'cancel', p_id::text, 20, '1 hour')` runs **before** the secret is checked and counts every attempt, valid or not.
  - What: the pass `id` is returned to the seeker by `create_handoff` and readable in `spot_handoffs`. The seeker needs no secret to burn the driver's 20/hour budget by posting wrong secrets for that id. Probe P3: after 21 wrong-secret `handoff_cancel_claim` calls, the legit driver's cancel returned `{"rate_limited": true}`; same for depart.
  - Expected: a stranger who knows only the id must not be able to deny the secret holder the ability to cancel.
  - Repro (scratch SQL, as service_role): claim a pass; `for i in 1..21 { select public.handoff_cancel_claim('<id>','AAAAAAAAAAAAAAAAAAAAAA'); }` then `select public.handoff_cancel_claim('<id>','<real secret>');` -> `{"rate_limited": true}`.
  - Suggested fix (for the owner to choose): count only **failed** gate attempts per id (call the gate first, hit the limiter only on failure), or key on `(id, ip_hash)`, and always allow a valid secret through.
  - Owner: `@backend-data`

- **#2: 3-report suspension counts report rows, not distinct reporters; claimer-side reports are unauthenticated**
  - Where: `internal.handoff_record_report`, `13-spot-handoffs.sql:541-550`; `handoff_report` `:693-713`.
  - What: probe P4: one seeker account, three passes claimed by the same victim, three `report_handoff` calls -> victim row in `handoff_suspensions`. Probe P5: three `handoff_report(token, ...)` calls from rotating IP hashes with no account, against three passes of seeker D -> D suspended, `create_handoff` now raises `handoff_suspended`. The only uniqueness is `(handoff_id, reporter)`. Suspension has no expiry and no auto-lift.
  - Expected: spec §14 "3-report suspension works" does not define distinctness, but a single actor (or any scanner holding three of a seeker's QR codes) shouldn't be able to suspend someone alone; the control is a safety control, not a griefing tool.
  - Suggested fix: count `distinct` reporter identity (seeker-side: `seeker_id` of the reported handoff; claimer-side: claimer anon id when present, else require the claim first), and/or only count claimer-side reports from an armed pass that carry a verified claimer identity. Consider a suspension expiry.
  - Owner: `@backend-data` (+ tech lead on the product rule)

- **#3: IP rate limit keys on the client-controllable first `X-Forwarded-For` hop**
  - Where: `_shared/handoff.ts:136-143` (`clientIp`), used at `_shared/handoff_runtime.ts:66`.
  - What: peek (30/h/IP), claim (20/h/IP) and report (10/h/IP) limits are only as strong as the IP key. A client that sends its own `X-Forwarded-For: <random>` gets a fresh bucket per request if the platform appends rather than replaces. Token guessing is still infeasible (128-bit), so this is abuse/spam resistance (§9 #8), not an auth bypass. Opposite problem: mobile-carrier CGNAT in NYC will put many legit scanners behind one IP, so 30/h/IP may produce false 429s at scale.
  - Not verified: actual Supabase edge header behavior (cannot be tested offline). Post-deploy test: send 35 peeks with distinct forged `X-Forwarded-For` values; if none return 429, the limit is bypassable.
  - Suggested fix: prefer `cf-connecting-ip` (set by the CDN) over `x-forwarded-for`, or take the **last** XFF hop; consider a separate per-token bucket in addition to per-IP.
  - Owner: `@backend-data`

- **#4: Karma same-device guard is bypassed by omitting the push token**
  - Where: `handoff_claim`, `13-spot-handoffs.sql:600-603` (only checked when `p_push_token is not null` and the seeker has a registered token).
  - What: spec §10 "claimer nonce != any seeker device token". Probe P7: seeker E and claimer F (separate anonymous users, claim with a JWT but no push token) both earned karma (seeker +3, driver +5/+1). One person with two anonymous accounts on one phone passes, bounded only by the 3/day cap and 24 h unordered-pair cooldown. Also `source:"auto"` is client-asserted, so a Sybil pair can collect the +2 fallback with zero seeker action.
  - Severity note: the spec itself lists farming rings as a post-launch watch-list item, so this is 🟡 not 🔴. Mitigation suggestion: grant karma to a claimer only when a push token is present (and differs), or add the watch-list query now.
  - Owner: `@backend-data` / tech lead

### 🟢 Minor / nit

- **#5: Token retention deviates from spec §9 #13 / §14 literal text.** Secret hash is nulled at every terminal (verified). Push/activity tokens/topic: 0 s for expired / driver-cancel / no_luck / claimer-report; 2 min after seeker-cancel/suspend; 30 min after `departed` (nulled on confirm, on `send-handoff-push` completion via `handoff_clear_tokens`, or by the sweep). Probe: after seeker `cancel_handoff` row shows `secret_null=t tok=t fuse<=2m`. I agree with the design (the `thanks` push needs the token after a terminal state) but it makes the §14 criterion "claimer tokens/secret are null once the row is terminal" false as written. Action: tech lead amends spec §9 #13/§14 to state the fuse, and README/privacy-policy copy says "within 30 minutes". Retention is **only as reliable as the sweep** (see #6).
- **#6: Everything time-based depends on the `handoff-sweep` cron.** Expiry status flips, token fuses, fallback karma, and the 24 h purge are all in `internal.handoff_sweep()`. Without it: tokens would never be nulled except by confirm/clear; rows would never be purged (violating the 24 h promise); statuses stay `armed` after expiry (RPCs still re-check `expires_at`, verified probe2). pg_cron is already enabled in prod (02d, 03 rely on it), so risk is low. **README step 2 is wrong**: "if `create extension pg_cron` fails the earlier statements are still the important part" — the SQL Editor runs the paste as one transaction (migration 03 line 671-677 says exactly this), so a failure rolls back **everything**. Fix the README sentence. Add a post-apply check that `cron.job_run_details` shows `handoff-sweep` succeeding.
- **#7: Kill switch also disables the driver's Cancel.** With `HANDOFF_ENABLED=false` (DB or env) `handoff_cancel_claim` returns `{"disabled":true}` (probe2), so in an emergency stop an armed driver cannot cancel (the pass just expires on schedule). Consider letting cancel/depart-as-cancel succeed while disabled.
- **#8: `handoff_pair_log` retention is 48 h** (`:751`); the cooldown needs 25 h. It stores seeker/claimer user-id pairs, which is the closest thing to a social-graph record in this feature. Shorten to 25 h to match the "purged within 24 h" privacy copy.
- **#9: `show_name=true` uses the first word of `profiles.username`** (`:398-404`, up to 20 chars). A user whose handle is an email-ish or real surname string would broadcast it to anyone holding the QR. iOS should preview the exact name before enabling the toggle.
- **#10: Unpinned `https://esm.sh/@supabase/supabase-js@2`** in `handoff_runtime.ts:13` and `send-handoff-push/index.ts:32`. Matches existing functions (send-regular-push) so consistent, but floating major is a supply-chain/regression risk; pin to an exact version when convenient. No Deno std imports to pin.
- **#11: `readJsonBody` buffers the whole body before the length check when no `Content-Length` (chunked).** Platform caps apply; negligible.

### 💡 Out of scope (logged, not fixed)
- **Platform edge logs.** Supabase's own function logs record request metadata (path, status, headers sample) outside our code. The PR/README claim "no logging of IPs" is true for the function code only. Check the dashboard log entries post-deploy; token/secret travel only in POST bodies (not logged by platform) — good choice.
- **Anonymous suspensions are evadable** by creating a new anonymous session; suspension keys on `auth.users.id`.
- **Seeker spoof of "departed" semantics**: a claimer can send `depart` immediately after arming; seeker gets "pulling out now" with no truth guarantee. Inherent to the model (copy already says courtesy, not promise).
- **Spec amendment candidates**: freeze glyph slug list, Live Activity `content-state {phase}`, `topic` semantics, and the "must name columns" rule in spec §8.

## Contract conformance vs spec §8
| Item | Result |
|---|---|
| `create_handoff(show_name) -> {id, token, alias, glyph, expires_at}` | Match. Token 22 b64url chars from 16 random bytes (`extensions.gen_random_bytes`), only sha256 stored. |
| `handoff-peek {token}` | Match; byte-identical unavailable; read-only; rate counted. |
| `handoff-claim` | Match; atomic (`for update` + `status='created'`); secret 128-bit; `invalid_leave_at` decided before token lookup (not an oracle). |
| `handoff-depart/extend/cancel` | Match; `{ok}` shapes as spec. |
| `cancel_handoff`, `confirm_handoff_outcome` | Match; confirm return shape was unspecified, builder picked `{ok,outcome,seeker_points}`; replay returns `seeker_points:0`, never re-pays, never re-pushes (probe P8). |
| Data model | Superset of the §8 sketch; extra columns documented; no coords/addr/plate. |
| Additive (`handoff-report`, `report_handoff`, `get_my_handoff_karma`) | Not in §8; needed for §9 #9; fine. See #2 for the report semantics. |
| Edge-function `Idempotent re-apply` of 13 | Verified: two applies (test) plus a third over live data (probe2) — flag value and live row preserved; cron registered once. |

## Evaluation of the builder's "contract concerns" (PR lists 9)
1. **Tokens vs thanks push (short fuse):** Agree, with the spec amendment in #5. Verified fuse behavior; retention bounded at 30 min and depends on the sweep (#6).
2. **Driver cancel leaves status `armed`:** Agree. It is the only way the seeker's own read can't reveal the cancel. Cost: seeker waits to expiry (up to leave_at+15) — which is what the spec says. Verified probe2: seeker `cancel_handoff` after driver cancel pushes nothing.
3. **Retry after lost depart response returns `{ok:false}`:** Agree (secret nulled at terminal per §9 #12/#13). iOS must treat `ok:false` on a retry as "may have been sent" and not show an error.
4. **Self-scan returns plain `unavailable`:** Agree for the backend; a distinguishable response would be an oracle. The seeker's device can recognise its own token locally for the "That's your own pass" copy. Probe P15 confirms identical output.
5. **First name has no source:** Agree with the opt-in/auto-handle-suppression approach; see #9 (preview the name).
6. **Karma needs claimer identity (optional JWT):** Agree. Web-fallback claims silently earn no karma for either side; product should know. `auth.getUser(jwt)` validates the token server-side; a public anon key resolves to no user (code-read, not run).
7. **Unspecified pieces picked by builder** (glyph slugs, `content-state {phase}`, topic = bundle id, ActivityKit topic `<topic>.push-type.liveactivity`): Agree; need iOS alignment. The APNs topic derivation is correct per Apple (`<bundle>.push-type.liveactivity`); topic is allow-listed at claim (`allowedTopics`) and again at send, push/activity tokens are hex-validated before they can reach an APNs URL path. Claimer tokens go to the function's single `APNS_ENV`; a TestFlight clip token sent to a sandbox function would silently fail (deploy-time check).
8. **Clients must name columns / `select *` denied:** Agree, and I verified it (42501 for `select *`, `token_hash`, and also for **filtering** on `claimer_anon_id`, so there is no oracle through filters). iOS note: filters like `.eq("seeker_id", ...)` also fail with 42501; filter on `id`/`status` only, RLS already scopes to the seeker.
9. **`create_handoff` cancels the live pass; reports counted over 30 days:** Agree on the first (partial unique index enforces one active). The second is where #2 applies. Documented lift command in the README is correct.

## Spec §9 safety walk (backend items)
| # | Result |
|---|---|
| 1 opt-in | Pass: only `handoff_claim` arms; depart/extend/cancel act on `armed` only. |
| 2 expiry/one-time | Pass: atomic claim; 20 min TTL; 240 min cap; extend cap 3. |
| 3 silent driver cancel | Pass in design, **weakened by #1** (lockout) and #7 (kill switch). |
| 4 no identity | Pass: seeker column grant excludes claimer columns; claimer id never returned. |
| 5/6 no location | Pass: no location columns/params anywhere; payloads text-only (unit-tested). |
| 7 anti-stalking | Pass: QR token cannot depart/extend/cancel (secret gate, probe). |
| 8 rate limits | Present; see #1 (id bucket abusable) and #3 (IP key). |
| 9 reporting | Present; see #2. |
| 10 security basics | Pass: 128-bit, hash at rest, constant-time compare (`ct_equal`, `safeEqual`), uniform bodies, CORS allow-list (default `https://getwepark.com`, reflects only listed origins), env + DB kill switch; IP HMAC'd (key = `HANDOFF_IP_SALT` or service key), only 16 bytes of digest stored, rows purged after 2 h. |
| 12 per-claim secret | Pass. |
| 13 tokens at terminal | Partial: see #5. |
| 14 thanks positive-only | Pass: `thanks` pushed only after `got_spot`; `stateAllows` double-gates. |
| 11, 15, 16 | Client/Kevin side; not in this PR. |

## Edge-function static review
- **Auth model:** six public functions are `--no-verify-jwt` by design; each validates the token/secret in the DB. `send-handoff-push` is deployed with JWT verification **and** compares the bearer to `SUPABASE_SERVICE_ROLE_KEY` in constant time (`safeEqual`, `send-handoff-push/index.ts:58`) so the public anon key (a valid project JWT) gets 401.
- **Input validation:** strict regexes (22-char b64url, UUID, hex APNs/activity tokens, enum source/reason), 4 KB body cap, topic allow-list. Validation failures that depend only on request shape return 400; shape-valid-but-wrong token state always returns the uniform body.
- **Error uniformity:** the only distinguishable statuses are 400 (malformed), 429 (rate), 503 (disabled), 500 (server) — none depend on token/secret state.
- **Secrets in code:** none. No logging of tokens/secrets/IPs in function code; `send-handoff-push` logs kind + counts only.
- **APNs topic:** `<bundle>.push-type.liveactivity` correct; clip detection `.Clip` suffix; `target-content-id` added for clip alerts.
- **pg_net dispatch:** body is only `{kind, handoff_id}`; tokens are re-read by the function; dispatch is fail-open and runs post-commit.
- **Imports:** `esm.sh/@supabase/supabase-js@2` unpinned (#10).

## Kevin's apply steps (README-handoff.md) — review
Order and prerequisites are correct: 10 first (13 replaces `delete_my_account()`; confirmed 13 keeps every statement of 10 — diffed statement-by-statement, only comments differ — and appends the five handoff deletions; no other migration redefines it), Vault `service_role_key`, pg_cron/pg_net already in prod, SQL then functions, flag stays off, never add to realtime. Fixes/additions needed:
1. **Fix the false "earlier statements still matter" sentence in step 2** (#6): a failed `create extension` rolls back the whole paste in the SQL Editor.
2. Add to checklist A: `select name from vault.decrypted_secrets where name='service_role_key';` (currently only mentioned in prose) and `select * from cron.job_run_details where jobid=(select jobid from cron.job where jobname='handoff-sweep') order by start_time desc limit 3;` after 2 minutes.
3. Checklist F (31 peeks) does not prove IP-key integrity; add the forged-`X-Forwarded-For` variant (#3).
4. Add a pg_net smoke: after the end-to-end `claim`, `select status_code, left(content,80) from net._http_response order by id desc limit 3;` (should be 200 from `send-handoff-push`) — otherwise a Vault/key mismatch fails silently by design (fail-open).
5. Add cross-user RLS check: user B `select count(*) from spot_handoffs` returns 0 for A's pass.
6. `APNS_ENV` caveat is already documented; add "send-handoff-push must be deployed with JWT verification AND the Vault key must equal `SUPABASE_SERVICE_ROLE_KEY` (rotated or new-style `sb_secret_*` keys would 401)".
7. Verification G: also test with no Authorization header (gateway 401) in addition to the anon key.

## Smoke tests run (all on the throwaway scratch DB; nothing touched production)
| Probe | Outcome |
|---|---|
| P1 RLS: user B reads A's pass | 0 rows. |
| P1 `select *`, `select token_hash`, filter on `claimer_anon_id`, update, delete (as owner) | all `42501`. anon select `42501`. |
| P1 authenticated select/update on `handoff_config/reports/suspensions/pair_log/rate_events` | all `42501`. |
| P1 authenticated calls `internal.handoff_sweep()`, `public.handoff_peek`, `handoff_clear_tokens` | `42501` (schema/function). `has_schema_privilege(auth/anon,'internal','usage')` = f/f. |
| P2 token format | 22 chars; only `token_hash`/`claimer_secret_hash` stored; no plaintext token column. |
| P3 seeker spams wrong-secret cancel x21 then legit driver cancel/depart | **`rate_limited` (finding #1)**. |
| P4 same seeker reports same victim across 3 passes | victim suspended (finding #2). |
| P5 3 anonymous claimer-side reports on one seeker | seeker suspended, `create_handoff` raises `handoff_suspended` (finding #2). |
| P6 report with bogus token | `{ok:false}` (note: valid-token report returns `{ok:true}`, an oracle but destructive, 128-bit). |
| P7 karma with no claimer push token, different users | both earned (finding #4). Replay confirm: `seeker_points 0`, no double pay; flip to `no_luck`: `ok:false`. |
| P9 realtime publication membership of handoff tables | 0 rows. |
| P10 leave_at 241 min / -11 min / 240 min | invalid / invalid / armed. |
| P11 shared `unknown` IP bucket | 31st peek `rate_limited`. |
| P12/P14 tokens after depart + confirm; sweep with expired fuse | nulled on confirm; sweep nulls expired fuse. |
| P15 self-claim; peek after valid peek | self-claim `unavailable`; peek of unclaimed own token `open` (expected). |
| P16 `delete_my_account` | spot_handoffs/pair_log/ledger rows for the user = 0. |
| probe2 re-apply 13 over live data | flag stays `true`, row survives, no error. |
| probe2 seeker cancel of armed pass | secret null, tokens kept with fuse <= 2 min, later depart `ok:false`. |
| probe2 claimer report (`unsafe`) | row `suspended`, tokens nulled immediately. |
| probe2 kill switch | driver cancel returns `{disabled:true}` (finding #7); seeker `cancel_handoff` still works. |
| probe2 expired-armed row, no sweep | depart `ok:false` (RPC re-checks `expires_at`). |
| probe2 `handoff_rate_events` keys | `<bucket>|<uuid or ip-hash>`; no raw IPs (test passes 'ip' literal; the real function passes an HMAC). |

## What can ONLY be verified after deploy
- Real APNs delivery (alert to seeker, `thanks` alert to driver, ActivityKit push-to-end, silent `handoff_ended`), including TestFlight vs sandbox env mismatch and clip `target-content-id` acceptance.
- `pg_net` -> `send-handoff-push` dispatch with the real Vault secret (fail-open means failures are silent; check `net._http_response`).
- `pg_cron` actually running `handoff-sweep` each minute (`cron.job_run_details`).
- Header behavior of the Supabase edge in front of the functions (`X-Forwarded-For`/`cf-connecting-ip`) and platform-level log contents.
- `auth.getUser(jwt)` resolving a real clip/app anonymous session (claimer karma attribution).
- Gateway behavior of `--no-verify-jwt` vs default on all seven functions.
- CORS preflight from `https://getwepark.com` against the real functions.

## What's working
- Privilege surface is tight and verified, not just asserted: RLS + column-level grants (including denial of filter oracles), deny-all ancillary tables, service RPCs service-role-only, `internal` schema unreachable, every definer function `search_path=''`.
- Secret handling: 128-bit values, hash-only at rest, constant-time comparisons in both layers, uniform responses, 400 only for token-independent shape errors (the `invalid_leave_at` ordering is a thoughtful no-oracle choice).
- Terminal-state discipline: secret hash nulled at every terminal; token fuse is bounded, documented, and has two clear-paths plus a sweep backstop.
- `delete_my_account()` replacement preserves every migration-10 statement and adds the new deletions; ACL unchanged.
- Idempotent migration: re-apply over live data keeps flag and rows; flag defaults off; cron registered last and by fixed job name.
- Atomic claim under parallel load and idempotent karma ledger are covered by the test suite.
- Clear, honest PR notes: the 9 concerns are real and mostly well-judged.

## Recommendation
Kevin can apply `13-spot-handoffs.sql` now (flag OFF, nothing user-facing changes). Before enabling: `@backend-data` fixes #1 (rate bucket), #2 (distinct reporters), #3 (IP key), amends README per the apply-steps list (including the false rollback claim), and the tech lead amends spec §9 #13/§14 for the token fuse. Re-run `13-spot-handoffs-test.sh` after those fixes (extend it with the P3/P4/P5 probes above) and request a Pass 2 post-deploy covering the "only after deploy" list.



---

## Re-verification after fixes (2026-11-24)

**Reviewed:** `feat/spot-pass-backend` at `7ea71968` (fix commit on top of `610a741f`)
**Verdict:** ✅ **APPLY-READY** to production (flag stays OFF). No 🔴, no new blockers. All four prior 🟡 are fixed and re-probed. One 🟡 residual (R1, suspension Sybil) and two 🟢 items are listed; none gates the apply. R1 should be decided before `HANDOFF_ENABLED` is flipped.

### Evidence
- `df -h /` = 15 GiB free (above the 8 GiB bar). Throwaway Homebrew `postgresql@16` cluster at `~/Library/Caches/wepark-qa161b-pg`, port 55462, unix socket only; nothing touched in production. **Cluster stopped and directory deleted; no process remains.**
- `supabase/13-spot-handoffs-test.sh`: **`RESULT: 200 passed, 0 failed`**, rc 0, zero FAIL lines.
- `deno test _shared/handoff_test.ts`: **12 passed, 0 failed**. `deno check` on all 7 entrypoints: rc 0 each (this also proves `esm.sh/@supabase/supabase-js@2.119.2` resolves).
- **Full-stack apply (the gap the harness leaves):** a second scratch DB with the stub + **01, 02, 02b-02g, 03-12 all applied verbatim**, then **13 three times**: every step clean (`ON_ERROR_STOP`, empty output). So 13 applies on top of 01-12, including 11 (coverage_requests) and 12 (storage policy; applied against the stub only, and already live in prod, so moot).
- **Upgrade path:** a third DB with 01-12 plus the OLD 13 (`610a741f`), seeded with a legacy suspension (no `expires_at` column then) and a legacy report, then the new 13 applied twice: both clean; exactly one `handoff_record_report` overload (the 4-arg one is dropped, no ambiguity); legacy suspension stays **active** (`expires_at` NULL = indefinite); legacy report survives with `reporter_user_id` NULL (counts as the single anonymous voice); one cron row; flag still `false`. Re-apply of the new version is idempotent from either prior shape (prod has no prior shape anyway).
- 13's `delete_my_account()` body diffed against 10's: every statement of 10 is present (only reordered; the `profiles` delete moved after the handoff deletions, which FK order requires); additions are the five handoff deletions. 11 and 12 do not redefine it (12 only mentions it in comments; `coverage_requests.user_id` is `ON DELETE SET NULL`). Live probe: a reporter deleting their account removes their `handoff_reports` rows and their `auth.users` row.

### Prior 🟡 findings, each re-probed on the live scratch objects

| # | Probe | Result |
|---|---|---|
| **#1 driver lockout** | 60 wrong-secret calls each to depart, extend and cancel for one pass id (180 attempts), then the real secret | Wrong secrets still get `rate_limited` after 20 (fail bucket), but the **real secret then succeeds**: `extend` -> `{"ok":true,...}`, `depart` -> `{"ok":true}`. The constant-time secret gate runs before any limiter; the success path uses a separate 60/h bucket reachable only with the secret. **FIXED.** A flood cannot affect the right secret. |
| **#2a one reporter, many passes** | seeker V reports 3 passes all claimed by X | X **not** suspended (3 report rows, 1 distinct reporter). **FIXED.** |
| **#2b anonymous reports** | 5 JWT-less `handoff_report(token,...)` with rotating IP hashes against one seeker | **Not suspended** (5 rows count as one voice). **FIXED.** |
| **#2c legit path + expiry** | 1 anonymous + 2 distinct identified claimers | After anon + 1 identified: not suspended. After the 2nd identified: suspended, `expires_at` = now + 7 days, `create_handoff` raises `handoff_suspended`. Force-expire the row: `create_handoff` works again; 1 new report does not re-suspend; 3 new voices after the old `suspended_at` re-suspend and refresh `suspended_at/expires_at`. Expiry and re-suspension logic correct (`v_since = greatest(30 d ago, last suspended_at)`). |
| **#3 forged XFF** | static review + unit tests | `clientIp` order: `cf-connecting-ip`, else LAST XFF hop, else `unknown`. Tests assert `"6.6.6.6, 203.0.113.9"` -> `203.0.113.9`, single hop, cf beats XFF, empty -> `unknown`. First-hop spoofing is gone in code. **Real-edge behavior cannot be verified offline** (see watch item 3). |
| **#4 karma guard** | confirm `got_spot` with: aged distinct claimer, no push tokens; claimer account 1 h old; seeker and claimer sharing a registered `device_push_tokens` token while the claim carries NO push token; claimer NULL (no JWT) | Aged distinct, no tokens: karma paid (the documented residual). **Fresh claimer: 0 karma. Shared registered device: 0 karma (no longer depends on the claim request). No-JWT claimer: 0 karma.** `handoff_karma_pair_ok(NULL,NULL)` and unknown uuids -> false. Fallback reward uses the same guard (code read, `handoff_reward_driver`). **FIXED** within the stated limit. |

### Try-to-break results
- Fail bucket keyed by pass id: floods fill only the `<fn>_fail` bucket; the success bucket needs a valid gate pass, so a non-holder cannot burn it. Cost note: every attempt still inserts a `handoff_rate_events` row (the 180-attempt flood left 183 rows) until the 2 h sweep; bounded by request rate, as before. Not a finding.
- Anonymous cap: "all unidentified = one voice" holds. A self-report (reporter == subject) is stored as unidentified, so it cannot add a distinct voice.
- `handoff_karma_pair_ok` edges: null seeker, null claimer, equal ids, fresh account, shared token, unknown ids: all false.
- `reporter_user_id`: nullable FK `on delete cascade`, added with `if not exists`; deny-all grants unchanged (0 client privileges on reports/suspensions).

### Regression (first-pass items re-confirmed)
200/200 harness covers RLS/column grants, hash-only storage, uniform responses, secret nulling, ACLs. Re-checked by hand on the full-stack DB: RLS on all 6 tables; **0** handoff tables in any publication (realtime exclusion); both new internal functions owner-only; `internal` schema usage false for `authenticated`; **0** handoff functions lacking SECURITY DEFINER + `search_path=''`. Edge auth unchanged by the fix commit (diff touched only `clientIp`, `readJsonBody`, a doc comment in `handoff-report`, and the esm pin).

### Production-readiness of the apply step
- `create extension if not exists pg_cron;` is the last statement. pg_cron is already enabled in prod (02d/03), so it is a no-op and `cron.schedule('handoff-sweep', ...)` upserts by name (one row after 3 applies). README now correctly says a failure rolls the whole transaction back. Real pg_cron is stubbed in scratch, as before.
- README steps (order, SQL then secrets then deploy with six `--no-verify-jwt` and `send-handoff-push` with JWT verification, flag off, no realtime, checklist A/A2/A3/C-G/F2, e2e 1-8) are complete and consistent with the code; all seven apply-step fixes from my first pass are in.

### Remaining findings
- 🟡 **R1: Suspension Sybil.** Any account of any age counts as a distinct reporter. Probe: 3 fresh (1-minute-old) anonymous accounts each claim one of victim V's passes and report -> V suspended for 7 days. Anonymous sign-in is free, so one actor needs 3 accounts instead of 1. Bounded by the 7-day expiry and the claim rate limit; flag is OFF. Suggestion: count a reporter only if the account is >= 24 h old (reuse the karma rule). Decide before enabling. Owner: `@backend-data` + tech lead.
- 🟢 **R2: stale comment** at the bottom of `13-spot-handoffs.sql` ("Cron -- LAST on purpose ... the paste above is the part that matters; re-run only this block") contradicts the README (one transaction; whole file rolls back). Comment-only.
- 🟢 **R3: acknowledged residuals** from the PR body (kill switch also blocks driver Cancel, iOS name preview, no per-IP limit on unauthenticated depart/extend/cancel, same-phone Sybil pair with no push token and >24 h old). Not regressions.

### Watch list for the production apply
1. Apply 13 as one paste with the flag OFF; expected: no error. Then checklist A/A2/A3: flag `false`, one `handoff-sweep` cron row, ACL posture, 6 tables RLS true, Vault `service_role_key` present, and after ~2 min `cron.job_run_details` shows `succeeded`.
2. If the paste errors, the whole transaction rolled back; nothing is half-applied. Fix and re-run.
3. After deploying functions, run F2 (forged XFF) AND the opposite check: from two different networks confirm peeks do NOT share one bucket. If the edge appends an internal proxy hop and sends no `cf-connecting-ip`, "last XFF hop" would key every user to the same proxy IP and cause global false 429s. Both directions matter before enabling the flag.
4. After the first end-to-end claim, `net._http_response` should show 200 from `send-handoff-push` (dispatch is fail-open; a Vault/key mismatch fails silently).
5. Karma test accounts must be >= 24 h old and not share a registered push token; a day-one account earning nothing is expected.
6. Keep `handoff_*` tables out of `supabase_realtime`.
7. Real APNs delivery, `auth.getUser(jwt)` on real anonymous sessions, CORS preflight from getwepark.com, and platform log contents remain post-deploy-only verifications.
