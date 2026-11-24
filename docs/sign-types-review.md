# NYC curb sign types: review sheet for Kevin

**Source:** NYC DOT parking-regulation signs for Manhattan (Socrata `nfid-uabd`), pulled 2026-11-24. That's 96,268 sign records using 1,909 distinct DOT sign codes. Nearly all of them fall into the ~35 families below.

**"Today in the app"** is how `build/preprocess.js` `classifySign()` and the iOS rules engine treat each family right now:
- 🔴 = shown as a restriction (red / not free in that window).
- 🟡 = metered.
- 🟢 = **treated as free (green)**.
- ⚪ = ignored entirely.

**Fill in:** "What it really means" (correct me) and "How the app should show it". Anything marked ⚠️ is a place where I think the app is wrong today.

## Street cleaning (ASP)

| # | Sign type | Example sign text | Signs | Today in the app | My read | Your call |
|---|---|---|---|---|---|---|
| 1 | ASP street cleaning, daytime (broom) | `NO PARKING (BROOM) TUESDAY FRIDAY 11AM-12:30PM` | 40,078 | 🔴 during the window on those days. 🟢 when ASP is suspended (holidays/snow) | Correct. Biggest category by far. | |
| 2 | ASP overnight (broom + moon) | `NO PARKING (BROOM) MOON & STARS TUE THU SAT MIDNIGHT-3AM` | 530 | 🔴 at night on those days | Correct. Matters most for the Overnight goal. | |

## No Standing / No Stopping / No Parking (never OK for a parked car)

