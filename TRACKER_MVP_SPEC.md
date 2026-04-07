# WePark Tracker MVP Spec

## Goal
Build a real, usable parking-threat layer on top of the current WePark map so a user who is **already parked** can quickly answer:
- Is enforcement or the sweeper near my block right now?
- Which way is it moving?
- Has my ASP block already been cleaned?
- Can I move back yet, or do I still need to wait?

This MVP is **structured reporting first, chat-lite second**.

## Fit With Current App
The current web app already has the right base primitives:
- canonical block identity in the UI: `street + from + to + side`
- block-face selection and parking state via the existing `Park My Car` flow
- map-centered browsing with tile-based loading
- ASP schedule/rule parsing already attached to block segments

That means the tracker should **reuse the existing block-face model**, not invent a place-based freeform chat model first.

## Product Scope, Locked Decisions
- Real reporting backend first
- Anonymous read, lightweight login for write
- Primary use case: help currently parked users avoid tickets / ASP traps
- V1 report types only:
  - `sweeper`
  - `ticket_agent`
  - `block_cleaned`
- Tow truck excluded
- Reports attach to a specific block face and also appear in a wider micro-neighborhood feed
- Direction uses **cross-street-relative direction**
- `block_cleaned` persists for the rest of the active ASP window, with repeat pass count if reported again

## Recommended MVP Architecture
Use a small real-time backend, not ad hoc client state.

### Recommended stack
- **Supabase Postgres + PostGIS + Auth + Realtime**
- Current web app continues to serve statically from GitHub Pages
- Add a thin tracker data layer from the client to Supabase

Why this fits:
- fastest path to a real backend
- Postgres/PostGIS matches the long-term roadmap
- built-in auth handles "anonymous read, login for write"
- realtime subscriptions are enough for the MVP feed and active map overlay

If Kevin wants a custom API later, this schema still ports cleanly to Node/Python.

---

# 1. Recommended Data Model

## 1.1 Canonical `block_faces`
Derived from the existing segment dataset by grouping on:
- `street`
- `from_cross_street`
- `to_cross_street`
- `side`

Each tracker report should point to one canonical block face.

### `block_faces`
- `id` uuid / stable slug
- `street` text
- `from_street` text
- `to_street` text
- `side` enum: `N | S | E | W`
- `label` text, ex. `Mulberry St, Prince St to Spring St, west side`
- `center` geography(Point, 4326)
- `geom` geography(LineString, 4326) or jsonb polyline
- `bbox` optional geometry for quick viewport queries
- `asp_rules` jsonb
- `has_asp` boolean
- `h3_cell` or geohash, optional but recommended for nearby feed lookups
- `source_segment_ids` jsonb or text[]
- `updated_at`

### Why this matters
The tracker UI and parked-car logic should reference the **block face**, not individual tiny rendered segments. The current `segmentLayers` model can stay for drawing, but tracker state should resolve to a single higher-level block-face record.

## 1.2 Users
Keep this minimal.

### `users`
- `id` uuid
- `created_at`
- `auth_provider`
- `display_name` nullable
- `trust_score` numeric default low
- `is_limited` boolean default false

No social profile work in MVP.

## 1.3 Reports
A report is the current active tracker object.

### `reports`
- `id` uuid
- `type` enum: `sweeper | ticket_agent | block_cleaned`
- `block_face_id` fk
- `reporter_user_id` fk
- `status` enum: `active | expired | retracted`
- `created_at`
- `updated_at`
- `last_seen_at`
- `expires_at`
- `note` varchar(140) nullable
- `confirm_count` int default 0
- `distinct_reporter_count` int default 1
- `confidence` enum or smallint, derived not user-entered

### Direction fields
For `sweeper` and `ticket_agent`:
- `direction_mode` enum: `toward_from | toward_to | unknown`
- `direction_label_cache` text

Important: direction is stored relative to the block face's cross streets, not cardinal direction.
Example render:
- `Toward Spring St`
- `Toward Prince St`

