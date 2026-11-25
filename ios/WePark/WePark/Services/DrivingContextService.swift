//
//  DrivingContextService.swift
//  WePark
//
//  W8.5c: Swift port of `getCurrentDrivingContext` (index.html:5557–5587) +
//         `speakDrivingContext` (index.html:5957–5979) merged into one service.
//  CM-2: Cruise Mode extension — `setCruiseMode(_:)` switches voice cadence to
//         `CruiseVoicePolicy` (gate on at least one free/metered side) + Cruise Mode
//         phrasing via `CruiseVoicePolicy.utteranceText(for:)`.
//  TF2-7: Side-level aggregation — `SideOpportunity` + `aggregateSide(segments:side:engine:date:minimumFreeLength:)`
//         replaces single-segment `safetyLabel` calls in `update(...)`.
//         Voice copy updated to use catch-all templates (§4.1) — "Free parking sections on
//         the [side] — check signs." / "Metered on the [side]." / "No parking on either side."
//  TF2-17: `SideAggregation` + `aggregateSideDetail(...)` — same traversal as `aggregateSide`,
//         plus `earliestFreeUntilText`: the exact "Free until X" text from the qualifying free
//         segment with the soonest upcoming restriction (conservative min). `aggregateSide` is
//         now a thin wrapper over `aggregateSideDetail(...).opportunity` — unchanged public
//         contract. `update(...)` now builds `leftLabel`/`rightLabel` via
//         `SafetyLabel(for: SideAggregation)` instead of `SafetyLabel(for: SideOpportunity)`.
//  TF2-18 (P1-2, bundled): `SideOpportunity` gained a `.comingSoon` case — a side aggregates to
//         `.comingSoon` instead of `.free` when the winning (displayed) restriction starts within
//         `ParkingRulesEngine.nearFutureWindow` (6h), restoring the map's orange "restriction
//         coming soon" tier to Drive Mode chips (previously collapsed into `.free`). `.comingSoon`
//         is treated as free-equivalent for voice purposes via `isFreeForVoice(_:)` — voice copy
//         is unaffected (OQ-4 still holds, extended to cover the new case).
//
//  Responsibilities:
//    - Find the closest block to the driver's GPS position.
//    - Classify N/S/E/W sides as "left" or "right" relative to the driver's heading.
//    - Aggregate ALL segments on each cardinal side via aggregateSideDetail → SideAggregation.
//    - Compute safety label for each side (wrapped from SideAggregation for downstream use).
//    - Detect block changes and trigger voice cues via DrivingVoice.
//    - In Cruise Mode: gate announcements via CruiseVoicePolicy.shouldAnnounce, and
//      use CruiseVoicePolicy.utteranceText for Cruise-specific phrasing.
//
//  OQ-4: Voice always speaks real-time status, ignoring W7.5 Park Until filter.
//  Voice minimum gap (DRIVING_VOICE_MIN_GAP_S): 12 seconds default.
//  Calibration of all timing constants deferred to W8.5c-follow after drive-test.
//
//  No import SwiftUI (QA invariant — pure service).
//  No Calendar.current.
//

import Foundation
import CoreLocation
import Observation

// MARK: - DrivingContext

/// Value type describing the current parking context while driving.
/// Left/Right relative to the driver's heading.
struct DrivingContext: Equatable {
    let street: String
    let from: String
    let to: String
    let leftLabel: SafetyLabel
    let rightLabel: SafetyLabel

    /// fix/goal-aware-drive-card (Kevin smoke, 2026-10-26): goal-aware (or clock-set Park
    /// Until) chip-COLOR override for the corresponding side. `nil` means "no Park Until
    /// filter active — use `leftLabel.severity`/`rightLabel.severity` unchanged," the exact
    /// pre-fix behavior. Non-nil (`.free` or `.restricted` only) when `parkUntilMode` was
    /// active at the time this context was built — see
    /// `DrivingContextService.goalAwareChipSeverity(...)`, which mirrors
    /// `ContentView.rebuildOverlays()`'s own `parkUntilMode` branch exactly so the chip
    /// agrees with the map's binary green/red bucket for this side.
    ///
    /// Deliberately a SEPARATE field from `leftLabel`/`rightLabel.severity`, not a mutation
    /// of it — `CruiseVoicePolicy`/`DrivingContextService.buildUtteranceText` read
    /// `leftLabel.severity`/`rightLabel.severity` directly and are UNCHANGED by this fix
    /// (OQ-4 predates this fix: voice always speaks real-time status, ignoring any Park
    /// Until filter). See this fix's PR description for the resulting voice/card mismatch,
    /// flagged as a named follow-up rather than refactored here.
    let leftChipColorOverride: SafetyLabel.Severity?
    let rightChipColorOverride: SafetyLabel.Severity?

    init(
        street: String,
        from: String,
        to: String,
        leftLabel: SafetyLabel,
        rightLabel: SafetyLabel,
        leftChipColorOverride: SafetyLabel.Severity? = nil,
        rightChipColorOverride: SafetyLabel.Severity? = nil
    ) {
        self.street = street
        self.from = from
        self.to = to
        self.leftLabel = leftLabel
        self.rightLabel = rightLabel
        self.leftChipColorOverride = leftChipColorOverride
        self.rightChipColorOverride = rightChipColorOverride
    }

    /// Block identity key for change detection. Mirrors PWA: `${ctx.street}|${ctx.from}|${ctx.to}`.
    var blockKey: String { "\(street)|\(from)|\(to)" }
}

// MARK: - TF2-7: SideOpportunity