| # | Sign type | Example | Signs | Today | My read | Your call |
|---|---|---|---|---|---|---|
| 3 | No Standing Anytime | `NO STANDING ANYTIME` | 7,904 | 🔴 always | Correct. You can't even wait with the driver in the car. | |
| 4 | No Stopping Anytime | `NO STOPPING ANYTIME` | 1,653 | 🔴 always (lumped with No Standing) | Correct. Strictest: you can't even stop to drop someone off. | |
| 5 | Bus stop | `BUS STOP (BUS & HANDICAP) NO STANDING` | 2,334 | 🔴 always | Correct. | |
| 6 | No Standing, timed (rush hours etc.) | `NO STANDING MON-FRI 7AM-10AM 4PM-7PM` | 2,841 | 🔴 in the window only | Correct. Classic "rush hour" curbs, free outside the window. | |
| 7 | No Standing, school days | `NO STANDING SCHOOL DAYS 7AM-4PM` | 733 | 🔴 7–4 **every weekday** (we don't know the school calendar) | Conservative: it also shows red on school holidays and in summer. OK? | |
| 8 | Hotel loading zone | `NO STANDING HOTEL LOADING ZONE` | 508 | 🔴 always | Correct. | |
| 9 | Fire zone | `NO STANDING FIRE ZONE` | 118 | 🔴 always | Correct. | |
| 10 | Carshare parking only | `CARSHARE PARKING ONLY, OTHERS NO STANDING ANYTIME` | 74 | 🔴 always | Correct for a private car. | |
| 11 | No Parking Anytime | `NO PARKING ANYTIME` | 2,350 | 🔴 always | Correct. You may stop briefly to load/unload passengers or goods. | |
| 12 | No Parking, timed | `NO PARKING MON-FRI 8AM-6PM` | 2,293 | 🔴 in the window | Correct. | |

## Meters

| # | Sign type | Example | Signs | Today | My read | Your call |
|---|---|---|---|---|---|---|
| 13 | Metered, any vehicle ("HMP" = hour Muni-Meter parking) | `2 HMP 9AM-7PM EXCEPT SUNDAY` | 6,523 | 🟡 metered during hours. **A Few Hours** = red (Oct 20: "it's a meter so that's not free"). **Overnight / Park & Forget** = ignore the meter (paying doesn't force a move) | ⚠️ This is why A Few Hours shows MORE red than Overnight at 1 pm, and why metered Bowery blocks show green under Overnight. Also note a 2-hour meter DOES force you to move after 2 h. Decide per goal: does a meter count as free? | |
| 14 | ⚠️ Metered, **COMMERCIAL VEHICLES ONLY** | `3 HMP COMMERCIAL VEHICLES ONLY MON-FRI 7AM-6PM` | 4,205 | 🟡 treated like a normal meter (so 🟢 under Overnight / Park & Forget) | **Wrong for a private car.** During those hours a regular car can't park there at all, so it should be 🔴 like No Parking. This caused the Bowery green. | |
| 15 | "Meters not in effect above times" rider | `METERS ARE NOT IN EFFECT ABOVE TIMES` | 627 | ⚪ ignored | A modifier: the meter is off during the street-cleaning window. Fine to ignore. | |
| 16 | Pay-by-cell locator number | `PAY-BY-CELL LOCATOR NUMBER` | 6,066 | ⚪ ignored | Not a rule. Correct to ignore (could show the zone number later). | |

## Loading

| # | Sign type | Example | Signs | Today | My read | Your call |
|---|---|---|---|---|---|---|
| 17 | Truck loading only | `TRUCK LOADING ONLY MON-FRI 7AM-7PM` | 1,919 | 🔴 in the window | Correct for a private car. | |
| 18 | ⚠️ Neighborhood Loading Zone (NLZ) | `NLZ LOADING ONLY MON-FRI 8AM-6PM` | 175 | 🟢 **treated as free** (unrecognized) | Wrong: any vehicle may load/unload, but you can't park. Should be 🔴 in the window. | |

## Permit / plate-only curbs (private car can't park)

| # | Sign type | Example | Signs | Today | My read | Your call |
|---|---|---|---|---|---|---|
| 19 | Authorized vehicles only: police/fire/sanitation/agencies (AVO) | `AVO POLICE DEPARTMENT` | 762 | 🔴 (Special) | Correct. | |
| 20 | Authorized vehicles only: school faculty | `AVO DEPT OF EDUCATION SCHOOL DAYS 7AM-4PM` | 593 | 🔴 (Special) in the window | Correct (same school-calendar caveat as #7). | |
| 21 | ⚠️ Diplomat / consul plates only | `AUTHORIZED VEHICLES ONLY CONSUL-C DIPLOMAT-A & D PLATES` | 408 | 🟢 **treated as free** | Wrong: should be 🔴 always (usually anytime). | |
| 22 | Doctor plates / ambulance only | `DOCTOR LICENSE PLATES ONLY` | 155 | 🔴 (Special) | Correct. | |
| 23 | ⚠️ Press (NYP) plates only | `PRESS NYP LICENSE PLATES ONLY` | 118 | 🟢 **treated as free** | Wrong: should be 🔴. | |
| 24 | ⚠️ US Postal Service only | `AUTHORIZED VEHICLES ONLY US POSTAL SERVICE` | ~40 | 🟢 **treated as free** | Wrong: should be 🔴. | |
| 25 | ⚠️ Ambulette only | `AMBULETTE ONLY` | ~36 | 🟢 **treated as free** | Wrong: should be 🔴. | |
| 26 | ⚠️ For-hire vehicles only | `FOR-HIRE VEHICLES ONLY MON-FRI 4PM-MIDNIGHT` | ~8 | 🟢 **treated as free** | Wrong: should be 🔴 in the window. | |
| 27 | ⚠️ Taxi stand | `TAXI STAND` | 312 | 🟢 **treated as free** | Wrong: should be 🔴 always for a private car. | |
| 28 | ⚠️ EV charging only | `ELECTRIC VEHICLE CHARGING ONLY` | ~21 | 🟢 **treated as free** | Wrong for most cars: 🔴 (or "EV only" if we ever know the car). | |
| 29 | ⚠️ Horse-drawn cabs only / farmers market | `HORSE DRAWN CABS ONLY`, `FARMERS MARKET ONLY SUNDAY 6AM-6PM` | ~25 | 🟢 **treated as free** | Wrong: should be 🔴 (in the window). | |

## Buses and construction

| # | Sign type | Example | Signs | Today | My read | Your call |
|---|---|---|---|---|---|---|
| 30 | ⚠️ Bus layover only (MTA / non-MTA) | `MTA BUS LAYOVER ONLY, NO ENGINE IDLING` | 177 | ⚪ **ignored** (our filter for bus route panels also drops these) | Wrong: should be 🔴 always for a car. | |
| 31 | Temporary construction regulation | `NO STANDING … HARD HAT TEMPORARY CONSTRUCTION REGULATION` | 369 | ⚪ ignored | Temporary, and often stale in the data. Ignore, or show a "may have construction" warning? | |

## Parking-style signs (parking IS allowed)

| # | Sign type | Example | Signs | Today | My read | Your call |
|---|---|---|---|---|---|---|
| 32 | Back-in / angle / 90° / parallel parking only | `BACK IN ANGLE PARKING ONLY` | ~515 | ⚪ unrecognized (no effect) | Parking IS allowed, it's just how you park. Fine as-is; could show "Back-in only" as a tip. | |
| 33 | Time-limited free parking (no meter) | `2 HOUR PARKING SATURDAY 9AM-7PM` | ~10 | 🟢 unrecognized | Free, but you must move after 2 h. Matters for Overnight / Park & Forget. | |

## Not rules (correctly ignored)

| # | Sign type | Signs | Today |
|---|---|---|---|
| 34 | Bus route/destination panels, street-name panels, info signs (Open Streets, carshare info, idling fines, delineators, weight limits, No Trucks) | ~10,500 | ⚪ ignored. Correct |
| 35 | "Description Not Available" (DOT placeholder) | 537 | ⚪ ignored. Unknowable |

## Questions only you can answer
1. **Meters per goal (#13):** should "A Few Hours" treat a meter as OK (you pay), or not free? Should "Overnight" care about a meter that starts again at 7–9 AM, before you'd move the car? What about time limits (2 HMP = must move after 2 h)?
2. **School days (#7, #20):** keep showing red on every weekday (safe), or add the DOE school calendar?
3. **Construction (#31):** ignore, or warn?
4. **Colors:** today there's red / yellow (metered) / green. Do you want more kinds (e.g. "loading only", "permit only") shown differently, or keep it simple: can I leave my car here, yes or no?
