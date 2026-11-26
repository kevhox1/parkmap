//
//  WPDriveLogic.swift
//  WePark
//
//  Phase 3 (design system v0.1: Drive mode, round-2 B5). Pure, unit-testable logic behind the
//  flag-on drive screens. Nothing here reads UI state or re-derives the left/right split:
//  `DrivingContextService` already resolves which curb is on the driver's left and right from the
//  direction of travel (`DriveSideAssignment`) and hands us one `SafetyLabel` plus an optional
//  goal-aware color verdict per side. This file only turns those into one glanceable verdict.
//
//  Product rules (Kevin's, non-negotiable; DECISIONS.md accuracy adjustments):
//    - Never show a spot that isn't a spot. A side is `park` only when the goal-aware verdict
//      says it passes the SAME green gate the map uses (`WPCurbVerdict.isParkable`, wired in
//      `DrivingContextService.goalAwareChip` while the flag is on) AND the label is a free label.
//      Unclear, no-data and unknown sides are NEVER `park`. A meter follows the map's gate too:
//      running in the window = not free; outside the window = free, exactly as the map draws it.
//    - Left and right are always spelled out in words, never an icon alone (A3).
//    - Unsure is drawn as don't: the only non-park, non-restriction looks are `nodata`
//      ("No sign data" / "Unclear sign"), `meter`, and the transient `checking`.
//    - Times come from the engine's label text; "12:00 AM" is written "midnight".
//

import Foundation
import SwiftUI

// MARK: - Side verdict

/// Which block to draw for one side of the street.
enum WPDriveKind: Equatable, CaseIterable {
    /// Free for the whole selected window: the only green.
    case park
    /// Legal right now, but not green (no goal window to judge it by).
    case soon
    case dont
    case meter
    /// No sign data, or an unclear sign.
    case nodata
    /// No driving context yet ("Checking / One moment").
    case checking

    /// Only `park` is green. Everything else reads as "do not rely on this curb".
    nonisolated var isParkable: Bool { self == .park }
}

/// One side's glanceable verdict. `name` is "Left side" or "Right side": always words.
struct WPDriveSide: Equatable {
    let kind: WPDriveKind
    let isLeft: Bool
    /// The one-glance answer ("Park", "No parking", "Metered", "No sign data", "Checking").
    let big: String
    /// One short line, or nil.
    let sub: String?

    nonisolated var name: String { isLeft ? "Left side" : "Right side" }

    /// VoiceOver reads the whole card as one sentence.
    nonisolated var spoken: String {
        [name, big, sub].compactMap { $0 }
            .map { $0.hasSuffix(".") ? $0 : $0 + "." }
            .joined(separator: " ")
    }

    /// "Right side: no parking." (the plain-words line the arrival prompt uses for a side that is
    /// not offered.)
    nonisolated var plainLine: String {
        var line = "\(name): \(big.lowercased())."
        if let sub, !sub.isEmpty { line += " " + (sub.hasSuffix(".") ? sub : sub + ".") }
        return line
    }
}

enum WPDriveVerdict {

    /// "Not free through your window": the label `DrivingContextService.goalAwareChip` writes when
    /// a side is free now but the selected window runs into a restriction.
    nonisolated static let notThroughWindow = "Not free through your window"

    /// Sentinel the engine uses for "no label".
    nonisolated static let emptyLabel = "\u{2014}"

    // MARK: Side

    /// Maps one side's label and goal verdict to the block.
    /// - Parameters:
    ///   - override: `DrivingContext.leftChipColorOverride` / `rightChipColorOverride`:
    ///     `.free` iff the side passes the map's green gate for the window, `.restricted` iff not,
    ///     nil when no goal window is set.
    nonisolated static func side(
        isLeft: Bool, label: SafetyLabel, override: SafetyLabel.Severity?
    ) -> WPDriveSide {
        func make(_ kind: WPDriveKind, _ big: String, _ sub: String? = nil) -> WPDriveSide {
            WPDriveSide(kind: kind, isLeft: isLeft, big: big, sub: sub)
        }
        let text = label.text.trimmingCharacters(in: .whitespaces)

        // Unreadable first: never park, whatever the goal verdict says.
        if text == NoSignData.headline {
            return make(.nodata, "No sign data", "Read the posted signs")
        }
        if text == UnclearSign.headline || text == UnclearSign.upcomingLabel {
            return make(.nodata, "Unclear sign", "Check the posted sign")
        }
        if label.severity == .unknown || text.isEmpty || text == emptyLabel {
            return make(.nodata, "No sign data", "Read the posted signs")
        }
        // Meters follow the map exactly: a meter running in the window is not free (the goal
        // verdict is `.restricted` or absent), a meter whose hours fall outside the window is
        // legally free and the map draws it green, so the card says park too.
        if label.severity == .metered {
            if override == .free {
                return make(.park, "Park", "No meter running in your window")
            }
            return make(.meter, "Metered", "Pay the meter. Check the signs.")
        }
        if label.severity == .restricted {
            if text == notThroughWindow {
                return make(.dont, "Not free", "Free now, but not through your window")
            }
            return make(.dont, "No parking")
        }

        // Free-looking label (.free / .comingSoon). The text must really be a free label; any
        // other wording on a "free" severity is unexpected, so it is never drawn as park.
        guard text.hasPrefix("Free") else {
            return make(.nodata, "Unclear sign", "Check the posted sign")
        }
        switch override {
        case .free:
            return make(.park, "Park", freeLine(text))
        case .restricted:
            // The window fails even though the label reads free now.
            return make(.dont, "Not free", "Free now, but not through your window")
        default:
            // No goal window to judge by: legal now is not green.
            return make(.soon, "Free now", freeLine(text))
        }
    }