/// Aggregated parking opportunity for one side of the current block.
///
/// Returned by `DrivingContextService.aggregateSide(segments:side:engine:date:minimumFreeLength:)`.
/// Reduces all segments on one cardinal side to a single actionable classification.
///
/// Mapping to voice + card (spec §3.2):
///   `.free`       → "Free parking sections on the [left/right] — check signs."
///   `.comingSoon` → same voice copy as `.free` (TF2-18 P1-2 — voice-equivalent, see
///                   `isFreeForVoice(_:)`); card chip renders orange instead of green.
///   `.metered`    → "Metered on the [left/right]."
///   `.restricted` → (silent in Cruise Mode; "No parking on either side." in destination mode when both restricted)
///   `.unknown`    → (silent)
enum SideOpportunity: Equatable {
    /// At least one qualifying free-now stretch ≥ minimumFreeLength exists on this side,
    /// and no restriction on the winning (displayed) segment starts within 6h.
    case free
    /// TF2-18 P1-2: Same as `.free`, but the winning qualifying free segment's next
    /// restriction starts within `ParkingRulesEngine.nearFutureWindow` (6h) — mirrors
    /// `CurrentState.freeButRestrictionSoon` at the side-aggregation level. Restores the
    /// map's orange warning tier to Drive Mode, which previously collapsed this case into
    /// `.free` with no visual distinction.
    case comingSoon
    /// No qualifying free stretch; at least one metered segment exists.
    case metered
    /// No free or metered segments — entire side is restricted or no-standing.
    case restricted
    /// No segments found for this side (data gap).
    case unknown
}

// MARK: - TF2-17: SideAggregation

/// Detail-preserving aggregation result for one side of the current block.
///
/// `aggregateSideDetail(segments:side:engine:date:minimumFreeLength:)` returns this;
/// `aggregateSide(...)` is a thin wrapper returning just `.opportunity` (unchanged public
/// contract, spec §3 "New flow").
struct SideAggregation: Equatable {
    /// Same classification `aggregateSide` has always returned — precedence
    /// (free/comingSoon > metered > restricted > unknown) is unchanged from TF2-7.
    let opportunity: SideOpportunity

    /// The exact `SafetyLabel.text` (e.g. "Free until Wednesday 9:30 AM") from whichever
    /// qualifying free segment has the SOONEST upcoming restriction (conservative min —
    /// spec §5.1). `nil` when `opportunity` is `.free` and no qualifying segment has any
    /// restriction within the 14-day window (falls back to "Free — check signs" at the
    /// `SafetyLabel(for: SideAggregation)` bridge), or when `opportunity` is not
    /// `.free`/`.comingSoon`.
    let earliestFreeUntilText: String?

    /// True when `opportunity` is `.restricted` only because every segment on the side has
    /// no usable sign data. The label bridge then says "No sign data", not "No parking".
    /// `var` with a default so existing memberwise call sites are unchanged.
    var noSignData: Bool = false

    /// True when `opportunity` is `.restricted` and every restricted curb on the side is so only
    /// because of an UNKNOWN sign (or has no sign data). The label bridge then says "Unclear
    /// sign: check the posted sign", never a specific restriction. `var` with a default so
    /// existing memberwise call sites are unchanged.
    var unclearSign: Bool = false
}

// MARK: - DrivingContextService

/// Parking commentary engine for Drive Mode.
/// Port of `getCurrentDrivingContext` (index.html:5557–5587) +
/// block-change-detection + `speakDrivingContext` (index.html:5957–5979).
@Observable
final class DrivingContextService {

    // MARK: - Published state

    /// Current driving context. Nil when no segment is within range.
    private(set) var currentContext: DrivingContext?

    /// TF2-16: The segment closest to the driver's GPS position, as found by `update()`'s
    /// existing closest-segment lookup (`findClosestSegment`). Nil when `update()` finds no
    /// segment (mirrors `currentContext == nil`). Purely additive — exposes the same result
    /// `update()` already computes internally; no second matcher/distance-search is introduced.
    /// Consumed by `ContentView.handleLocationUpdate()` as the `hasBlockMatch` / snap-target
    /// input to `DriveHeadingSnap`.
    private(set) var matchedSegment: Segment?

    /// All curbs of the matched block (direction-agnostic grouping), for the heading snap.
    private(set) var matchedSiblings: [Segment] = []

    // MARK: - Block change detection (index.html:5905–5908)

    /// Block key from the most recent call. Nil on first call.
    private var lastBlockKey: String?

    /// Finding 8: remembers the last heading / street direction so left/right survive a
    /// stationary or unreliable-heading period.
    private var sideTravel = DriveSideTravel()

    /// Clears per-session travel/match state. ContentView builds a fresh service per drive, but
    /// this makes the guarantee explicit (and survives any future service reuse).
    func resetSession() {
        sideTravel.reset()
        matchedSegment = nil
        matchedSiblings = []
        lastBlockKey = nil
    }

    /// Timestamp of the last voice cue. Used for minimum-gap enforcement.
    private var lastSpokenAt: Date = .distantPast

    // MARK: - CM-2: Cruise Mode state

    /// True when the service is operating in Cruise Mode ("Find Parking").
    ///
    /// When true:
    ///   - `CruiseVoicePolicy.shouldAnnounce(context:)` gates each block-change announcement.
    ///     Blocks where both sides are restricted or unknown are silent.
    ///   - `CruiseVoicePolicy.utteranceText(for:)` supplies the announcement text,
    ///     which leads with the parking opportunity ("Free parking on left") rather than
    ///     the neutral destination-mode format ("Left side, free until...").
    ///   - The mute gate (`driveVoiceMuted`) is checked by the caller in `speakContext`
    ///     via `DrivingVoice.speak` — NOT inside `CruiseVoicePolicy.shouldAnnounce`
    ///     (which must remain a pure function of parking context for testability).
    ///
    /// When false (destination mode), the pre-CM-2 unconditional behavior is preserved —
    /// every block change triggers a voice cue (no regression).
    ///
    /// Set via `setCruiseMode(_:)`. Reset to `false` on Drive Mode exit.
    private var isCruiseMode: Bool = false

    // MARK: - Constants

