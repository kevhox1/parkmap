# WePark — Privacy Policy

**Last updated: 2026-06-11.**

WePark helps you find legal, free street parking in New York City. We care about your privacy and collect as little as possible. This policy explains what we collect, why, and who it's shared with.

## What we collect

**Location.** WePark uses your device location to center the map on your block, recommend nearby parking, and power Drive Mode and Find Parking. **Your continuous location stays on your device and is not sent to our servers** — with one exception: when you *choose* to submit a community report (e.g. "enforcement active" or "street sweeper") or save a parking pin, the location *of that report* is sent to our backend so other users can see it.

**Anonymous account.** On first launch we create an anonymous account (a random identifier) so the app works without you signing up. It contains **no name, email, or phone number.** It lets us attribute your community contributions, let you confirm/dispute reports, and prevent abuse.

**Community content you submit.** Reports and reactions you create (type, the location you attach, and a timestamp) are stored so the community can see them. Reports are ephemeral and expire automatically.

**Notifications.** If you enable reminders (e.g. before you need to move your car), we use Apple's notification system to deliver them.

## What we do NOT collect
- No name, email, phone, or contact list (unless you later opt in to "Sign in with Apple" to sync across devices — not in this version).
- No browsing history, no advertising identifiers, no health/financial data.
- We do **not** sell your data, and we do **not** use it for advertising or cross-app tracking.

## Third parties we use
- **Mapbox** — map display, search, and directions. Requests (including location for routing) are processed by Mapbox under its privacy policy.
- **Supabase** — secure hosting for community data and anonymous accounts.
- **NYC OpenData / NYC.gov** — we read public city data (film permits, alternate-side-parking calendar). We do not send your data to the city.
- **Apple** — standard iOS services and push notifications (APNs).

## Data retention
- Community reports are ephemeral and auto-expire (within ~5 minutes for moving reports like enforcement agents and street sweepers; up to ~30 minutes for stationary ones like broken meters).
- Your anonymous identifier persists on your device until you delete the app.

## Accuracy disclaimer
WePark provides parking information and community reports for convenience only and does not guarantee accuracy. Parking rules change and signs are updated without notice. **You are responsible for obeying all posted signs and NYC regulations — the sign on the street is always the final word.**

## Children
WePark is not directed to children under 13 and does not knowingly collect their data.

## Changes
We may update this policy; material changes will be reflected here with a new date.

## Contact
Questions about privacy? Contact **kevinhx2010@gmail.com**.

---

## Appendix — App Store Connect "App Privacy" label answers (for Kevin)
When filling out App Privacy in App Store Connect, the honest answers for this version:

| Data type | Collected? | Purpose | Linked to identity? | Tracking? |
|---|---|---|---|---|
| **Precise Location** | Yes | App Functionality (map, reports you submit) | Not linked to a real identity (anonymous only) | **No** |
| **User ID** (the anonymous UUID) | Yes | App Functionality (attribute reports, abuse prevention) | — (it *is* the anonymous id) | **No** |
| **User Content** (reports/reactions) | Yes | App Functionality | Not linked to a real identity | **No** |
| Contact info, Health, Financial, Browsing, Purchases, Contacts, Search history, Diagnostics-for-tracking | **No** | — | — | — |

- **"Used for tracking"? → No** for everything (no third-party ad/analytics SDKs).
- If you add analytics later (e.g. the deferred `drive_sessions` metric), update this label + the policy.
