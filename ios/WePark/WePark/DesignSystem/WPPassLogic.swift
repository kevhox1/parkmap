//
//  WPPassLogic.swift
//  WePark
//
//  Stoop Phase 5a (B9 Spot Pass seeker, B10 Spot Pass driver). Pure, unit-testable wording and
//  logic behind the Stoop skin of the in-app Spot Pass screens. Shown only while
//  `AppConstants.designSystemV2Enabled && AppConstants.spotHandoffEnabled`. Nothing here touches
//  Spot Pass networking, QR payloads or Live Activities: it only decides what the screens say and
//  which leave-time slots they offer.
//
//  Rules in force (DECISIONS.md round 2):
//    - "About 10 min" / "About 30 min" / "About 1 hour" replace "~10 min" (VoiceOver reads it cleanly).
//    - "Pick a time" offers every 15 minutes up to 4 hours from now, never past what the server
//      accepts (`LeaveChoice.latest`), so the time shown is the time sent.
//    - The driver's auto heads-up is an opt-in switch, off by default. Turning it ON still goes
//      through the one-time purpose screen (spec 9 item 1); only turning it OFF is immediate.
//    - Privacy: the seeker is never shown to the driver by name or place ("They won't see who you
//      are or where you are").
//

import Foundation

nonisolated enum WPPassCopy {

    /// B9.1 intro.
    static let seekerOver = "Spot Pass"
    static let seekerTitle = "Ask a driver for their spot"
    static let seekerSub = "For when you see someone walking back to their car."
    static let seekerSteps = [
        "Show them your pass. They scan it with their camera.",
        "They tell you when they're leaving.",
        "You get a heads-up the moment they pull out."
    ]
    /// The privacy promise (kept word for word from the brief and the mock).
    static let privacyTitle = "They won't see who you are or where you are."
    static let privacyBody = "They see a nickname and a code. Nothing else."
    static let makePass = "Make a pass"
    static let notNow = "Not now"

    /// B9.3 QR badge.
    static let waitingForScan = "Waiting for a scan"

    /// B9.4 / B9.5 / B9.7 / B9.9.
    static let armedTitle = "A neighbor's on it"
    static let armedNote = "We'll tell you the moment they pull out."
    static let armedNoteBody = "Stay close to the spot. Keep notifications on."
    static let departedTitle = "Go to the spot"
    static let departedBig = "Leaving now"
    static let departedNote = "Check the signs before you park"
    static let departedNoteBody = "A passed spot still follows the curb rules."

    /// B10.1 driver.
    static func driverTitle(name: String?) -> String { "\(name ?? "A neighbor") is waiting for your spot" }
    static let driverSub = "When are you leaving? They won't see who you are."
    static let notLeaving = "I'm not leaving"
    static let reportPass = "Report this pass"

    /// B10.2 pick a time.
    static let pickTitle = "Leaving around"
    static let pickSub = "Every 15 minutes, up to 4 hours from now."
    static func useTime(_ clock: String) -> String { "Use \(clock)" }

    /// B10.3 / B10.4 armed.
    static let armedDriverTitle = "You're on, neighbor."
    static let leavingNow = "Leaving now"
    static let leavingSoon = "Leaving soon"

    /// Title of the pre-tap pull-out screen. It must match what the box under it says: while the
    /// countdown still has time on it, "Leaving soon"; once the time has come (or the driver
    /// chose "Now"), "Leaving now".
    static func pullTitle(leaveAt: Date?, now: Date) -> String {
        if let leaveAt, leaveAt > now.addingTimeInterval(1) { return leavingSoon }
        return leavingNow
    }
    static let autoRowTitle = "Send it when I drive off"
    static let notLeavingAfterAll = "Not leaving after all"

    // MARK: Leave-time chips

    /// "Now", "About 10 min", "About 30 min", "About 1 hour"; a picked time shows its clock time
    /// (`clock`), and "Pick a time" otherwise.
    static func chipTitle(_ choice: LeaveChoice, clock: String? = nil) -> String {
        switch choice {
        case .now: return "Now"
        case .minutes(let m):
            if m == 60 { return "About 1 hour" }
            return "About \(m) min"
        case .custom: return clock ?? "Pick a time"
        }
    }

    /// Spoken label: "Leaving in about 10 minutes" (never "~").
    static func chipAccessibilityLabel(_ choice: LeaveChoice) -> String {
        switch choice {
        case .now: return "Leaving now"
        case .minutes(let m): return m == 60 ? "Leaving in about 1 hour" : "Leaving in about \(m) minutes"
        case .custom: return "Pick a time"
        }
    }
}

