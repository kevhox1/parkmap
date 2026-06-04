//
//  CruiseVoicePolicy.swift
//  WePark
//
//  CM-1: Pure-function voice cadence policy for Cruise Mode ("Find Parking").
//
//  Pattern: enum with all-static methods, no instance state, no framework imports.
//  Directly mirrors FinalApproachService.swift — same "pure static, trivially testable"
//  pattern. No AVSpeechSynthesizer, no CoreLocation, no SwiftUI — just parking context
//  in, decision out.
//
//  Design rationale (spec §4.1):
//    In Cruise Mode the driver is searching, not arriving. Announcing
//    "No parking. No parking. No parking." on consecutive avenue segments
//    is noise that erodes trust. The policy speaks only when an announcement
//    helps the driver act (at least one side is free or metered).
//
//  OQ-2 resolution: announce only when at least one side is .free or .metered.
//  All-restricted and all-unknown blocks are silent.
//
//  No Calendar.current.
//  No import SwiftUI (QA invariant — pure service).
//

import Foundation

// MARK: - CruiseVoicePolicy

/// Pure-function voice cadence policy for Cruise Mode.
///
/// All methods are static — no instance state, no side effects, no framework dependencies.
/// `DrivingContextService` calls `shouldAnnounce(context:)` from the block-change path
/// when cruise mode is active; `utteranceText(for:)` supplies the Cruise Mode phrasing.
///
/// ## Testability contract
/// `shouldAnnounce` MUST remain a pure function of `DrivingContext` ONLY.
/// Do NOT thread mute state, `UserDefaults`, or any other external dependency into this
/// function — mute gating belongs in the caller (`DrivingContextService.speakContext`).
/// This keeps the decision table exhaustively unit-testable without setup.
///
/// ## Convergence with Patrol Mode (spec §8)
/// Patrol mode (tier3-patrol-mode-buildplan.md sub-PR #2) will use Cruise Mode's voice
/// policy as its baseline. `shouldAnnounce` is designed for reuse: pass the patrol block's
/// context and it returns the same decision. Community-pin callouts ("Enforcement ahead")
/// are a patrol-mode addition layered on top — not inside this type.
enum CruiseVoicePolicy {

    // MARK: - Constants

    /// Minimum gap between voice cues in Cruise Mode (seconds).
    ///
    /// Same baseline as `FinalApproachService.baselineVoiceGapSeconds` (12.0s).
    /// Cruise Mode never enters `.approaching` or `.arrived` states, so this constant
    /// is fixed for the lifetime of the Cruise Mode session.
    /// Calibration deferred to W8.5c-follow after drive-test.
    static let minimumGapSeconds: TimeInterval = 12.0

    // MARK: - Should announce

    /// Returns `true` if the given parking context should trigger a voice announcement
    /// in Cruise Mode.
    ///
    /// Decision table (spec §4.2):
    ///
    /// | Left severity  | Right severity | Result |
    /// |----------------|----------------|--------|
    /// | `.free`        | any            | `true` |
    /// | any            | `.free`        | `true` |
    /// | `.metered`     | any            | `true` |
    /// | any            | `.metered`     | `true` |
    /// | `.restricted`  | `.restricted`  | `false`|
    /// | `.restricted`  | `.unknown`     | `false`|
    /// | `.unknown`     | `.restricted`  | `false`|
    /// | `.unknown`     | `.unknown`     | `false`|
    ///
    /// Rationale: if both sides are restricted or unknown, announcing them adds noise
    /// without value — the driver cannot park on either side regardless.
    ///
    /// - Parameter context: The current driving context.
    /// - Returns: `true` if at least one side is free or metered.
    static func shouldAnnounce(context: DrivingContext) -> Bool {
        let left = context.leftLabel.severity
        let right = context.rightLabel.severity
        return left == .free || left == .metered
            || right == .free || right == .metered
    }

    // MARK: - Utterance text

    /// Builds the voice utterance text for Cruise Mode.
    ///
    /// Cruise Mode phrasing leads with the opportunity ("Free parking on left") rather
    /// than the neutral destination-mode format ("Left side, free until..."). In Cruise
    /// Mode the driver wants to know "can I park there?" immediately — the affirmative
    /// lead is more actionable from a dashboard-mount.
    ///
    /// Full restriction text (until when) is still shown visually in `DriveModeBottomCard`
    /// chips; voice in Cruise Mode is the action cue, not the full data read-out.
    ///
    /// Phrasing rules (spec §4.2):
    ///   - Both free → "[Street]. Free parking on both sides."
    ///   - Only left free → "[Street]. Free parking on the left."
    ///   - Only right free → "[Street]. Free parking on the right."
    ///   - Neither free, left metered only → "[Street]. Metered on the left."
    ///   - Neither free, right metered only → "[Street]. Metered on the right."
    ///   - Neither free, both metered → "[Street]. Metered on both sides."
    ///   - Any other combination that passes `shouldAnnounce` → fallback to both-metered phrasing.
    ///
    /// Note: this function is only called when `shouldAnnounce(context:)` returns `true`,
    /// so callers may assert at least one side is free or metered at this point.
    ///
    /// - Parameter context: The current driving context.
    /// - Returns: The utterance text for TTS.
    static func utteranceText(for context: DrivingContext) -> String {
        let street = expandAbbreviations(titleCase(context.street))
        let leftFree  = context.leftLabel.severity == .free
        let rightFree = context.rightLabel.severity == .free
        let leftMetered  = context.leftLabel.severity == .metered
        let rightMetered = context.rightLabel.severity == .metered

        let parkingClause: String
        if leftFree && rightFree {
            parkingClause = "Free parking on both sides."
        } else if leftFree {
            parkingClause = "Free parking on the left."
        } else if rightFree {
            parkingClause = "Free parking on the right."
        } else if leftMetered && rightMetered {
            parkingClause = "Metered on both sides."
        } else if leftMetered {
            parkingClause = "Metered on the left."
        } else {
            // rightMetered (or edge case)
            parkingClause = "Metered on the right."
        }

        return "\(street). \(parkingClause)"
    }

    // MARK: - Text helpers (mirrors DrivingContextService)

    /// Converts a string to Title Case.
    private static func titleCase(_ s: String) -> String {
        s.split(separator: " ").map { word in
            let str = String(word)
            return str.prefix(1).uppercased() + str.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Expands common street abbreviations for voice clarity.
    /// Mirrors `DrivingContextService.expandAbbreviations` — kept in sync manually.
    private static func expandAbbreviations(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\bSt\\b", with: "Street", options: .regularExpression)
            .replacingOccurrences(of: "\\bAve\\b", with: "Avenue", options: .regularExpression)
            .replacingOccurrences(of: "\\bBlvd\\b", with: "Boulevard", options: .regularExpression)
            .replacingOccurrences(of: "\\bDr\\b", with: "Drive", options: .regularExpression)
            .replacingOccurrences(of: "\\bPl\\b", with: "Place", options: .regularExpression)
            .replacingOccurrences(of: "\\bRd\\b", with: "Road", options: .regularExpression)
    }
}