    /// Minimum gap between voice cues (seconds).
    ///
    /// W8.5d: Changed from `private let` (immutable) to `private var` (settable) so
    /// `ContentView`'s `.onChange(of: driveModeDistanceMeters)` can update the gap when
    /// `FinalApproachState` changes:
    ///   - `.outside`    → 12s (baseline, port of DRIVING_VOICE_MIN_GAP_MS = 12000)
    ///   - `.approaching` → 4s  (elevated cadence during final approach, OQ-2)
    ///   - `.arrived`    → .infinity (suppresses voice; arrival prompt is the cue)
    ///
    /// Updated via `setVoiceGap(_:)` called from `ContentView` on the main thread.
    /// Reset to baseline when `DrivingContextService` is re-instantiated at the start
    /// of each Drive Mode session (see `handleDriveModeChange` in `ContentView`).
    /// Calibration deferred to W8.5c-follow after drive-test.
    private var voiceMinGapSeconds: TimeInterval = FinalApproachService.baselineVoiceGapSeconds

    // MARK: - Dependencies

    private let voice: DrivingVoice

    // MARK: - Init

    init(voice: DrivingVoice) {
        self.voice = voice
    }

    // MARK: - W8.5d: Voice gap update

    /// Sets the minimum gap between voice cues for the current Drive Mode session.
    ///
    /// Called from `ContentView`'s `.onChange(of: driveModeDistanceMeters)` handler
    /// (`handleFinalApproachUpdate`) on the main thread when `FinalApproachState` changes.
    ///
    /// Use `FinalApproachService.voiceGap(for:)` to derive the value:
    /// - `.outside`    → 12s (baseline, matches pre-W8.5d constant)
    /// - `.approaching` → 4s  (elevated cadence during final approach)
    /// - `.arrived`    → .infinity (suppresses voice; arrival prompt is the user cue)
    ///
    /// When `gap == .infinity`, the `speakContext` guard
    /// (`now.timeIntervalSince(lastSpokenAt) >= voiceMinGapSeconds`) always returns early,
    /// effectively suppressing voice with no new code path needed.
    ///
    /// Thread safety: must be called from the main thread (same thread as the
    /// `.onChange` modifier — `@Observable` property mutations are safe on main).
    func setVoiceGap(_ gap: TimeInterval) {
        voiceMinGapSeconds = gap
    }

    // MARK: - CM-2: Cruise Mode toggle

    /// Switches the voice cadence policy for the current Drive Mode session.
    ///
    /// Call with `true` immediately after `driveModeActive = true` for Cruise Mode entry,
    /// and with `false` on Drive Mode exit (or destination mode entry).
    ///
    /// When `isCruise == true`:
    ///   - Block-change announcements are gated by `CruiseVoicePolicy.shouldAnnounce(context:)`.
    ///   - Utterance text is generated by `CruiseVoicePolicy.utteranceText(for:)`.
    ///
    /// When `isCruise == false` (destination mode):
    ///   - Every block change triggers a voice cue (pre-CM-2 behavior — no regression).
    ///   - Utterance text is generated by `buildUtteranceText(_:)`.
    ///
    /// Thread safety: must be called from the main thread (same thread as
    /// `handleDriveModeChange` in ContentView — `@Observable` mutations are safe on main).
    func setCruiseMode(_ isCruise: Bool) {
        isCruiseMode = isCruise
    }

    // MARK: - Main update method

