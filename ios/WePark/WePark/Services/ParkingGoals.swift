//
//  ParkingGoals.swift
//  WePark
//
//  DM-2e — §0.8 goal-first parking (docs/drive-mode-default-spec.md, 2026-10-20
//  amendment). Pure-Foundation resolution layer for the three ambient-home-screen
//  goals (§0.8.1): Free Overnight, Free a Few Hours, Park & Forget. Each goal
//  resolves to a target `Date` (or, for Park & Forget, a step-down ladder of
//  candidate dates) fed straight into the EXISTING `ParkingRulesEngine.isFree(...)`
//  call that Park Until already uses — no new map-rendering code, no new overlay
//  bucket (§0.8.6).
//
//  Re-scoped 2026-10-20 (file table, §3.3): this file is DM-2e's — the goal-
//  resolution math. `Views/GoalSelectorView.swift` (DM-2, not yet built) is the UI
//  consumer; the two streams never touch the same file.
//
//  NO import SwiftUI (AC-14's service-file rule). Calendar.easternTime only — zero
//  Calendar.current references.
//
//  Kevin's rulings baked in here (amendment banner, 2026-10-20 — all five now LOCKED):
//    1. Park & Forget ladder RULED LOCKED at offsetDays 8 → 4 → 2 (7 → 3 → 1 full
//       clear days), confirmed against the shipped tile data (46,925 segments).
//       Implemented to the offsets; never surfaced to users as "rung" numbers —
//       the "Good through <day>" label (§0.8.3a) is the only user-facing framing.
//    2. "Free a few hours" = +3h — RULED, confirmed ("sure good idea").
//    5. "Free a few hours" metered tolerance — RULED strict (Kevin: "it's a meter
//       so that's not free") — `ignoringMeteredPayment: false` for this goal only.
//
//  Port map (this file has no PWA equivalent — goal-first is iOS-only, §3.2):
//    n/a — composes `ParkingRulesEngine.isFree(...)` / `nextRestriction(...)`,
//    both already-ported/tested pure functions.
//

import Foundation

// MARK: - ParkingGoal

/// The three ambient-home-screen goal presets (§0.8.1). Each case answers one
/// plain-English question; `ParkingGoals` resolves it to a target `Date` (or, for
/// `.parkAndForget`, a per-segment ladder of candidate dates) that feeds straight
/// into the already-shipped `ParkingRulesEngine.isFree(...)` / Park Until binary
/// overlay (`ContentView.parkUntilMode` / `parkUntilTarget`, §0.8.6 — unchanged by
/// this file).
enum ParkingGoal: String, CaseIterable, Equatable {
    /// "Will I have to move it for tomorrow's sweep?" — the pre-selected default on
    /// every cold launch (§0.8.1). Low bar: clears tonight + all of tomorrow,
    /// evaluated as a calendar-day boundary rather than a clock hour (§0.8.2).
    case freeOvernight

    /// "Can I leave it untouched — no payment, no risk — for a few hours?" Low bar,
    /// strict window: a metered block with paid hours active inside the window still
    /// disqualifies (§0.8.5 — Kevin: "it's a meter so that's not free").
    case freeFewHours

    /// "What's the longest I can leave it without moving it at all?" High bar, the
    /// holy grail (§0.8.3) — resolved via a step-down ladder, never a single
    /// checkpoint, so the map never has to show "zero matches" unless a block fails
    /// even Free Overnight's own bar (§0.8.10).
    case parkAndForget
}

// MARK: - GoalMatchResult

/// Result of evaluating one segment against one goal (`ParkingGoals.match`).
///
/// `clearedRungOffsetDays` is only meaningful for `.parkAndForget` (§0.8.3's ladder)
/// — it records which `ParkingGoals.parkAndForgetLadderOffsetDays` rung the segment
/// cleared, so callers can rank matching segments (§0.8.3a: "a block that clears the
/// top rung is labeled/ranked above one that only clears the bottom"). `nil` for
/// `.freeOvernight` / `.freeFewHours` (single-checkpoint goals, no ladder) and for
/// any non-matching segment (`matches == false`).
struct GoalMatchResult: Equatable {
    let matches: Bool
    let clearedRungOffsetDays: Int?
}

// MARK: - ParkingGoals