## 1.4 ASP-window state for `block_cleaned`
`block_cleaned` is different from other report types. It is tied to a specific ASP window instance.

### Additional `reports` fields for `block_cleaned`
- `asp_window_start_at`
- `asp_window_end_at`
- `pass_count` int default 1
- `last_pass_at`

### Rule
Only one active `block_cleaned` report should exist per:
- `block_face_id`
- `asp_window_start_at`

If another user reports the same block cleaned during that same ASP window:
- do **not** create a fresh active row
- increment `pass_count`
- update `last_pass_at`
- optionally increment `distinct_reporter_count`

## 1.5 Report event log
Use a small event table instead of full chat.

### `report_events`
- `id` uuid
- `report_id` fk
- `user_id` fk
- `event_type` enum:
  - `created`
  - `confirmed`
  - `pass_incremented`
  - `retracted`
  - `expired`
- `created_at`
- `payload` jsonb nullable

This powers the lightweight feed without building chat rooms.

## 1.6 Optional abuse/rate-limit table
### `user_actions`
- `id`
- `user_id`
- `action_type`
- `created_at`
- `metadata`

Useful for write throttles and moderation later.

---

# 2. Core Backend Behavior

## 2.1 Active report query surfaces
Need two main read surfaces:

### A. Block-face detail
For a selected block face:
- active reports on that exact block face
- latest `block_cleaned` status for the current ASP window
- recent event history for that block face

### B. Micro-neighborhood feed
For a location, return active reports within roughly **400m**.

Recommended default:
- `radius_m = 400`
- center on parked car if set
- otherwise map center

This is close to the original "few blocks" intent and useful enough without feeling noisy.

## 2.2 Suggested API shape
Even if Supabase is accessed directly from the client, think in these product-level endpoints:

- `GET /tracker/reports/active?bbox=...`
- `GET /tracker/block-face/:id`
- `GET /tracker/feed?lat=...&lng=...&radius=400`
- `POST /tracker/reports`
- `POST /tracker/reports/:id/confirm`
- `POST /tracker/reports/:id/pass`
- `POST /tracker/reports/:id/retract`

## 2.3 Realtime behavior
Realtime should push:
- new report created
- report confirmed
- `block_cleaned.pass_count` incremented
- report expired/retracted

Enough for live map updates and the feed. No chat transport needed.

---

# 3. UI Flow

## 3.1 Read path, no login required
User opens app and can immediately:
- see active threat markers on the map
- tap a block face to see active reports
- read the nearby feed
- see whether their parked block is threatened or already cleaned

No auth wall on read.

## 3.2 Write path, login only when needed
When a user tries to:
- create a report
- confirm a report
- increment a cleaned pass
- retract their own report

Then show lightweight auth.

## 3.3 Recommended auth UX
Best MVP flow:
- browse anonymously by default
- on first write action, prompt:
  - Continue with Google
  - Continue with Apple
  - Email magic link
- keep session persistent

Do **not** require profile setup, username creation, or onboarding.

If only one write auth method is desired for MVP, choose **email magic link**. It is the lightest web-safe option.

## 3.4 Main tracker UI surfaces

### A. New top-level mode or overlay
Add a **Tracker** mode or toggle, not a separate app.

Recommended behavior:
- current parking/regulation map remains the base layer
- tracker overlay can be toggled on/off
- parked-car status remains visible and becomes more important when tracker is on

### B. Block-face sheet
When user taps a block face, show a bottom sheet / detail panel with:
- block name and side
- current ASP status for that block face
- active reports on that block face
- report actions:
  - `Report sweeper`
  - `Report ticket agent`
  - `Mark block cleaned`
- recent tracker events for that block

### C. Nearby feed drawer
Show a compact feed sorted by freshness, centered on parked car if available.

Each item should show:
- type icon
- block label
- time ago
- direction if applicable
- pass count if cleaned
- distance from car or map center

This is the "lighter chat" surface. It is an event feed, not a conversation room.

## 3.5 Report composer flow

### Sweeper / ticket agent
1. User taps block face
2. Taps `Report sweeper` or `Report ticket agent`
3. Composer asks:
   - direction: `Toward [from]` or `Toward [to]`
   - optional short note