    /// Update the driving context for the given GPS position and heading.
    ///
    /// Call this on every `locationUpdateCount` change while Drive Mode is active.
    /// Performs closest-segment lookup, side classification, and block-change detection.
    ///
    /// - Parameters:
    ///   - coordinate: Driver's current GPS coordinate.
    ///   - heading: Stabilized heading in degrees (nil = use fallback convention).
    ///   - segments: Currently-loaded tile segments.
    ///   - engine: ParkingRulesEngine instance for safety label evaluation.
    ///   - date: Current date for rule evaluation. Defaults to `.nowET`.
    ///   - parkUntilMode: fix/goal-aware-drive-card — `ContentView`'s own `parkUntilMode`
    ///     `@State`, threaded straight through, unchanged. `false` (the default) preserves
    ///     every pre-fix call site byte-for-byte: `goalAwareChipSeverity` returns `nil` for
    ///     both sides whenever this is `false`, leaving `DrivingContext.leftChipColorOverride`/
    ///     `rightChipColorOverride` `nil` (chip falls back to legacy severity, unchanged).
    ///   - parkUntilTarget: `ContentView`'s own `parkUntilTarget` `@State`. Ignored when
    ///     `parkUntilMode` is `false`.
    ///   - parkUntilIgnoresMeteredPayment: `ContentView`'s own `parkUntilIgnoresMeteredPayment`
    ///     `@State` — always `false` on the goal path (no goal tolerates a running meter), and
    ///     at its `false` default for the power-user clock-set `ParkUntilSheet` path. This
    ///     function never imports `ParkingGoals` itself — it consumes whichever value the
    ///     map's own `rebuildOverlays()` already resolved.
    func update(
        coordinate: CLLocationCoordinate2D,
        heading: CLLocationDirection?,
        segments: [Segment],
        engine: ParkingRulesEngine,
        date: Date = .nowET,
        parkUntilMode: Bool = false,
        parkUntilTarget: Date? = nil,
        parkUntilIgnoresMeteredPayment: Bool = false
    ) {
        guard !segments.isEmpty else {
            currentContext = nil
            matchedSegment = nil
            matchedSiblings = []
            return
        }

        // Step 1: Find closest segment overall (port of findClosestSegment, index.html:5560).
        guard let closest = findClosestSegment(to: coordinate, in: segments) else {
            currentContext = nil
            matchedSegment = nil
            matchedSiblings = []
            return
        }

        // TF2-16: publish the same closest-segment result as a side-channel property —
        // no second matcher/distance-search, purely additive to the existing control flow.
        matchedSegment = closest

        // Step 2: Block identity — street + from + to of the closest segment.
        let block = (street: closest.street, from: closest.fromStreet, to: closest.to)

        // Step 3: Find all sides (N/S/E/W) for this block.
        // TF2-7: We now resolve cardinal side strings, not individual segments.
        let allSides = ["N", "S", "E", "W"]
        // Direction-agnostic: the two curbs of one block may list from/to reversed.
        let blockSiblings = segments.filter { DriveSideAssignment.sameBlock($0, as: closest) }
        matchedSiblings = blockSiblings
        let sidesPresent: [(side: String, segment: Segment)] = allSides.compactMap { s in
            guard let seg = blockSiblings.first(where: { $0.side == s }) else { return nil }
            return (s, seg)
        }

        // Step 4: Assign left/right curbs for the driver's TRAVEL direction (finding 8).
        // The travel bearing follows the matched street's polyline (one-way streets use their
        // legal direction); an unknown/unreliable heading keeps the last known direction
        // instead of flipping or blanking. See DriveSideAssignment.swift.
        let sideNames = sidesPresent.map { $0.side }
        var leftCardinalSide: String? = nil
        var rightCardinalSide: String? = nil
        let blockKeyForSides = DriveSideAssignment.canonicalBlockKey(
            street: block.street, from: block.from, to: block.to
        )
        if let travel = sideTravel.resolve(
            heading: heading, segment: closest, siblings: blockSiblings,
            blockKey: blockKeyForSides, coordinate: coordinate
        ) {
            let assigned = DriveSideAssignment.assign(sides: sideNames, travelBearing: travel)
            leftCardinalSide = assigned.left
            rightCardinalSide = assigned.right
        } else if !sideNames.isEmpty {
            // Step 5: no heading has ever been known (first fixes of a session).
            let fallback = DriveSideAssignment.cardinalFallback(sides: sideNames)
            leftCardinalSide = fallback.left
            rightCardinalSide = fallback.right
        }

        // Step 6: TF2-7 — side-level aggregation replaces single-segment safetyLabel calls.
        // TF2-17: aggregateSideDetail reduces ALL segments on the cardinal side to one
        // SideAggregation (opportunity classification + optional "Free until X" text).
        // Pre-filter to the current block (street + from + to) so aggregation only sees
        // segments for this block, not other blocks on the same cardinal side.
        // (spec §3.5: "segments: [Segment] — all segments for the current street/from/to combination")
        let blockSegments = blockSiblings  // direction-agnostic block grouping (Step 3)
        let leftAgg  = leftCardinalSide.map  { DrivingContextService.aggregateSideDetail(segments: blockSegments, side: $0, engine: engine, date: date) }
            ?? SideAggregation(opportunity: .unknown, earliestFreeUntilText: nil)
        let rightAgg = rightCardinalSide.map { DrivingContextService.aggregateSideDetail(segments: blockSegments, side: $0, engine: engine, date: date) }
            ?? SideAggregation(opportunity: .unknown, earliestFreeUntilText: nil)
        let leftLabel  = SafetyLabel(for: leftAgg)
        let rightLabel = SafetyLabel(for: rightAgg)

        // fix/goal-aware-drive-card: goal-aware (or clock-set Park Until) chip-color
        // override — computed from the SAME per-side raw segments as leftAgg/rightAgg
        // above, but tested with `engine.isFree(...)` (the map's own binary Park Until
        // predicate) instead of the legacy 5-color `safetyLabel`/`currentState`
        // classification those aggregations use. See `goalAwareChipSeverity`'s doc
        // comment for why this intentionally does NOT touch `leftLabel`/`rightLabel`.
        let leftSideSegments: [Segment] = leftCardinalSide.map { s in blockSegments.filter { $0.side == s } } ?? []
        let rightSideSegments: [Segment] = rightCardinalSide.map { s in blockSegments.filter { $0.side == s } } ?? []
        let leftChip = DrivingContextService.goalAwareChip(
            sideSegments: leftSideSegments,
            parkUntilMode: parkUntilMode,
            target: parkUntilTarget,
            ignoringMeteredPayment: parkUntilIgnoresMeteredPayment,
            from: date,
            engine: engine
        )
        let rightChip = DrivingContextService.goalAwareChip(
            sideSegments: rightSideSegments,
            parkUntilMode: parkUntilMode,
            target: parkUntilTarget,
            ignoringMeteredPayment: parkUntilIgnoresMeteredPayment,
            from: date,
            engine: engine
        )
        let leftChipColorOverride = leftChip?.severity
        let rightChipColorOverride = rightChip?.severity

        let context = DrivingContext(
            street: block.street,
            from: block.from,
            to: block.to,
            leftLabel: leftChip?.labelOverride ?? leftLabel,
            rightLabel: rightChip?.labelOverride ?? rightLabel,
            leftChipColorOverride: leftChipColorOverride,
            rightChipColorOverride: rightChipColorOverride
        )
        currentContext = context

        // Step 7: Block-change detection + voice trigger (index.html:5905–5908).
        //
        // CM-2: In Cruise Mode, gate through CruiseVoicePolicy.shouldAnnounce before speaking.
        // In Destination Mode, preserve the pre-CM-2 unconditional behavior (no regression).
        let blockKey = context.blockKey
        if blockKey != lastBlockKey {
            lastBlockKey = blockKey
            if !isCruiseMode {
                // Destination Mode: announce every block change (pre-CM-2 behavior preserved).
                // TF2-7: buildUtteranceText returns "" for the one-restricted+one-unknown case;
                // skip speakContext for empty text to avoid burning the 12s min-gap timer.
                let text = buildUtteranceText(context)
                if !text.isEmpty {
                    speakContext(context, text: text)
                }
            } else if CruiseVoicePolicy.shouldAnnounce(context: context) {
                // Cruise Mode: only announce when at least one side is free or metered.
                speakContext(context, text: CruiseVoicePolicy.utteranceText(for: context))
            }
            // Cruise Mode + all-restricted/unknown: silent (CruiseVoicePolicy.shouldAnnounce returned false).
        }
    }

    // MARK: - Voice cue builder

    /// Speaks the given utterance text via DrivingVoice, subject to the minimum-gap guard.
    ///
    /// CM-2: Takes an explicit `text` parameter rather than computing text internally,
    /// so the caller can inject either destination-mode phrasing (`buildUtteranceText`)
    /// or Cruise Mode phrasing (`CruiseVoicePolicy.utteranceText`).
    ///
    /// The `voiceMinGapSeconds` guard still applies regardless of mode. Mute gating is
    /// handled inside `DrivingVoice.speak` — this method does not need to check it.
    ///
    /// Port of speakDrivingContext (index.html:5957–5979):
    ///   "[StreetName]. Left side, [label]. Right side, [label]."
    ///   Abbreviations expanded: St → Street, Ave → Avenue, Blvd → Boulevard.
    ///   Sides with "No data" are omitted.
    private func speakContext(_ context: DrivingContext, text: String) {
        let now = Date()
        guard now.timeIntervalSince(lastSpokenAt) >= voiceMinGapSeconds else { return }
        lastSpokenAt = now
        voice.speak(text)
    }