nonisolated enum WPPassLogic {

    // MARK: Pick-a-time slots

    /// The quarter-hour slots offered by "Pick a time": the first quarter hour strictly after `now`,
    /// then every 15 minutes, up to 4 hours from now, but never past `LeaveChoice.latest(from:)`
    /// (what the server accepts, minus a 60 s clock-skew guard). At most 16 slots.
    static func leaveSlots(from now: Date) -> [Date] {
        let step: TimeInterval = 15 * 60
        let first = (now.timeIntervalSince1970 / step).rounded(.down) * step + step
        let horizon = min(
            now.addingTimeInterval(Double(LeaveChoice.maxHorizonMinutes) * 60),
            LeaveChoice.latest(from: now)
        )
        var out: [Date] = []
        var t = first
        while t <= horizon.timeIntervalSince1970 {
            out.append(Date(timeIntervalSince1970: t))
            t += step
        }
        return out
    }

    /// `choice` only while it is still one of the offered `slots`. A slot the clock has passed (the
    /// sheet sat open) is no longer chosen, so "Use 4:15 AM" can never send a clamped, different time.
    static func stillOffered(_ choice: Date?, in slots: [Date]) -> Date? {
        guard let choice, slots.contains(choice) else { return nil }
        return choice
    }

    /// A chosen custom time that has passed is no longer a time in the future: sending it is clamped to
    /// now, so the screen must say "Now" instead of "around 4:15". Presets and future times are unchanged.
    static func resolvedChoice(_ choice: LeaveChoice, now: Date) -> LeaveChoice {
        if case .custom(let picked) = choice, picked <= now { return .now }
        return choice
    }

    // MARK: Auto heads-up switch

    /// What the driver's auto heads-up switch shows for each offer state. `isOn` is "the driver
    /// opted in": `.on` (watching now) and `.waiting` (opted in, window not open yet). Everything
    /// else is OFF, which is the default.
    struct AutoSwitch: Equatable {
        var isVisible: Bool
        var isOn: Bool
        var subtitle: String
    }

    static func autoSwitch(offer: AutoDetectOffer, name: String) -> AutoSwitch {
        switch offer {
        case .hidden:
            return AutoSwitch(isVisible: false, isOn: false, subtitle: "")
        case .on:
            return AutoSwitch(isVisible: true, isOn: true, subtitle: DriverCopy.autoDetectOnSub(name: name))
        case .waiting:
            return AutoSwitch(isVisible: true, isOn: true, subtitle: DriverCopy.autoDetectWaitingSub)
        case .canEnable:
            return AutoSwitch(isVisible: true, isOn: false, subtitle: DriverCopy.autoDetectOfferSub)
        case .needsSavedCar:
            return AutoSwitch(isVisible: true, isOn: false, subtitle: DriverCopy.autoDetectNeedsCarSub)
        case .locationDenied:
            return AutoSwitch(isVisible: true, isOn: false, subtitle: DriverCopy.autoDetectDeniedSub)
        }
    }

    /// Flipping the switch ON never enables by itself: it opens the purpose screen (the second
    /// explicit opt-in). Flipping it OFF turns auto heads-up off at once. Returns what to do.
    enum SwitchAction: Equatable {
        case openPurpose
        case turnOff
        case none
    }

    static func switchAction(currentlyOn: Bool, newValue: Bool) -> SwitchAction {
        if newValue == currentlyOn { return .none }
        return newValue ? .openPurpose : .turnOff
    }
}