4. Submit

### Block cleaned
1. User taps ASP block face
2. Taps `Mark block cleaned`
3. App confirms the active ASP window being marked
4. Submit
5. If already marked cleaned for this ASP window, button changes to:
   - `Seen another pass`

## 3.6 Use parked-car flow as a shortcut
The existing parked-car feature should be a first-class shortcut.

If user has a parked car set:
- show a prominent `Report near my car` action
- auto-open the current parked block face
- pin nearby feed to parked-car radius first

This keeps the product centered on "help me not get ticketed" instead of generic neighborhood chatter.

---

# 4. Map Behavior

## 4.1 Marker model
Render tracker state at the **block-face level**, not free-floating pins.

Recommended visuals:
- `sweeper`: broom icon + directional arrow
- `ticket_agent`: ticket icon + directional arrow
- `block_cleaned`: green/teal cleaned badge with pass count, ex. `Cleaned x2`

## 4.2 Placement
Place the marker at the block-face centroid or along the block polyline midpoint.

When a block face has multiple active states:
- stack in the block sheet
- on the map show the highest-priority badge or a small multi-state pill

Recommended display priority:
1. `ticket_agent`
2. `sweeper`
3. `block_cleaned`

Reason: immediate threat should visually beat informational state.

## 4.3 Zoom behavior
- At high zoom: show per-block-face tracker markers
- At lower zoom: collapse into count badges or simple heat dots
- Do not let the tracker layer clutter the base parking map

## 4.4 Direction display
Direction should always be rendered relative to the block's cross streets:
- `Toward Spring St`
- `Toward Houston St`

Avoid cardinal wording in the product copy. The user on the street cares about cross-street progression.

## 4.5 Parked-car prioritization
If a parked car exists, the map should visually emphasize:
- reports on the same block face
- reports on adjacent block faces in the same micro-neighborhood
- `block_cleaned` state on the parked user's own ASP block

Recommended simple rules:
- same block face: highest emphasis
- same street, adjacent block: medium emphasis
- rest of 400m feed: standard emphasis

## 4.6 Block cleaned semantics on map
`block_cleaned` should look different from moving threats.

It should communicate:
- this block was already passed/cleaned
- how many times it has been seen this ASP window
- it remains valid through the current ASP window end

Example label:
- `Cleaned, 10:42 AM`
- `Cleaned x2, last pass 10:51 AM`

---

# 5. TTL and State Rules

## 5.1 Sweeper TTL
- default TTL: **15 minutes**
- `expires_at = created_at + 15m`
- confirmation refresh sets `expires_at = now + 15m`
- if unconfirmed, it silently ages out

## 5.2 Ticket agent TTL
- default TTL: **15 minutes**
- same refresh behavior as sweeper

## 5.3 Block cleaned TTL
`block_cleaned` does **not** use a 15-minute TTL.

Rule:
- valid from creation time until the end of that block face's **current ASP window instance**
- `expires_at = asp_window_end_at`

If seen again during the same ASP window:
- increment `pass_count`
- update `last_pass_at`
- keep same `expires_at`

## 5.4 Preconditions for `block_cleaned`
Only allow `block_cleaned` when:
- the block face has an ASP rule
- the app can resolve the relevant ASP window instance for today
- current time is within the ASP window, or within a short grace after sweep start if desired

Recommended MVP simplification:
- allow only when current time falls inside the active ASP window for that block

That prevents confusing "cleaned" posts hours early.

## 5.5 Report merging rules
### Sweeper / ticket agent
If a same-type report already exists on the same block face and same direction within freshness window:
- treat new submissions as confirmations, not brand-new separate active reports

### Block cleaned
Merge by:
- `block_face_id`
- `asp_window_start_at`

Increment pass count instead of creating duplicates.

## 5.6 Confidence / verification
Keep it lightweight:
- `1 reporter`: unverified
- `2+ distinct reporters`: verified
- recent confirmation bumps it higher in the UI

