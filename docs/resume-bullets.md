# WePark — Resume Source Material

Raw, verifiable bullet points about building WePark, written to be fed into a resume-writing
assistant. Every number below is grounded in the repo (git history, `docs/`, QA reports) as of
build 1.0 (14) / August 2026. Framing note for the assistant at the bottom.

## One-liner

**WePark** — a native iOS app (TestFlight, App Store Connect) that maps every legal free-parking
opportunity in Manhattan in real time, built solo end-to-end: product, data engineering, iOS
architecture, and an AI-agent engineering process, on top of NYC Open Data.

## Hard numbers (all verifiable in-repo)

| Metric | Value |
|---|---|
| NYC parking-sign records processed per build | 75,684 signs + 20,346 ASP records (Socrata) |
| Curb segments produced | ~39,000 block-face segments, ~77,000 rule instances |
| Map tile system | 1,032 pre-computed geographic tiles, bundled offline-first |
| Rendering scale | 40,000+ simultaneous MapKit polylines |
| Memory optimization | 19.92 GB → 137.5 MB (~145× reduction) via rendering-architecture pivot |
| Test suite | 585+ unit tests, 0 failing, gating every merge |
| Pull requests shipped | 68 PRs, every one through spec → build → independent QA → merge |
| TestFlight builds | 1.0 (1) through 1.0 (14) live on TestFlight |
| Data coverage instrumentation | 43% → 47% of Manhattan street-miles in one pipeline fix (Harlem 38% → 64%) |
| Data incident recovered | Silent loss of ~40–48% of all restriction data — detected, root-caused, permanently gated |

## Bullets by theme

### Product & shipping
- Conceived, designed, and shipped WePark, a native iOS app that turns NYC's open parking-sign
  data into a live map of free-parking opportunities; distributed via TestFlight with App Store
  Connect release management (14 builds), privacy policy, and export-compliance handling.
- Ran a tight field-test loop as the product's own power user: 20+ documented on-device driving
  sessions produced a numbered findings log (FT-1..14, TF2-1..20) where every issue was triaged,
  spec'd, fixed, QA'd, and re-verified on the street — the log is the project's source of truth.
- Shipped a "Parking 101" in-app education product: NYC sign-reading curriculum with
  vector-rendered replica signs, savings math, and a one-shot onboarding banner — caught and
  fixed a legal-accuracy error (No Parking vs No Standing loading rules) before release.
- Prioritized ruthlessly across a PWA precursor (live on GitHub Pages) and the native rewrite,
  keeping the PWA in maintenance mode while porting to Swift for a polished single launch.

### iOS engineering (Swift / SwiftUI / MapKit)
- Architected a MapKit rendering pipeline that displays 40,000+ colored curb polylines at 60fps:
  diagnosed a 19.92 GB memory blowup in the naive SwiftUI approach (each polyline ≈ 30 Metal GPU
  resources) and pivoted to batched `MKMultiPolyline` overlays grouped by parking state —
  137.5 MB final footprint, a ~145× reduction.
- Built a real-time parking-legality rules engine in Swift (ported from JS with parity tests):
  evaluates day-of-week/time-window/suspension logic for every block face live, entirely in
  Eastern Time regardless of device locale, with a 6-hour "restriction coming soon" look-ahead
  tier feeding map color, voice, and notifications.
