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
    ///   `.metered`    → "Metered"
    ///   `.restricted` → "No parking"
    ///   `.unknown`    → "—"
    init(for opportunity: SideOpportunity) {
        switch opportunity {
        case .free:
            self.init(text: "Free — check signs", severity: .free)
        case .metered:
            self.init(text: "Metered", severity: .metered)
        case .restricted:
            self.init(text: "No parking", severity: .restricted)
        case .unknown:
            self.init(text: "—", severity: .unknown)
        }
    }
}