    /// Builds the destination-mode voice utterance text for a driving context.
    ///
    /// TF2-7: Replaced the zone-by-zone format ("Left side, free until Thu 9:30am.
    /// Right side, no parking.") with the same catch-all templates used by
    /// `CruiseVoicePolicy.utteranceText(for:)` — spec §4.3.
    ///
    /// Destination mode retains one meaningful difference from Cruise Mode:
    /// all-restricted blocks are NOT silenced. If both sides are `.restricted`,
    /// destination mode announces: "[Street]. No parking on either side."
    /// This keeps the driver informed in navigation mode (spec §4.3).
    ///
    /// Copy strings (exact — QA verifies against these, spec §4.1):
    ///   - Both free      → "[Street]. Free parking sections on both sides — check signs."
    ///   - Left free only → "[Street]. Free parking sections on the left — check signs."
    ///   - Right free only→ "[Street]. Free parking sections on the right — check signs."
    ///   - No free, left metered only  → "[Street]. Metered on the left."
    ///   - No free, right metered only → "[Street]. Metered on the right."
    ///   - No free, both metered       → "[Street]. Metered on both sides."
    ///   - Both restricted → "[Street]. No parking on either side."
    ///   - One restricted + one unknown → (no announcement — consistent with Cruise Mode)
    ///
    /// TF2-18 note: `leftFree`/`rightFree` use `isFreeForVoice(_:)` so a side classified
    /// `.comingSoon` (P1-2) still reads as "free" for voice purposes — the new severity case
    /// only changes chip color/text, never spoken copy (OQ-4, locked by Test Inventory #10/#15).
    func buildUtteranceText(_ context: DrivingContext) -> String {
        let street = expandAbbreviations(titleCase(context.street))
        let leftFree     = DrivingContextService.isFreeForVoice(context.leftLabel.severity)
        let rightFree    = DrivingContextService.isFreeForVoice(context.rightLabel.severity)
        let leftMetered  = context.leftLabel.severity == .metered
        let rightMetered = context.rightLabel.severity == .metered
        let leftRestricted  = context.leftLabel.severity == .restricted
        let rightRestricted = context.rightLabel.severity == .restricted

        let clause: String
        if leftFree && rightFree {
            clause = "Free parking sections on both sides — check signs."
        } else if leftFree {
            clause = "Free parking sections on the left — check signs."
        } else if rightFree {
            clause = "Free parking sections on the right — check signs."
        } else if leftMetered && rightMetered {
            clause = "Metered on both sides."
        } else if leftMetered {
            clause = "Metered on the left."
        } else if rightMetered {
            clause = "Metered on the right."
        } else if leftRestricted && rightRestricted {
            // Destination mode: announce all-restricted blocks (spec §4.3 meaningful difference).
            // An UNKNOWN sign is the reason on either side: never claim "No parking".
            if context.leftLabel.text == UnclearSign.headline || context.rightLabel.text == UnclearSign.headline {
                clause = UnclearSign.spoken
            } else {
                clause = "No parking on either side."
            }
        } else {
            // One restricted + one unknown, or both unknown — no announcement value.
            // Return empty string; speakContext's min-gap guard still fires but the
            // empty string is harmless when spoken by AVSpeechSynthesizer.
            return ""
        }
        return "\(street). \(clause)"
    }

    // MARK: - TF2-18: Voice free-equivalence helper

    /// Returns `true` if `severity` should be treated as "free" for voice-cadence and
    /// voice-phrasing purposes.
    ///
    /// TF2-18 P1-2 added `SafetyLabel.Severity.comingSoon` (a side that's free right now but
    /// whose winning restriction starts within 6h). A `.comingSoon` side is still, in fact,
    /// free right now — the driver can park there — so voice must treat it exactly like
    /// `.free`: same cadence gating (`CruiseVoicePolicy.shouldAnnounce`) and same phrasing
    /// (`CruiseVoicePolicy.utteranceText`, `buildUtteranceText`). Only the chip color/text
    /// changes for `.comingSoon`; this helper is what keeps voice output byte-identical
    /// before/after the P1-2 severity split (OQ-4, Test Inventory #10/#15 extended).
    static func isFreeForVoice(_ severity: SafetyLabel.Severity) -> Bool {
        severity == .free || severity == .comingSoon
    }

    // MARK: - TF2-7 / TF2-17: Side-level aggregation

    /// Public wrapper preserving the pre-TF2-17 signature and return type.
    ///
    /// TF2-17 §3: `aggregateSide` is now a thin wrapper over
    /// `aggregateSideDetail(...).opportunity` — pure refactor for reuse, not a behavior
    /// change. All 9 pre-existing `TF27Tests` decision-table outcomes are preserved exactly.
    ///
    /// - Returns: `SideOpportunity` classification for the given side.
    static func aggregateSide(
        segments: [Segment],
        side: String,
        engine: ParkingRulesEngine,
        date: Date,
        minimumFreeLength: Double = 6.0
    ) -> SideOpportunity {
        aggregateSideDetail(
            segments: segments, side: side, engine: engine, date: date,
            minimumFreeLength: minimumFreeLength
        ).opportunity
    }