- Built "Drive Mode": a Waze-style in-car experience for parking hunting — custom per-GPS-tick
  follow camera (replaced MapKit's `.follow` after it fought user zoom), course-based heading with
  exponential smoothing plus snap-to-street-bearing at low GPS confidence (hysteresis-gated),
  side-of-street voice guidance, parking-aware route scoring over Mapbox Directions, and an
  arrival flow that drops a parked-car pin with restriction reminders.
- Implemented DST-safe local notifications (`UNCalendarNotificationTrigger`) with customizable
  multi-stage reminders (15m/30m/1h/2h/night-before) and cold-launch-safe deep linking.
- Enforced accessibility and glanceability: WCAG-checked color contrast for in-car UI (fixed a
  light-mode failure computed at 1.4:1, shipped at 5.9–10.4:1), Dynamic Type, VoiceOver labels.

### Data engineering (NYC Open Data / Node.js ETL)
- Built an ETL pipeline that converts 75,684 NYC parking-sign records + street geometry (OSM +
  NYC CSCL centerlines) into 1,032 offline map tiles: sign→block-face joining, rule
  classification, curb-side zone construction, and per-street perpendicular curb-offset geometry
  using real CSCL street widths (divided-roadway handling for Houston/Bowery-class streets).
- Root-caused a silent data-loss incident where an unstable paginated API pull dropped ~40–48% of
  all parking restrictions citywide (the app showed restricted curbs as free): proved the failure
  byte-by-byte across dataset snapshots, then hardened the pipeline with stable `$order`
  pagination, retry-with-backoff, and a fail-closed row-count completeness gate that aborts any
  build shipping partial data.
- Discovered via my own field testing that 11% of sign records were silently dropped at the
  street-name join (NYC's dataset spells "LA GUARDIA PLACE" three ways); built the
  quantification, then a collision-checked name-normalization layer (alias dictionary, SAINT↔ST,
  compact-spacing matching) that recovered 4,200+ records — citywide coverage 43%→47%, Harlem
  38%→64%.
- Built per-neighborhood coverage instrumentation (tile data vs official CSCL street-miles) so
  every data regeneration prints a coverage delta by neighborhood — turning "some streets look
  empty" into a measurable, rankable metric.

### Backend & community (Supabase)
- Designed a community-reporting layer on Supabase/Postgres: anonymous auth, row-level security,
  crowd pins for enforcement agents/street sweepers with TTL decay, confirm/dispute voting with
  auto-resolution, and direction-of-travel capture derived from one-way street data.

### AI-agent engineering organization (novel process work)
- Designed and operated a multi-agent AI engineering organization (Claude-based) with defined
  roles — tech lead (specs), iOS engineer, data engineer, designer, and an independent QA
  verifier — governed by a written operating manual: spec-first development, the builder never
  self-certifies, and every merge requires an adversarial QA pass by a fresh agent.
- Enforced real independence mechanics: isolated git worktrees per agent, per-agent iOS
  simulators, live-UI smoke gates before merge (after a passing-tests-but-broken-UI regression
  proved unit tests insufficient), and QA passes that re-derive every claimed number from raw
  data rather than trusting the builder's report.
- The process caught real defects pre-ship repeatedly: a fail-open validation gate in my own data
  pipeline fix, a spec-inherited legal-accuracy error in user-facing content, and a
  wrong-day-of-week diagnosis (the "bug" was correct Sunday behavior) — each documented in
  QA reports in-repo.
- Personally owned the irreducible human layer: product decisions, on-device drive-test
  verification of all camera/GPS behavior (untestable in simulator), Apple release ceremony, and
  final merge authority on all 68 PRs.

## Notes for the resume assistant

- **Honest framing:** solo personal project; Kevin is founder/product owner/architect and
  directed AI coding agents through a documented engineering process — he did not hand-write
  every line of Swift. Bullets above use "built/architected/shipped," which is standard founder
  framing; keep claims tied to the verifiable numbers.
- **Strongest differentiators:** (1) the AI-agent org with genuine independent-QA mechanics —
  timely and rare; (2) the two data-integrity incidents root-caused with evidence; (3) the 145×
  memory optimization story; (4) shipping discipline (68 PRs, 585 tests, 14 TestFlight builds)
  on a solo project.
- **Keyword bank:** Swift, SwiftUI, MapKit, MKMultiPolyline, Core Location, AVSpeechSynthesizer,
  UserNotifications, StoreKit-adjacent TestFlight/App Store Connect, Node.js, ETL, NYC Open Data
  (Socrata/SoQL), OpenStreetMap, PostGIS-style geospatial joins (haversine, polyline offsetting),
  Supabase, PostgreSQL, RLS, service workers/PWA, Mapbox Directions API, CI-style test gating,
  multi-agent LLM orchestration, prompt-driven spec/QA workflows.
- Tailor length to the target: the whole project compresses honestly to 3–4 resume lines for a
  standard resume, or expands to a project page/portfolio case study using the incident stories.