/// Pure resolution layer: goal → target date(s) → `isFree()` call → match result,
/// plus the per-segment "Good through <day>" ranking label (§0.8.3a).
///
/// Zero SwiftUI, zero stored state, zero side effects — every function here is a
/// `nonisolated static` pure function over its inputs, mirroring `FinalApproachService`'s
/// precedent (W8.5d) for isolated, trivially-unit-testable Drive-Mode-adjacent logic.
/// `nonisolated` is explicit throughout (this project's `SWIFT_DEFAULT_ACTOR_ISOLATION
/// = MainActor` build setting would otherwise tie these statics to the main actor,
/// same convention as `GarageSavingsService`/`CommunityPinService`/`Constants`).
enum ParkingGoals {

    // MARK: - Constants (Kevin's 2026-10-20 rulings)

    /// Free Overnight's day-boundary offset (§0.8.2). `offsetDays: 2` from
    /// `Date.nowET.startOfDayET(...)` = midnight at the start of the day AFTER
    /// tomorrow — the SAME idiom `ParkUntilSheet.tonightMidnight()` uses with
    /// `offsetDays: 1`, one day further out. A day-boundary target makes the
    /// per-zone ASP start hour irrelevant: the window fully contains tomorrow's
    /// entire calendar day regardless of what hour the sweep actually starts.
    nonisolated static let freeOvernightOffsetDays = 2

    /// Free a Few Hours' fixed interval (§0.8.5, RULED LOCKED 2026-10-20: "sure good
    /// idea"). Splits the difference between `ParkUntilSheet`'s existing 2hr/4hr
    /// presets.
    nonisolated static let freeFewHoursInterval: TimeInterval = 3 * 3600

    /// Park & Forget's step-down ladder, RULED LOCKED 2026-10-20, highest (widest)
    /// rung first. In full clear days this is 7 → 3 → 1 — the amendment banner's
    /// ruling #1: the original draft's "7d → 4d → 2d" labels were sloppy `offsetDays`
    /// shorthand; implement to these offsets, describe to users in "Good through
    /// <day>" terms only (§0.8.3a), never rung numbers.
    nonisolated static let parkAndForgetLadderOffsetDays: [Int] = [8, 4, 2]

    // MARK: - Target resolution (§0.8.2, §0.8.5)

    /// Resolves a goal's SINGLE target date, from `from`. For `.parkAndForget`, this
    /// returns the top (widest) rung's target only — callers that need the real
    /// per-segment step-down behavior should use `match(segment:goal:from:engine:)`
    /// instead, which walks the full ladder per segment rather than committing to one
    /// fixed target up front.
    nonisolated static func target(for goal: ParkingGoal, from: Date = .nowET) -> Date {
        switch goal {
        case .freeOvernight:
            return from.startOfDayET(offsetDays: freeOvernightOffsetDays)
        case .freeFewHours:
            return from.addingTimeInterval(freeFewHoursInterval)
        case .parkAndForget:
            return from.startOfDayET(offsetDays: parkAndForgetLadderOffsetDays[0])
        }
    }

    /// Whether a goal's `isFree(...)` call ignores metered payment (§0.8.4).
    /// `true` for the overnight family (Free Overnight, Park & Forget) — their job is
    /// "would I have to MOVE it," and paying a meter doesn't force relocation.
    /// `false` for Free a Few Hours (RULED LOCKED strict, §0.8.5 — Kevin: "it's a
    /// meter so that's not free").
    nonisolated static func ignoresMeteredPayment(for goal: ParkingGoal) -> Bool {
        switch goal {
        case .freeOvernight, .parkAndForget:
            return true
        case .freeFewHours:
            return false
        }
    }

    // MARK: - Per-segment match (§0.8.3's ladder walk)