    /// Reduces all segments on one cardinal side of the current block to a single
    /// `SideAggregation` — answers "is there any free stretch, metered zone, or nothing
    /// usable on this side?" (the `.opportunity` field, unchanged from TF2-7's
    /// `aggregateSide` algorithm) AND, when the side is free/comingSoon, which exact
    /// "Free until X" text to show (TF2-17 §5.1 — the earliest-restriction ranking, "earliest"
    /// meaning smallest `nextRestriction.hours`, a conservative-min policy).
    ///
    /// Pure static function contract: no side effects, no stored state, no framework imports.
    /// Testable at zero cost. Mirrors the `CruiseVoicePolicy` / `FinalApproachService` pattern.
    ///
    /// Algorithm:
    ///   1. Filter `segments` to those matching the given cardinal `side`.
    ///   2. For each matching segment, call `engine.safetyLabel(for: segment, at: date)`.
    ///   3. Segments with severity `.free` AND haversine length ≥ `minimumFreeLength` are
    ///      "qualifying free" — collected (not short-circuited, unlike pre-TF2-17
    ///      `aggregateSide`) so every qualifying segment's upcoming restriction can be ranked.
    ///      A sub-`minimumFreeLength` free sliver beside a restricted zone is not actionable
    ///      and is excluded, same as before.
    ///   4. If `qualifyingFree` is non-empty → `.opportunity` is `.free` or `.comingSoon`
    ///      (never `.metered`/`.restricted`/`.unknown` — free takes priority, TF2-7 precedence
    ///      unchanged). For each qualifying segment, call `engine.nextRestriction(for:at:)`.
    ///      OQ-3: this intentionally skips METERED rules (they're not a move-your-car
    ///      restriction, `ParkingRulesEngine.swift` `nextRestriction` already excludes them) —
    ///      a "free until 9am" driven purely by an upcoming meter start does not supply the
    ///      ranking text. Segments with `hours >= 168` (no restriction within the 14-day
    ///      window) are excluded from the ranking. Among the remainder, the segment with the
    ///      SMALLEST `hours` wins; its `SafetyLabel.text` becomes `earliestFreeUntilText`.
    ///      TF2-18 P1-2: if the winning segment's `hours < nearFutureWindow` (6h) AND its
    ///      restriction category isn't metered, `.opportunity` is `.comingSoon` instead of
    ///      `.free` (mirrors `ParkingRulesEngine.currentState`'s `.freeButRestrictionSoon`
    ///      classification for that same segment). If no qualifying segment has any
    ///      restriction within 14 days, `earliestFreeUntilText` is `nil` and `.opportunity`
    ///      stays `.free` — no fabricated "until" (OQ-1).
    ///   5. If `qualifyingFree` is empty but any segment has severity `.metered` →
    ///      `.opportunity` is `.metered`, `earliestFreeUntilText` is `nil`.
    ///   6. If segments were found but none were free or metered → `.opportunity` is
    ///      `.restricted`, `earliestFreeUntilText` is `nil`.
    ///   7. If no segments matched the side → `.opportunity` is `.unknown`,
    ///      `earliestFreeUntilText` is `nil`.
    ///
    /// - Parameters:
    ///   - segments: All segments for the current tile region (not pre-filtered to block).
    ///   - side: Cardinal side string — "N", "S", "E", or "W".
    ///   - engine: ParkingRulesEngine for safetyLabel/nextRestriction evaluation.
    ///   - date: Evaluation date. Pass `.nowET` in production; inject a fixed date in tests.
    ///   - minimumFreeLength: Minimum free-stretch length in meters to count as qualifying.
    ///     Defaults to 6.0m (one car length — same as the tile-geometry intersection-clip
    ///     setback constant from PR #21, spec §3.3). Injectable for unit tests.
    ///
    /// - Returns: `SideAggregation` for the given side.
    static func aggregateSideDetail(
        segments: [Segment],
        side: String,
        engine: ParkingRulesEngine,
        date: Date,
        minimumFreeLength: Double = 6.0
    ) -> SideAggregation {
        // Step 1: Filter to segments matching the given cardinal side.
        let sideSegments = segments.filter { $0.side == side }

        // Step 7 (early): no segments found for this side → unknown (data gap).
        guard !sideSegments.isEmpty else {
            return SideAggregation(opportunity: .unknown, earliestFreeUntilText: nil)
        }

        var hasMetered = false
        var qualifyingFree: [(seg: Segment, label: SafetyLabel)] = []
        var allUnclearOrNoData = true

        // Steps 2–3: classify each segment.
        for seg in sideSegments {
            let label = engine.safetyLabel(for: seg, at: date)
            if !(seg.hasNoSignData || label.text == UnclearSign.headline) { allUnclearOrNoData = false }
            switch label.severity {
            case .free:
                // Step 3: check minimum free-stretch length via haversine.
                let length = segmentLengthMeters(seg)
                if length >= minimumFreeLength {
                    qualifyingFree.append((seg, label))
                }
                // Free segment too short — excluded. Not actionable, same as before.
            case .metered:
                hasMetered = true
            case .restricted, .unknown, .comingSoon:
                // `.comingSoon` never comes from `engine.safetyLabel` (that engine method's
                // severity space is unchanged — free/metered/restricted/unknown only). Listed
                // here only so the switch stays exhaustive against `SafetyLabel.Severity`.
                break
            }
        }

        // Step 4: at least one qualifying free segment → rank by earliest upcoming restriction.
        if !qualifyingFree.isEmpty {
            var best: (hours: Double, category: Category?, text: String)? = nil
            for (seg, label) in qualifyingFree {
                let restriction = engine.nextRestriction(for: seg, at: date)
                guard restriction.hours < 168 else { continue }  // no restriction within 14 days
                if best == nil || restriction.hours < best!.hours {
                    best = (restriction.hours, restriction.category, label.text)
                }
            }
            guard let winner = best else {
                // OQ-1: no qualifying segment has any restriction within 14 days.
                return SideAggregation(opportunity: .free, earliestFreeUntilText: nil)
            }
            // TF2-18 P1-2: mirror ParkingRulesEngine.currentState's freeButRestrictionSoon
            // classification for the WINNING segment — same 6h window (single source of
            // truth: ParkingRulesEngine.nearFutureWindowHours), same "metered doesn't count"
            // exclusion (a metered category never reaches here anyway per OQ-3, but the check
            // is kept for symmetry with currentState's own guard).
            let isComingSoon = winner.hours < ParkingRulesEngine.nearFutureWindowHours && winner.category != .metered
            return SideAggregation(
                opportunity: isComingSoon ? .comingSoon : .free,
                earliestFreeUntilText: winner.text
            )
        }

        // Step 5: no qualifying free, but at least one metered.
        if hasMetered {
            return SideAggregation(opportunity: .metered, earliestFreeUntilText: nil)
        }

        // Step 6: segments found but none free or metered.
        // Every segment lacks sign data: say so (still red / not free) rather than "No parking".
        return SideAggregation(
            opportunity: .restricted,
            earliestFreeUntilText: nil,
            noSignData: sideSegments.allSatisfy { $0.hasNoSignData },
            unclearSign: allUnclearOrNoData && !sideSegments.allSatisfy { $0.hasNoSignData }
        )
    }

