# Cruise Mode entry button + mute toggle — design note (2026-06-04)

**Decision (Kevin, 2026-06-04): Option B — one combined Drive/Cruise entry button with an expand-on-tap menu.** NOT two separate toolbar buttons. Rationale: the two are co-equal entries to the *same* in-car experience, two icon buttons don't communicate that relationship, and **patrol mode adds a third drive-entry soon** — a combined menu scales (add a 3rd item) where 3+ toolbar buttons would not.

## Entry button — the combined menu

Replace the two-button approach (Drive + Find Parking) with a **single entry button** in the `recenterButtonStack` toolbar cluster:

- **Resting state:** keep `arrow.triangle.turn.up.right.diamond.fill` (the existing Drive icon — recognizable to anyone who's used destination mode).
- **On tap:** expand *in place* (no full-screen cover) into a compact picker of labeled capsule options:
  - **"Drive to…"** — icon `arrow.triangle.turn.up.right.diamond` — opens `DriveModeDestinationView` (today's destination flow).
  - **"Find Parking"** — icon `car.front.waves.right.fill` — enters Cruise Mode directly via `enterCruiseMode()`.
- **On second tap** of an option: collapse + activate that mode. Tapping elsewhere collapses with no action.
- This keeps the toolbar at **four permanent buttons**; the picker is ephemeral (appears only on deliberate tap). Solves both the density problem and the semantic-clarity problem.
- This is distinct from the long-press the spec §5.1 rejected: it's a single normal tap surfacing *labeled* options, not a hidden gesture.

**Accessibility:**
- Resting button: `.accessibilityLabel("Start Drive Mode")`, `.accessibilityHint("Double-tap to choose destination navigation or find parking nearby.")`
- Expanded options: "Drive to a destination" / "Find Parking nearby".

**Forward note:** when patrol mode lands, it becomes a third option in this same menu — no toolbar change needed.

## Mute toggle (in the active Cruise/Drive overlay)

The mute button already exists in `DriveModeBottomCard.swift` (inline, trailing edge of the street-name row) — **keep it there** (the driver's eye is already on the bottom card; that's the right surface). State already persists (`DrivingVoice.isMuted` → UserDefaults `wepark_dm_voice_muted`), default ON. Two fixes:

| Priority | Fix | Location |
|---|---|---|
| **Must-fix** | Touch target is 36×36pt — below the 44pt HIG minimum. Make the interactive area ≥44pt (44×44 frame or `.contentShape` with larger frame). | `DriveModeBottomCard.swift` (~line 233) |
| Nice-to-have | Mode-neutral accessibility phrasing: "Mute/Unmute parking callouts" (works for both Cruise and Destination). | `DriveModeBottomCard.swift` (~237–238) |

**Corrected from the original review:** the note initially flagged mute persistence as missing — that was wrong. `DrivingVoice.isMuted` is already UserDefaults-backed (`wepark_dm_voice_muted`), read on init, written on toggle. No persistence fix needed. (Spec §5.4 named the key `driveVoiceMuted`; the existing `wepark_dm_voice_muted` achieves the same shared-across-modes behavior — keep the existing key, no rename needed.)