No karma system needed yet.

---

# 6. Auth and Trust Behavior

## 6.1 Anonymous read
Anyone can:
- open the map
- read active reports
- read nearby feed
- inspect block detail

## 6.2 Login required for write
Authenticated users only can:
- report
- confirm
- increment pass count
- retract own report

## 6.3 Minimal trust protections for MVP
Implement immediately:
- per-user write rate limits
- one-click retract for own recent report
- server timestamp only, never trust client timestamp
- optional note length cap, max 140 chars
- soft flagging for users who post too many contradictory reports

## 6.4 What not to build yet
Do not build in MVP:
- public profiles
- follower graph
- open-ended neighborhood chat rooms
- reputation gamification
- notification system beyond live in-app state

---

# 7. Recommended Lighter-Chat Shape

Do not ship a freeform chat room in v1.

Instead, use:
- structured reports
- confirm actions
- optional one-line notes
- event feed entries from `report_events`

That gives the product enough social signal to feel alive, without diluting the core utility.

Good example feed items:
- `Sweeper reported on Mulberry, moving toward Spring, 2 min ago`
- `Ticket agent confirmed on Prince west side, 1 min ago`
- `Block cleaned on Elizabeth, pass x2, last seen 10:51 AM`

---

# 8. Phased Implementation Order

## Phase 0, normalize block faces from existing map data
Goal: create backend-ready canonical tracker geography.

Build:
- script to derive `block_faces` from current tile data
- stable block-face ids from `street + from + to + side`
- centroid/geometry export
- attach parsed ASP metadata from existing rules

Why first:
- everything else depends on a stable report target
- this lets tracker state line up with the current map immediately

## Phase 1, backend foundation
Goal: real reporting backend, public reads, auth-gated writes.

Build:
- Supabase project
- `block_faces`, `reports`, `report_events`, `users`
- public read policies
- auth for writes
- TTL expiration job or SQL-based active view
- active report queries by bbox and radius

Done when:
- data can be created, read, expired, and merged correctly
- `block_cleaned` window logic works

## Phase 2, read-only tracker overlay in the web app
Goal: make the map useful before users can post from it.

Build:
- fetch active tracker reports by visible area
- render block-face badges
- nearby feed drawer
- block-face detail panel with tracker state
- parked-car prioritization in tracker UI

Done when:
- a user can browse threats and cleaned blocks without logging in

## Phase 3, reporting UI + lightweight auth gate
Goal: enable real contribution.

Build:
- report composer from selected block face
- login prompt on first write action
- confirm action
- `Seen another pass` for `block_cleaned`
- own-report retract

Done when:
- a user can report sweeper, ticket agent, and cleaned block end-to-end

## Phase 4, trust and polish
Goal: reduce noise and make the signal feel reliable.

Build:
- duplicate merge logic in UI and backend
- verified badge / distinct-reporter counts
- abuse throttles
- optimistic realtime UI updates
- clearer same-block and near-my-car alerts

## Post-MVP, not now
- richer chat
- push notifications
- historical enforcement patterns
- predicted sweeper timing
- native app packaging

---

# 9. Recommended MVP Decisions To Lock

If Kevin wants crisp implementation choices, these are the right defaults:

- **Backend**: Supabase Postgres/PostGIS/Auth/Realtime
- **Canonical object**: `block_face`
- **Nearby feed radius**: **400m**
- **Direction encoding**: `toward_from | toward_to | unknown`
- **Sweeper TTL**: **15m**
- **Ticket agent TTL**: **15m**
- **Block cleaned TTL**: until **end of current ASP window**
- **Block cleaned duplicate handling**: merge into one active report per ASP window, increment `pass_count`
- **Auth**: anonymous browse, login on first write
- **Chat**: no room chat in MVP, event feed only

---

# 10. Best MVP Mental Model

This feature should feel like:
- **Waze for ASP enforcement**, not Discord for parking

The user should not need to wonder where to post, who is in the room, or what thread to read.
They should tap a block, see the current signal, add signal fast, and get back to not being ticketed.