    /// "Free until Mon 9 AM" from the engine's label (midnight spelled out, non-breaking AM/PM).
    /// A label that is not a "Free until ..." time reads "Check the signs".
    nonisolated static func freeLine(_ text: String) -> String {
        guard text.hasPrefix("Free until") else { return "Check the signs" }
        return WPCurbCopy.midnightized(ParkingGoals.nonBreakingMeridiem(text))
    }

    /// Both sides for a context. nil context (no street matched yet) is "Checking" on both sides.
    nonisolated static func sides(for context: DrivingContext?) -> (left: WPDriveSide, right: WPDriveSide) {
        guard let context else {
            let checking = { (isLeft: Bool) in
                WPDriveSide(kind: .checking, isLeft: isLeft, big: "Checking", sub: "One moment")
            }
            return (checking(true), checking(false))
        }
        return (
            side(isLeft: true, label: context.leftLabel, override: context.leftChipColorOverride),
            side(isLeft: false, label: context.rightLabel, override: context.rightChipColorOverride)
        )
    }

    // MARK: Compact (accessibility sizes)

    /// The largest Dynamic Type size the drive overlay renders at. Everything above it draws at
    /// this size: a driver at AX3 to AX5 still gets accessibility-sized, never-truncated text, but
    /// both sides' verdicts, the street and the actions must fit one screen together (a glance
    /// while driving cannot scroll). Short phones (SE class, under 700 pt) cap one step lower.
    /// VoiceOver is unaffected.
    nonisolated static func maxDriveTypeSize(screenHeight: CGFloat) -> DynamicTypeSize {
        screenHeight < 700 ? .accessibility1 : .accessibility2
    }

    /// One line for a side at accessibility sizes. Secondary text is dropped: "Park until Mon 9:00 AM"
    /// for a green side whose label is a "Free until ..." time, otherwise the verdict word alone.
    nonisolated static func compactLine(for side: WPDriveSide) -> String {
        guard side.kind == .park, let sub = side.sub else { return side.big }
        if sub.hasPrefix("Free until ") { return "Park until " + sub.dropFirst("Free until ".count) }
        // A green metered side keeps its caveat. "meter not running" (not "no meter") so it never
        // reads as "this street has no meter": the meter exists, it just is not running in the
        // driver's window (green is only drawn when the goal window clears the meter hours).
        if sub.hasPrefix("No meter running") { return "Park \u{00B7} meter not running" }
        return side.big
    }

    // MARK: Primary action

    enum Primary: Equatable {
        /// Yellow raised "Park here": a side is green for the window.
        case park
        /// White flat "Park here anyway": nothing is green.
        case anyway
        /// White flat "Park here": still checking.
        case checking

        nonisolated var title: String {
            switch self {
            case .park, .checking: return "Park here"
            case .anyway: return "Park here anyway"
            }
        }

        /// Only a green side earns the raised yellow button.
        nonisolated var isRaised: Bool { self == .park }
    }

    nonisolated static func primary(left: WPDriveSide, right: WPDriveSide) -> Primary {
        if left.kind == .checking || right.kind == .checking { return .checking }
        return (left.kind.isParkable || right.kind.isParkable) ? .park : .anyway
    }

    // MARK: Layout weight

    /// Width share of a side card while both sit side by side: a green side gets the larger card
    /// (mock B5.2 to B5.4). 0.5 each when both or neither are green.
    nonisolated static func widthShare(of side: WPDriveSide, other: WPDriveSide) -> Double {
        if side.kind.isParkable == other.kind.isParkable { return 0.5 }
        return side.kind.isParkable ? 0.58 : 0.42
    }

    // MARK: Street and destination

    /// "E 1st St" from the tile's upper-case street name.
    nonisolated static func streetTitle(_ raw: String) -> String {
        StreetNameFormatter.displayCanonical(raw)
    }

    /// Final-approach window: closer than this reads "Destination in 400 ft".
    nonisolated static let nearMeters: Double = 161

    /// "1.2 mi to destination" far out, "Destination in 400 ft" when close or approaching.
    nonisolated static func destinationLine(meters: Double, approaching: Bool, metric: Bool) -> String {
        let near = approaching || meters < nearMeters
        let amount = distanceText(meters: meters, metric: metric)
        return near ? "Destination in \(amount)" : "\(amount) to destination"
    }

    nonisolated static func distanceText(meters: Double, metric: Bool) -> String {
        let m = max(0, meters)
        if metric {
            if m < 1000 { return "\(max(10, Int((m / 10).rounded()) * 10)) m" }
            return String(format: "%.1f km", m / 1000)
        }
        let feet = m * 3.28084
        if feet < 528 { return "\(max(50, Int((feet / 50).rounded()) * 50)) ft" }
        return String(format: "%.1f mi", m / 1609.344)
    }

    // MARK: Voice

    nonisolated static func voiceTitle(muted: Bool) -> String { muted ? "Voice off" : "Voice on" }
}