    /// Evaluates one segment against one goal, from `from`, using `engine`.
    ///
    /// For `.freeOvernight` / `.freeFewHours`: a single `isFree(...)` call against the
    /// goal's one checkpoint (§0.8.1 / §0.8.2 / §0.8.5).
    ///
    /// For `.parkAndForget`: walks the ladder top rung first (§0.8.3) — `offsetDays:
    /// 8`, then `4`, then `2` — and returns the FIRST (highest) rung the segment
    /// clears. A segment that fails even the bottom rung (2 — the same bar as Free
    /// Overnight) is non-matching; this function does not invent a fourth
    /// "never clears" state — the empty-map guard (§0.8.10) is a UI-layer concern
    /// (DM-2), not this function's.
    ///
    /// `ignoringMeteredPayment` is always derived from `ignoresMeteredPayment(for:)`
    /// internally — never accepted as a separate parameter — so a goal's metered
    /// tolerance can't drift between this function and `target(for:from:)`.
    nonisolated static func match(
        segment: Segment,
        goal: ParkingGoal,
        from: Date = .nowET,
        engine: ParkingRulesEngine
    ) -> GoalMatchResult {
        let ignoringMetered = ignoresMeteredPayment(for: goal)

        switch goal {
        case .freeOvernight, .freeFewHours:
            let checkpoint = target(for: goal, from: from)
            let ok = engine.isFree(
                segment: segment,
                from: from,
                until: checkpoint,
                ignoringMeteredPayment: ignoringMetered
            )
            return GoalMatchResult(matches: ok, clearedRungOffsetDays: nil)

        case .parkAndForget:
            for offsetDays in parkAndForgetLadderOffsetDays {
                let checkpoint = from.startOfDayET(offsetDays: offsetDays)
                let ok = engine.isFree(
                    segment: segment,
                    from: from,
                    until: checkpoint,
                    ignoringMeteredPayment: ignoringMetered
                )
                if ok {
                    return GoalMatchResult(matches: true, clearedRungOffsetDays: offsetDays)
                }
            }
            return GoalMatchResult(matches: false, clearedRungOffsetDays: nil)
        }
    }

    // MARK: - Ranking / labeling (§0.8.3a)

    /// The actual next move-forcing restriction date for a segment, honoring
    /// `goal`'s own metered tolerance (§0.8.4 — `ignoringMeteredPayment: true` for
    /// the overnight family, `false` for Free a Few Hours). Returns the ET midnight
    /// of the first calendar day carrying a move-forcing restriction — day-level
    /// precision only; §0.8.3a's "Good through <day>" label only ever needs the
    /// day, never a clock time.
    ///
    /// `goal` is a REQUIRED parameter, not defaulted — this closes a QA-flagged trap
    /// (pass 1, Finding #2): an earlier draft of this function hardcoded the
    /// overnight family's `ignoringMeteredPayment: true` with no way for a future
    /// caller evaluating Free a Few Hours to get the strict semantics that goal
    /// actually requires. Requiring `goal` here means the metered tolerance can
    /// never drift from `ignoresMeteredPayment(for:)`, for any caller.
    ///
    /// **Does NOT compose `ParkingRulesEngine.nextRestriction(for:at:)`** (QA pass 1,
    /// Finding #1, blocking). That function has a real, pre-existing asymmetry:
    /// `NO_PARKING`/`TRUCK_LOADING` rules get a full forward walk even when not
    /// active right now, but `NO_STANDING`/`SPECIAL` rules only check "is this
    /// active RIGHT NOW" — a scheduled (non-`anytime`) `NO_STANDING`/`SPECIAL` rule
    /// that isn't active at the exact instant `nextRestriction` is called is
    /// invisible to it, and it silently falls through with zero contribution (no
    /// forward walk, no sentinel update). That's a real, mainstream restriction
    /// shape in the shipped tile data (QA's 400-tile sample: 100% of `SPECIAL`
    /// rules, ~41% of `NO_STANDING` rules are this scheduled shape) — composing
    /// `nextRestriction` here silently reported "no restriction found" for those
    /// segments, which this function's ranking consumer then read as "indefinitely
    /// clear," ranking a bottom-rung segment ABOVE a top-rung one. See
    /// `ParkingGoalsTests.swift`'s `testNextMoveForcingDate_scheduled...` tests for
    /// the exact reproduction.
    ///
    /// Instead, this walks calendar days directly via `isFree(..., until:)` — the
    /// SAME day-walk `match(...)` already uses for the ladder. `isFree`'s day-walk
    /// evaluates `NO_STANDING`/`SPECIAL`/`NO_PARKING`/`TRUCK_LOADING` schedules
    /// identically on ANY future calendar day (not just "right now"), and already
    /// skips suspended ASP dates — so suspension-skip honesty (§0.8.3a's "no new
    /// code needed" claim) still holds, just via a different composition than the
    /// original draft. One `isFree` call per calendar day up to `searchHorizonDays`
    /// — cheap, since each call's own internal day-walk only spans the single day
    /// passed in.
    ///
    /// Returns `nil` when no restriction is found within `searchHorizonDays` — i.e.
    /// this segment has no weekly move-forcing rule at all (or none within the
    /// horizon). A `nil` result means "clear indefinitely, as far as this function
    /// can see" — callers should treat it as the best possible outcome, not an error.
    nonisolated static func nextMoveForcingDate(
        for segment: Segment,
        goal: ParkingGoal,
        from: Date = .nowET,
        engine: ParkingRulesEngine,
        searchHorizonDays: Int = 14
    ) -> Date? {
        let ignoringMetered = ignoresMeteredPayment(for: goal)

        for dayOffset in 0..<searchHorizonDays {
            let windowStart = dayOffset == 0 ? from : from.startOfDayET(offsetDays: dayOffset)
            let windowEnd = from.startOfDayET(offsetDays: dayOffset + 1)
            guard windowEnd > windowStart else { continue }

            let clearThisDay = engine.isFree(
                segment: segment,
                from: windowStart,
                until: windowEnd,
                ignoringMeteredPayment: ignoringMetered
            )
            if !clearThisDay {
                return from.startOfDayET(offsetDays: dayOffset)
            }
        }
        return nil
    }