    // MARK: - fix/goal-aware-drive-card: goal-aware chip-color override

    /// Same one-car-length threshold `aggregateSideDetail` uses for its free-stretch text.
    nonisolated static let minimumSubjectLengthMeters: Double = 6.0

    /// Computes the goal-aware (or clock-set Park Until) chip-color OVERRIDE for one side
    /// of the current block (Kevin smoke, 2026-10-26: an escalated-Cruise session with the
    /// Overnight goal active showed BOTH side chips green via the legacy `aggregateSideDetail`
    /// classification above, while the map painted the left side red because it fails the
    /// Overnight goal — the text ["Free until Tomorrow 8:00 AM"] was honest, the COLOR lied).
    ///
    /// Mirrors `ContentView.rebuildOverlays()`'s `parkUntilMode` branch EXACTLY — the same
    /// `engine.isFree(segment:from:until:ignoringMeteredPayment:)` call, collapsed to the
    /// same two-color (`.free` / `.restricted`) bucket the map's binary Park Until overlay
    /// already uses. Deliberately gated on `parkUntilMode` alone — NOT on
    /// `AppConstants.driveModeDefaultEnabled` and NOT on a `ParkingGoal` parameter. The
    /// map's own overlay branch doesn't care whether `parkUntilTarget` came from a goal tap
    /// (`docs/drive-mode-default-spec.md` §0.8) or the power-user clock-set `ParkUntilSheet`
    /// (§0.8.9) — both set the identical `parkUntilMode`/`parkUntilTarget`/
    /// `parkUntilIgnoresMeteredPayment` triple in `ContentView`, so gating on `parkUntilMode`
    /// alone covers BOTH of the smoke finding's fix items with one mechanism and zero new
    /// `ParkingGoals` coupling in this file — `ContentView` has already resolved
    /// `ignoringMeteredPayment` (strict `false` on both paths) by the time this is called. This also means the fix applies correctly flag-OFF (clock-set Park Until
    /// has shipped and is reachable with `driveModeDefaultEnabled == false`) — see this
    /// fix's PR description for the alternative considered (gating on the flag) and why it
    /// was rejected.
    ///
    /// "Side passes" = ANY qualifying segment (free now, >= 6 m) passes `isFree(...)` for the
    /// whole window - see `goalAwareChip`. Returns `nil` (defer to the legacy severity,
    /// unchanged) when `parkUntilMode` is `false`, `target` is `nil`, or there are no
    /// segments for this side.
    ///
    /// Pure, `nonisolated static` — no stored state, no side effects. Does NOT read
    /// `SafetyLabel`/`SideOpportunity` at all; this answers the SAME binary question the
    /// map's overlay answers, independent of the 5-color legacy classification
    /// `aggregateSideDetail` computes for TEXT purposes.
    nonisolated static func goalAwareChipSeverity(
        sideSegments: [Segment],
        parkUntilMode: Bool,
        target: Date?,
        ignoringMeteredPayment: Bool,
        from: Date,
        engine: ParkingRulesEngine
    ) -> SafetyLabel.Severity? {
        return goalAwareChip(
            sideSegments: sideSegments,
            parkUntilMode: parkUntilMode,
            target: target,
            ignoringMeteredPayment: ignoringMeteredPayment,
            from: from,
            engine: engine
        )?.severity
    }

    /// Chip color plus (when the color would otherwise contradict it) the chip text.
    struct GoalAwareChip: Equatable {
        /// `.free` iff a driver can find a legal spot on this side for the whole window.
        let severity: SafetyLabel.Severity
        /// Replacement label, or `nil` to keep the legacy `aggregateSideDetail` label.
        let labelOverride: SafetyLabel?
    }

    /// Owner rule: the chip is GREEN iff a driver can actually find a legal spot on this
    /// side for the whole goal window. Chip color, text and map must agree.
    ///
    /// Qualifying set (what a driver could pull into): free-now segments at least
    /// `minimumSubjectLengthMeters` long; else merely long enough; else all. The side is
    /// green iff ANY qualifying segment passes `engine.isFree(...)` for the whole window
    /// (`contains(where:)`) - the same call the map overlay makes. (Was `allSatisfy`, which
    /// let one 13.7 m NO STANDING Tue-Sat 7AM-4PM stub turn E 2nd St red above six green
    /// ASP segments.)
    ///
    /// Text: when green, the "Free until ..." text is recomputed from the PASSING segments
    /// only (`aggregateSideDetail`'s earliest-next-restriction ranking, restricted to that
    /// set), so it never describes a segment that fails the window. We keep the existing
    /// conservative-earliest policy rather than "longest" so the claim holds for every spot
    /// the green line shows. When red and the legacy label would still say "Free until ..."
    /// (free now, but every spot fails the window), the text becomes "Not free through your
    /// window" instead of a misleading "Free until" for a segment that fails.
    nonisolated static func goalAwareChip(
        sideSegments: [Segment],
        parkUntilMode: Bool,
        target: Date?,
        ignoringMeteredPayment: Bool,
        from: Date,
        engine: ParkingRulesEngine
    ) -> GoalAwareChip? {
        guard parkUntilMode, let target, !sideSegments.isEmpty else { return nil }
        let longEnough = sideSegments.filter { segmentLengthMeters($0) >= minimumSubjectLengthMeters }
        let freeNow = longEnough.filter { engine.safetyLabel(for: $0, at: from).severity == .free }
        let subject = !freeNow.isEmpty ? freeNow : (!longEnough.isEmpty ? longEnough : sideSegments)
        let passing = subject.filter {
            engine.isFree(
                segment: $0,
                from: from,
                until: target,
                ignoringMeteredPayment: ignoringMeteredPayment
            )
        }
        if passing.isEmpty {
            // Red. Only the free-now case needs a text fix; "No parking"/"Metered" already agree.
            return GoalAwareChip(
                severity: .restricted,
                labelOverride: freeNow.isEmpty ? nil
                    : SafetyLabel(text: "Not free through your window", severity: .restricted)
            )
        }
        // Green. Text from the passing set (only meaningful when they are free-now segments).
        guard !freeNow.isEmpty else { return GoalAwareChip(severity: .free, labelOverride: nil) }
        let agg = aggregateSideDetail(segments: passing, side: passing[0].side, engine: engine, date: from)
        return GoalAwareChip(severity: .free, labelOverride: SafetyLabel(for: agg))
    }

