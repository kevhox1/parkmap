# WePark Backend Options

## Repo reality check

This codebase is a very static front end right now:

- one giant `index.html` with inline JS/CSS
- deployed on GitHub Pages
- already comfortable with browser `fetch`, `localStorage`, and client-side state
- no existing server, build system, or auth layer

So the best backend is not the most elegant long-term architecture. It is the one that gets real multi-user reports working fast without forcing a rewrite.

## Bottom line

**Recommendation: use Supabase first.**

It is the fastest practical path to a real product for this repo because it gives you:

- hosted Postgres
- realtime subscriptions
- auth that can start soft and get stricter later
- row-level security and moderation controls
- zero need to move off GitHub Pages
- an easier path than Firebase once you want admin tools, SQL queries, report expiry, confirmations, and moderation

If you wanted the absolute fastest hack for just a live feed with almost no admin logic, Firebase is close. But for **live reports + comments + soft login + moderation**, Supabase is the better MVP-to-real-product bridge.

## Quick ranking

### 1) Supabase, best overall fit
**Best for:** fastest viable product that still has a sane path forward.

**Why it fits this repo**
- Works from a static site. Just include the client SDK and keys in the front end.
- No custom server needed.
- SQL is a better fit than document stores for reports, comments, confirmations, expiry windows, and moderation.
- Realtime is good enough for this use case, especially if the first version is Manhattan-only and low volume.
- Easy to inspect data manually in the dashboard when debugging early MVP issues.

**Pros**
- Very low wiring cost from GitHub Pages
- Realtime subscriptions for new/updated reports and comments
- Postgres tables make TTL, ranking, and moderation much easier
- Built-in auth, including anonymous or magic-link style flows
- Storage is there later if photo reports matter
- RLS gives you a real safety layer instead of trusting the browser

**Cons**
- You must get RLS right or you can create a mess fast
- Realtime is solid, but not as effortless as Firestore for pure live-feed UX
- Abuse prevention still needs work, auth alone is not moderation
- Anonymous/public client keys are normal, but the security model needs to be understood

**Auth friction**
- Good. Start with **anonymous auth** or a very light guest flow.
- Later add magic link, Google, or Apple without rebuilding the data model.

**Moderation implications**
- Good. Add `hidden`, `flagged`, `deleted_at`, `created_by`, `is_mod` fields and simple admin views.
- SQL makes it easy to find spam patterns and mass-hide junk.
- Better than Firebase if you expect to do manual moderation and analytics in the dashboard.

**How hard to wire in here**
- Low.
- Add Supabase client via CDN or a tiny imported JS file.
- Keep GitHub Pages for the app, use Supabase for data/auth/realtime.
- You do **not** need to break the single-file app on day one, although eventually splitting JS out of `index.html` would help.

---

### 2) Firebase, very fast for realtime, weaker fit once product gets messy
**Best for:** fastest path if you only care about live sync and easy anonymous auth.

**Why it fits**
- Excellent realtime UX for a feed of active reports.
- Anonymous auth is easy.
- Static-site friendly.

**Pros**
- Very easy realtime updates
- Anonymous auth is battle-tested
- Simple to drop into a static front end
- Good if the product is basically a live stream of nearby events

**Cons**
- Firestore data modeling gets awkward once you want relational stuff like comments, confirmations, reporter reputation, moderation actions, and expiry logic
- Security rules are powerful but easy to get wrong and harder to reason about than SQL + RLS
- Admin/debugging for product logic is worse than just writing SQL
- Geo querying is workable, but not especially pleasant

**Auth friction**
- Best of the bunch for soft login if you use anonymous auth.

**Moderation implications**
- Fine for MVP, worse than Supabase once you need dashboards, spam analysis, or moderator workflows.

**How hard to wire in here**
- Low.
- Similar integration effort to Supabase.
- If the only near-term feature was “map pins that appear instantly”, Firebase would be more competitive.

---

### 3) Tiny custom backend, not the fastest once you include auth + realtime + abuse handling
**Examples:** Cloudflare Workers + D1/Neon, Express on a VPS, FastAPI, etc.

**Best for:** when you already know exactly what product rules you need and want full control.

**Pros**
- Full flexibility
- Can design APIs around the app instead of around a platform
- Easy to optimize later

**Cons**
- You now own auth, rate limits, moderation tooling, and realtime delivery
- WebSockets/SSE plus comments plus guest identity is more work than it sounds
- Much higher chance of spending a week building plumbing instead of shipping the feature
- Bad choice for time-to-working-product in this repo

**Auth friction**
- Entirely on you.

**Moderation implications**
- Entirely on you.

**How hard to wire in here**
- Medium to high, not because fetch calls are hard, but because everything behind them is now your problem.

---

