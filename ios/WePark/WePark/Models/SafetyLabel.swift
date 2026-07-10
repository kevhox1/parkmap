//
//  SafetyLabel.swift
//  WePark
//
//  Value type returned by ParkingRulesEngine.safetyLabel(for:at:).
//  Swift port of the { text, severity } object from actionableSafetyLabel()
//  at index.html:5457.
//
//  The `text` field is the user-facing label string. It must be byte-identical
//  to the PWA's actionableSafetyLabel output for the same inputs.
//  Examples: "Free until Thu 9:30am", "No parking", "Metered until 7pm",
//            "No standing", "No parking (truck loading)", "Free"
//
//  The `severity` field drives color selection and accessibility labels.
//

import Foundation

struct SafetyLabel: Equatable {

    /// User-facing parking status string. Byte-identical to PWA output for same inputs.
    let text: String

    /// Severity classification, used for color coding and accessibility.
    let severity: Severity

    enum Severity: String, Equatable {
        /// Block is currently usable at no cost (or a time-restricted restriction
        /// is not active right now).
        case free

        /// TF2-18 P1-2: Free right now, but the winning (displayed) restriction starts
        /// within `ParkingRulesEngine.nearFutureWindow` (6h). Distinct from `.free` so
        /// Drive Mode chips can surface the map's existing orange "restriction coming
        /// soon" tier (`CurrentState.freeButRestrictionSoon`), which previously collapsed
        /// into `.free` at the side-aggregation step. Treated as free-equivalent for voice
        /// purposes — see `CruiseVoicePolicy.shouldAnnounce`/`utteranceText` and
        /// `DrivingContextService.isFreeForVoice`/`buildUtteranceText`, all updated so this
        /// case doesn't change spoken copy (OQ-4).
        case comingSoon

        /// Block requires payment right now (METERED during paid hours).
        case metered

        /// Block is currently restricted — do not park.
        case restricted

        /// No data available for this segment.
        case unknown
    }
}

// MARK: - TF2-7: SideOpportunity → SafetyLabel bridge

extension SafetyLabel {

    /// Converts a `SideOpportunity` aggregation result to a `SafetyLabel` for downstream
    /// consumers (`DrivingContext`, `DriveModeBottomCard`, `CruiseVoicePolicy`).
    ///
    /// Placed in an extension (not the primary struct body) to preserve the compiler-synthesized
    /// memberwise `init(text:severity:)` — required by `ParkingRulesEngine` and tests.
    ///
    /// Card chip text per spec §3.2:
    ///   `.free`       → "Free — check signs" (chip width; voice has the full "sections" qualifier)
    ///   `.comingSoon` → "Free — check signs" (TF2-18 P1-2 — generic text; the detailed
    ///                   "Free until X" text is only produced by `init(for: SideAggregation)`
    ///                   below, which is what production code actually calls)
    ///   `.metered`    → "Metered"
    ///   `.restricted` → "No parking"
    ///   `.unknown`    → "—"
    ///
    /// TF2-18 override note: this switch gained a `.comingSoon` branch because
    /// `SideOpportunity` gained that case (P1-2, bundled per Kevin's approval — see PR
    /// description). TF2-17 spec AC-3 called this init "untouched"; that assumption predates
    /// the bundled TF2-18 scope, and Swift's exhaustiveness check forces this addition. The
    /// four pre-existing branches and `SafetyLabelSideOpportunityTests` (D-1..D-4) are
    /// otherwise unchanged.
    init(for opportunity: SideOpportunity) {
        switch opportunity {
        case .free:
            self.init(text: "Free — check signs", severity: .free)
        case .comingSoon:
            self.init(text: "Free — check signs", severity: .comingSoon)
        case .metered:
            self.init(text: "Metered", severity: .metered)
        case .restricted:
            self.init(text: "No parking", severity: .restricted)
        case .unknown:
            self.init(text: "—", severity: .unknown)
        }
    }
}

// MARK: - TF2-17 / TF2-18: SideAggregation → SafetyLabel bridge

extension SafetyLabel {

    /// Converts a `SideAggregation` (TF2-17 detail-preserving aggregation result) to a
    /// `SafetyLabel`. This is the init `DrivingContextService.update()` actually uses to
    /// build `DrivingContext.leftLabel` / `.rightLabel`.
    ///
    /// TF2-17 §5.2 + TF2-18 P1-2 (bundled — both changes touch this same switch):
    ///   `.free` / `.comingSoon` with `earliestFreeUntilText != nil` → that exact text,
    ///     matching severity (`.free` or `.comingSoon`).
    ///   `.free` / `.comingSoon` with `earliestFreeUntilText == nil` → "Free — check signs",
    ///     matching severity. (In practice `aggregateSideDetail` never produces
    ///     `.comingSoon` + nil text — a side only classifies `.comingSoon` when the winning
    ///     segment supplied upcoming-restriction text — but the fallback keeps this init
    ///     total and defensive.)
    ///   `.metered`    → "Metered" (unchanged from TF2-7 — OQ-2, deferred to a follow-up).
    ///   `.restricted` → "No parking" (unchanged — OQ-2, deferred).
    ///   `.unknown`    → "—" (unchanged).
    init(for aggregation: SideAggregation) {
        switch aggregation.opportunity {
        case .free:
            self.init(text: aggregation.earliestFreeUntilText ?? "Free — check signs", severity: .free)
        case .comingSoon:
            self.init(text: aggregation.earliestFreeUntilText ?? "Free — check signs", severity: .comingSoon)
        case .metered:
            self.init(text: "Metered", severity: .metered)
        case .restricted:
            self.init(text: "No parking", severity: .restricted)
        case .unknown:
            self.init(text: "—", severity: .unknown)
        }
    }
}
