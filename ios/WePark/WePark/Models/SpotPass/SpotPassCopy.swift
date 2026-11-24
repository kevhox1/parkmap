//
//  SpotPassCopy.swift
//  Models/SpotPass
//
//  Spot Pass C1: every seeker-facing string in one place (`docs/design/spot-pass-design.md` §2.3,
//  §7.3, §7.4, §9, §10). Voice: a good neighbor on a stoop. Rules enforced by `SpotPassCopyTests`:
//  no "ping" (internal jargon), none of the banned urgency words, at most one exclamation point
//  per string and only on the thanks lines, no clock times.
//

import Foundation

nonisolated enum SpotPassCopy {

    // MARK: More sheet row (design §9.1)

    static let rowTitle = "Spot Pass"
    static let rowSubtitle = "Ask a neighbor for their spot"

    // MARK: Badge (design §2.3, §9.3)

    static let signLine1 = "Leaving soon?"
    static let signLine2 = "Scan to pass me your spot."
    static let armedHeadline = "A neighbor's on it."
    static let armedFallbackLine = "Leaving soon."
    static let courtesyLine = "It's a courtesy, not a promise."
    static let stopWaiting = "Stop waiting"
    static let nightTip = "Too bright? Tap the sun."
    static let notificationsOffBanner = "Notifications are off. Keep this screen open to see when a neighbor scans."

    // MARK: Explainer (design §9.2)

    static let explainerTitle = "Pass the spot."
    static let explainerSteps = [
        "Show your pass to someone walking to their car.",
        "They scan it with their camera. No app needed.",
        "You get a heads-up the moment they pull out."
    ]
    static let explainerPosture = "Hold it up to your window. Please set it up while parked."
    static let showFirstName = "Show my first name"
    static let showFirstNameOff = "Off: neighbors see \"Bodega Cat\"."
    static let showFirstNameOn = "On: they see \"Maya\". Never your last name."
    static let showFirstNameDisabled = "Add a first name in Settings to turn this on."
    static let createButton = "Create my Spot Pass"

    // MARK: Notification rationale (design §8.3; "heads-up", never "ping")

    static let rationaleTitle = "Get a heads-up."
    static let rationaleBody = "We'll let you know the moment your neighbor is pulling out, even if your screen is locked."
    static let rationaleAllow = "Allow notifications"
    static let rationaleNotNow = "Not now"

    // MARK: Create states (design §9.5)

    static let creating = "Making your Spot Pass..."
    static let offline = "Can't make a pass without a connection."
    static let createFailed = "Couldn't make your Spot Pass right now."
    static let tryAgain = "Try again"

    // MARK: Departed + outcome (design §9.4, §7.3, §7.4)

    static let departedTitle = "Spot opening up."
    static let departedSubtitle = "Your neighbor is pulling out now."
    static let departedSafety = "It's a courtesy, not a promise. Stay alert when you head over."
    static let gotIt = "Got it, thanks!"
    static let didntWorkOut = "Didn't work out"
    static let outcomeSubmitFailed = "Couldn't send that. Try again."

    static let thanksTitle = "Thanks, neighbor."
    static let thanksSubtitle = "You just made someone's day easier too."
    static let noLuckTitle = "No worries. Thanks for trying."
    static let keepLooking = "Keep looking"
    static let done = "Done"

    // MARK: Ended (design §2.5, §9.5)

    static let passEnded = "Pass ended."
    static let passPaused = "This Spot Pass has been paused."
    static let makeNewPass = "Make a new pass"
    static let parkedToast = "You parked. Spot Pass is off."

    // MARK: Karma receipt (design §7.3, §7.4, §10.4)

    /// "+3 karma". Only ever shown with a server-confirmed amount.
    static func karmaReceipt(_ amount: Int) -> String { "+\(amount) karma" }
    static func noLuckKarmaReceipt(_ amount: Int) -> String { "+\(amount) karma \u{00B7} for letting us know" }
}