### 4) PocketBase, very tempting, but adds ops burden
**Best for:** if you want “Supabase-lite” on your own small server and are comfortable hosting a single binary.

**Pros**
- Fast MVP setup
- Built-in auth, realtime, admin UI
- Simple mental model

**Cons**
- You need to host and back it up
- Operationally more fragile than managed Supabase/Firebase
- Less standard if this grows or other devs touch it later

**Verdict**
- Viable, but only if you actively want to self-host. Otherwise it is an unnecessary extra dependency.

## What I would ship first

### Recommended MVP stack
- **Frontend:** keep GitHub Pages
- **Backend:** Supabase
- **Auth:** anonymous auth first, optional upgrade later to magic link or OAuth
- **Realtime:** subscribe to `reports` changes globally or by viewport
- **Comments:** lightweight table keyed by `report_id`
- **Moderation:** soft-delete + hidden flag + basic admin role

## Minimal schema

### `profiles`
- `id` UUID, auth user id
- `handle` text
- `karma` int default 0
- `is_mod` bool default false
- `created_at`

### `reports`
- `id` UUID
- `created_at`
- `expires_at`
- `user_id` UUID nullable but ideally auth-backed
- `type` text, example: `sweeper`, `ticket_agent`, `tow`, `open_spot`
- `lat`, `lng`
- `street_name` text nullable
- `direction` text nullable
- `note` text nullable
- `status` text, example: `active`, `hidden`, `expired`
- `confirm_count` int default 0
- `last_confirmed_at` timestamp nullable

### `comments`
- `id` UUID
- `report_id` UUID FK
- `user_id` UUID
- `body` text
- `created_at`
- `deleted_at` nullable

### `report_confirmations`
- `report_id`
- `user_id`
- `created_at`

This is enough for live reports, confirmations, and a tiny comment thread.

## Practical moderation plan

Do not launch this totally open with no friction. Parking apps will attract junk fast.

### MVP moderation baseline
- anonymous auth allowed, but every post tied to a stable user id
- one active report per user per type per small time window
- max comment length
- soft delete, never hard delete at first
- `flagged_count` or `hidden` fields
- admin SQL view or dashboard for recent abusive activity

### If abuse shows up fast
Add one of these before building a full backend rewrite:
- Cloudflare Turnstile on create-report and create-comment
- a Supabase Edge Function for writes, instead of direct table inserts
- temporary cooldowns based on user id and device fingerprint

## Why Supabase beats Firebase here

For WePark, the hard part is not just realtime. It is **realtime plus product rules**:

- reports expire after 15 minutes
- confirmations refresh trust
- comments are attached to reports
- some content gets hidden
- moderators need control
- eventually you may want hot blocks, reliable reporters, and neighborhood summaries

That all smells more like SQL than document trees.

Firebase is still good, but it is better for “live shared state” than “community product with evolving relational rules”.

## Migration path

### Phase 1, fastest possible real product
1. Create Supabase project
2. Add `reports`, `comments`, `profiles`, `report_confirmations`
3. Turn on anonymous auth
4. Add RLS:
   - anyone signed in can read active reports/comments
   - users can insert their own reports/comments
   - users can update only their own content
   - mods can hide content
5. Add client SDK to the app
6. Show live report pins on the map
7. Open a bottom sheet when a pin is tapped, show comments + confirm button

### Phase 2, basic safety and trust
1. Add rate limits and cooldowns
2. Add `hidden` and `flag_reason`
3. Add moderator dashboard in Supabase or a tiny separate admin page
4. Add karma or reliability score

### Phase 3, cleaner architecture
1. Split backend code out of `index.html` into `community.js` or similar
2. Move write paths to Edge Functions if spam/validation becomes annoying
3. Add photo uploads if needed
4. Add geographic subscriptions by viewport or neighborhood

## Wiring plan for this specific repo

Because `index.html` is already doing everything, I would not over-engineer the first pass.

### Smallest viable integration
- keep map rendering exactly as-is
- add a new `communityState` section in JS
- load active reports after map init
- subscribe to report inserts/updates/deletes
- render pins as another Leaflet layer group
- on pin click, fetch comments for that report and show them in the existing panel/modal style

### What not to do yet
- do not build a separate backend repo
- do not migrate off GitHub Pages
- do not build full chat rooms
- do not overthink geospatial indexing before actual usage exists

## Final recommendation

If the goal is **fastest time to a real working multi-user WePark MVP**, pick **Supabase**.

It is the best balance of:
- fast setup
- static-site compatibility
- realtime support
- soft login
- moderation sanity
- future flexibility

### One-line decision
**Ship Supabase now, anonymous auth first, SQL tables for reports/comments/confirmations, and keep the app on GitHub Pages.**