    /// "Good through <day>" ranking label for a matching segment (§0.8.3a). `nil`
    /// when `nextMoveForcingDate` is `nil` (no restriction found — see that
    /// function's doc comment). Callers (DM-2's UI) decide what to show in that
    /// case; this function doesn't invent a fallback string.
    ///
    /// `goal` is required for the same reason it's required on
    /// `nextMoveForcingDate` (QA pass 1, Finding #2) — this label must never
    /// silently use the overnight family's loose metered tolerance for a goal that
    /// doesn't want it. Note for a future DM-2 caller: ranking has no real value
    /// for `.freeFewHours` (every match clears an identical flat 3-hour bar, so
    /// there's nothing to distinguish) — this function will still behave correctly
    /// if called for that goal, but DM-2's UI likely has no reason to call it there.
    nonisolated static func goodThroughLabel(
        for segment: Segment,
        goal: ParkingGoal,
        from: Date = .nowET,
        engine: ParkingRulesEngine
    ) -> String? {
        guard let date = nextMoveForcingDate(for: segment, goal: goal, from: from, engine: engine) else {
            return nil
        }
        let day = relativeDayLabel(for: date, from: from)
        // Mid-sentence: "Good through tomorrow", not "Tomorrow" (weekday/date labels keep their case).
        return "Good through " + ((day == "Today" || day == "Tomorrow") ? day.lowercased() : day)
    }

    /// Date-only relative-day label — "Today" / "Tomorrow" / a weekday abbreviation
    /// (2-6 days out) / "MMM d" (7+ days out). Pure-Foundation re-derivation of
    /// `ParkUntilSheet.formatTime`'s tier logic with the time-of-day component
    /// dropped — this file cannot import `ParkUntilSheet` (a SwiftUI view) per
    /// AC-14's service-file rule, so the tiers are re-implemented here against the
    /// same day-diff math rather than shared.
    ///
    /// "Today" is included defensively (`dayDiff <= 0`) even though a matching
    /// segment's next move-forcing date landing on "today" shouldn't reach this
    /// label in practice (a restriction active later today would normally make
    /// `from`'s own checkpoint fail first) — degrades gracefully rather than
    /// producing a negative-sounding date.
    nonisolated static func relativeDayLabel(for date: Date, from: Date = .nowET) -> String {
        let cal = Calendar.easternTime
        let fromMidnight = cal.startOfDay(for: from)
        let dateMidnight = cal.startOfDay(for: date)
        let dayDiff = cal.dateComponents([.day], from: fromMidnight, to: dateMidnight).day ?? 0

        switch dayDiff {
        case ...0:
            return "Today"
        case 1:
            return "Tomorrow"
        case 2...6:
            let fmt = DateFormatter()
            fmt.timeZone = .easternTime
            fmt.locale = Locale(identifier: "en_US")
            fmt.dateFormat = "EEE"
            return fmt.string(from: date)
        default:
            let fmt = DateFormatter()
            fmt.timeZone = .easternTime
            fmt.locale = Locale(identifier: "en_US")
            fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
    }
}
