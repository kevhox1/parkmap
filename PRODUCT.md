# ParkMap — Product Vision & Roadmap

## Mission
Free parking app for NYC street parkers. Regulation data + community-driven real-time intelligence.

## Target User
Anyone who street parks in NYC. ~2M registered vehicles in NYC, majority street park.

## Tier 1: Regulation Map (MVP — DONE)
- [x] NYC parking sign data (76K signs, all Manhattan)
- [x] OSM street geometry (2,813 streets)
- [x] 12 sign categories with distinct colors
- [x] "Signs" mode (static regulation view)
- [x] "Free Today" mode with ASP suspension
- [x] "Free Between" mode (time window filter)
- [ ] PWA setup (installable, offline capable)
- [ ] Deploy to GitHub Pages with real domain
- [ ] Mobile UI polish

## Tier 2: Smart Parking Tools
- [ ] "Park Until" filter — show blocks safe for a specific time window
- [ ] Block scoring engine — score every block by: time until next restriction, proximity, block length
- [ ] Route optimizer — generate driving loop through best streets
- [ ] Apple Maps / Google Maps handoff with waypoints
- [ ] "My car" pin — remember where you parked

## Tier 3: Alerts
- [ ] "Move your car" — ASP reminder based on car pin location
- [ ] "ASP suspended" — don't-move notification
- [ ] "Meter expiring" — timer-based alert
- Requires: native app + push notifications

## Tier 4: Community Layer
- [ ] Spot sharing — "leaving in X min" pins with auto-expiry
- [ ] Photo/note spot reports
- [ ] Spot confirmation ("still open" votes)

### Live Threat Tracking
- [ ] Sweeper truck reports 🧹 — location + direction, 15 min TTL
- [ ] Ticket agent reports 🎫 — location + direction, 15 min TTL  
- [ ] Tow truck reports 🚛 — location, 15 min TTL
- [ ] Confirmation system — "still here" refreshes TTL, 3+ = verified badge
- [ ] Direction of travel arrows on icons
- [ ] Pattern learning over time (sweeper always comes at 9:35 AM)

### Neighborhood Chat
- [ ] Geo-fenced chat zones (~4 block radius)
- [ ] Tied to car pin location
- [ ] Real-time utility messages (not social)
- [ ] Scrolling feed + post ability

## Technical Architecture

### Current (Web MVP)
- Single HTML file + JSON data
- Client-side processing
- Leaflet + Canvas renderer
- NYC Socrata API for sign data
- OSM Overpass for street geometry
- Cloudflare tunnel (temp) → GitHub Pages (next)

### Production (Native App)
- React Native (iOS + Android from one codebase)
- Backend: Node.js or Python API
- Database: PostgreSQL + PostGIS
- Real-time: WebSockets or Firebase
- Auth: Firebase Auth (free tier)
- Maps: react-native-maps (Apple Maps / Google Maps native)
- Push notifications: APNs (iOS) + FCM (Android)

### Data Pipeline
- Daily cron: fetch all sign data, pre-process, cache
- Pre-computed block scores served via API
- Tile-based loading (only send data for visible area)

## Key Feature: "Smart Move" Recommendations
- Core value prop: never sit in your car during ASP again
- Given car location + block rules, compute optimal time and destination to move
- "Move tonight to Elizabeth St, skip tomorrow's ASP, good until Thursday"
- Push notification the evening before ASP: "Move now in 5 min or sit for 90 min tomorrow"
- Scoring: nearby blocks where ASP already passed > blocks with ASP far in the future > metered (free hours)

## Additional Features
- Parking Karma system (gamification for community contributions)
- Watch This Block alerts (notify when someone leaves a spot in your zone)
- Garage price fallback (SpotHero/ParkWhiz integration when no street spots available)
- Historical ticket data overlay (NYC open data, which blocks are heavily enforced)
- Snow emergency mode (auto-detect, show snow emergency routes)
- Time-lapse visualization (24hr parking availability animation)
- One-sided spot claiming ("leaving in 5 min" → "be there in 5" response)

## Revenue Model (Keep App Free)
- Anonymized aggregate data licensing (city planners, real estate, delivery cos)
- Sponsored parking garage pins
- Premium fleet features (commercial delivery companies)
- All user features remain FREE

## Timeline
1. Manhattan web MVP — DONE
2. PWA + real hosting — 1-2 days
3. Native app v1 (map + regulations) — 3-4 weeks
4. Backend API — 1-2 weeks  
5. Scoring engine + route optimizer — 1-2 weeks
6. User accounts — 1 week
7. Community features — 2-3 weeks
8. Threat tracking — 1-2 weeks
9. App Store submission — 1 week

## Cost
- Apple Developer: $99/year
- Google Play: $25 one-time
- Hosting: $5-10/mo (or free tier)
- Domain: $10-15/year
- Total year 1: ~$150-250