    /// Computes the haversine length of a segment's polyline in meters.
    ///
    /// Sums the haversine distance between consecutive coordinate pairs in `segment.line`.
    /// Used by `aggregateSide` to check the 6m minimum-free-stretch threshold (spec §3.3).
    ///
    /// Internal (not private) so `TF27Tests` can verify the threshold behaviour directly
    /// without needing to construct a full `ParkingRulesEngine` context.
    /// Accessibility note: `@testable import WePark` exposes `internal` to tests.
    nonisolated static func segmentLengthMeters(_ segment: Segment) -> Double {
        let coords = segment.line
        guard coords.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(coords.count - 1) {
            guard coords[i].count >= 2, coords[i+1].count >= 2 else { continue }
            let a = CLLocationCoordinate2D(latitude: coords[i][0], longitude: coords[i][1])
            let b = CLLocationCoordinate2D(latitude: coords[i+1][0], longitude: coords[i+1][1])
            total += staticHaversineMeters(from: a, to: b)
        }
        return total
    }

    /// Static haversine helper for use by `aggregateSide` and `segmentLengthMeters`.
    /// Mirrors the instance `haversineMeters(from:to:)` method; kept static so `aggregateSide`
    /// (which is static) can call it without a service instance.
    nonisolated private static func staticHaversineMeters(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let sinHalfLat = sin(dLat / 2)
        let sinHalfLng = sin(dLng / 2)
        let h = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLng * sinHalfLng
        return 2 * R * asin(sqrt(h))
    }

    // MARK: - Geometry: closest segment

    /// Finds the segment with the minimum haversine distance from `coordinate`.
    /// Port of findClosestSegment (index.html:5560, which delegates to the tile-level function).
    private func findClosestSegment(to coordinate: CLLocationCoordinate2D, in segments: [Segment]) -> Segment? {
        var closest: Segment? = nil
        var closestDist = Double.infinity

        for seg in segments {
            guard seg.line.count >= 2 else { continue }
            let dist = pointToPolylineDistanceMeters(from: coordinate, line: seg.line)
            if dist < closestDist {
                closestDist = dist
                closest = seg
            }
        }
        return closest
    }


    /// Minimum distance from a point to a polyline defined by [lat, lng] pairs.
    private func pointToPolylineDistanceMeters(
        from coordinate: CLLocationCoordinate2D,
        line: [[Double]]
    ) -> Double {
        var minDist = Double.infinity
        for i in 0..<(line.count - 1) {
            guard line[i].count >= 2, line[i+1].count >= 2 else { continue }
            let a = CLLocationCoordinate2D(latitude: line[i][0], longitude: line[i][1])
            let b = CLLocationCoordinate2D(latitude: line[i+1][0], longitude: line[i+1][1])
            let d = pointToSegmentDistanceMeters(point: coordinate, a: a, b: b)
            if d < minDist { minDist = d }
        }
        return minDist
    }

    private func pointToSegmentDistanceMeters(
        point: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> Double {
        let metersPerDegLat = 111_320.0
        let cosLat = cos(a.latitude * .pi / 180.0)
        let metersPerDegLng = metersPerDegLat * cosLat

        let px = (point.longitude - a.longitude) * metersPerDegLng
        let py = (point.latitude  - a.latitude)  * metersPerDegLat
        let bx = (b.longitude - a.longitude) * metersPerDegLng
        let by = (b.latitude  - a.latitude)  * metersPerDegLat

        let abLenSq = bx * bx + by * by
        if abLenSq == 0 {
            return haversineMeters(from: point, to: a)
        }

        let t = max(0, min(1, (px * bx + py * by) / abLenSq))
        let closestLat = a.latitude  + (t * by) / metersPerDegLat
        let closestLng = a.longitude + (t * bx) / metersPerDegLng
        return haversineMeters(from: point, to: CLLocationCoordinate2D(latitude: closestLat, longitude: closestLng))
    }

    private func haversineMeters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let sinHalfLat = sin(dLat / 2)
        let sinHalfLng = sin(dLng / 2)
        let h = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLng * sinHalfLng
        return 2 * R * asin(sqrt(h))
    }

    // MARK: - Text helpers

    /// Converts a string to Title Case.
    private func titleCase(_ s: String) -> String {
        s.split(separator: " ").map { word in
            let str = String(word)
            return str.prefix(1).uppercased() + str.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Expands common street abbreviations for voice clarity.
    /// Port of speakDrivingContext's replace calls (index.html:5964).
    func expandAbbreviations(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\bSt\\b", with: "Street", options: .regularExpression)
            .replacingOccurrences(of: "\\bAve\\b", with: "Avenue", options: .regularExpression)
            .replacingOccurrences(of: "\\bBlvd\\b", with: "Boulevard", options: .regularExpression)
            .replacingOccurrences(of: "\\bDr\\b", with: "Drive", options: .regularExpression)
            .replacingOccurrences(of: "\\bPl\\b", with: "Place", options: .regularExpression)
            .replacingOccurrences(of: "\\bRd\\b", with: "Road", options: .regularExpression)
    }
}
