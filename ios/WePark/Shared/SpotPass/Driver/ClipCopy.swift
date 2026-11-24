//
//  ClipCopy.swift
//  Shared/SpotPass/Driver
//
//  Every user-facing string of the clip, Live Activity and reminder in one place
//  (design sections 3.3, 3.4, 3.5, 3.8, 5.1c, 6, 7, 8.1, 10.1). Voice rules: no "ping", "claim",
//  "token", "free spot", "hurry"; at most one exclamation mark, only on thanks; never a location.
//

import Foundation

nonisolated enum ClipCopy {

    // MARK: First screen

    static func headline(name: String?) -> String {
        "\(name ?? "A neighbor") is waiting for your spot."
    }
    static let subline = "Leaving soon? Tell them when, with one tap. They'll only know you're pulling out, never who you are or where you are."
    static let chipsLabel = "When are you leaving?"
    static let consent = "A neighbor will be told when you pull out. That's all they will know."
    static let underCTA = "One tap. That's all they'll know."
    static let notLeavingSoon = "Not leaving soon"
    static let dismissedLine = "No worries. Thanks for looking."
    static let pickTimeTitle = "Pick a time"
    static let pickTimeHelper = "Up to 4 hours from now."
    static let pickTimeSet = "Set time"

    static func chipTitle(_ choice: LeaveChoice) -> String {
        switch choice {
        case .now: return "Now"
        case .minutes(let m): return m == 60 ? "1 hr" : "\(m) min"
        case .custom: return "Pick a time"
        }
    }

    static func chipAccessibilityLabel(_ choice: LeaveChoice) -> String {
        switch choice {
        case .now: return "Leaving now"
        case .minutes(let m): return m == 60 ? "Leaving in 1 hour" : "Leaving in \(m) minutes"
        case .custom: return "Pick a time"
        }
    }

    static func cta(choice: LeaveChoice, name: String?) -> String {
        let who = name ?? "your neighbor"
        return choice.isNow ? "Tell \(who) I'm on my way" : "Tell \(who) when I leave"
    }

    // MARK: Armed

    static let armedHeadline = "You're on, neighbor."
    static func armedSub(name: String, reminderTime: String?) -> String {
        if let reminderTime { return "We'll tell \(name) when you leave. Reminder at \(reminderTime)." }
        return "We'll tell \(name) when you leave."
    }
    static let lockScreenTitle = "Look at your lock screen"
    static let lockScreenBody = "Your countdown is there, with a Leaving now button for when you pull out."
    static let tapWhenOut = "Tap it when you pull out."
    static let activitiesOffTitle = "Lock-screen countdown is off"
    static let activitiesOffBody = "We'll remind you with a notification instead."
    static let activitiesOff = "\(activitiesOffTitle). \(activitiesOffBody)"
    static let settingsLink = "Settings"
    static let remindersOff = "Reminders are off. Your lock-screen countdown still works."
    static let bothOff = "Keep this screen handy. Tap \"I'm pulling out\" when you go."
    static let oneNeighborNote = "You can only help one neighbor at a time. Finish or cancel this pass first."
    static let notLeavingAfterAll = "Not leaving after all"
    static let cancelMyPass = "Cancel my pass"
    static let keepIt = "Keep it"
    static let cancelledLine = "Pass cancelled."
    static let finishedTitle = "Thanks for passing it on."
    static let finishedBody = "That helped a neighbor find a spot."

    // MARK: Pulling out

    static let timeToGo = "Time to go?"
    static let pullingOut = "I'm pulling out"
    static let pullingOutSafety = "Tap right before you go. Please don't use your phone while driving."
    static let fiveMore = "5 more min"
    static let notLeaving = "Not leaving"
    static func sentLine(name: String) -> String { "Sent. \(name) knows you're pulling out. Drive safe." }
    static let sendFailed = "Couldn't send. Try again."
    static let extendDone = "Done. +5 minutes."
    static let extendFailed = "Can't add more time."
    static let cancelFailed = "Couldn't cancel. Try again."
    static let passEnded = "This pass has ended. Thanks for being ready, neighbor."

    // MARK: Celebration / thanks

    static let passedHeadline = "You just passed a spot."
    static let passedSub = "A neighbor is pulling in because of you."
    static let karmaPending = "+5 karma"
    static let karmaPendingCaption = "lands when they say thanks"
    static let karmaSettled = "+5 karma"
    static let thanksHeadline = "Thanks, neighbor!"
    static func thanksSub(name: String) -> String { "\(name) got your spot." }
    static let done = "Done"

    // MARK: Install card

    static let installHeadline = "Keep your karma."
    static let installBody = "Get WePark to hold on to the good you just did, and to hear when a spot opens near you."
    static let installSecondary = "Next time, leave from your lock screen in one tap."
    static let installButton = "Get WePark"
    static let installNotNow = "Not now"

    // MARK: Terminal / error screens

    static let unavailableTitle = "This Spot Pass isn't active anymore."
    static let unavailableBody = "It may have been used or timed out. Thanks for stopping to look, neighbor."
    static let whatsWePark = "What's WePark?"
    static let offlineTitle = "Can't reach WePark right now."
    static let offlineBody = "Check your connection and try again."
    static let busyTitle = "Hang on a moment."
    static let busyBody = "Lots of people are looking. Try again in a minute."
    static let tryAgain = "Try again"
    static let disabledTitle = "Spot Pass isn't live yet."
    static let disabledBody = "Thanks for scanning, neighbor. Check back soon."
    static let openAppTitle = "Open the WePark app to finish."
    static let openAppBody = "We couldn't finish setting this up here. Get WePark and scan again."
    static let saveFailedTitle = "We couldn't save this on your phone."
    static let saveFailedBody = "Nothing was set up. Get WePark and scan again."
    static let landingTitle = "Pass the spot"
    static let landingBody = "Looking for a spot? Open WePark and tap Spot Pass."

    // MARK: Report

    static let reportTitle = "Report this pass"
    static let reportReasons: [(HandoffReportReason, String)] = [
        (.harassment, "Harassment"), (.spam, "Spam"), (.unsafe, "Unsafe"), (.other, "Something else")
    ]
    static let reportThanks = "Thanks. We'll take a look."

    // MARK: Block card (design 3.5)

    static let blockTeaserTitle = "Curious about this block?"
    static let blockTeaserSub = "See what WePark knows about the street you're on."
    static let blockShowMe = "Show me"
    static let blockFootnote = "Uses your location once. Only a rough area is looked up, and nothing is saved."
    static let blockTitle = "This block"
    static let blockNearestCurb = "Nearest curb."
    static let blockSideLine = "Street cleaning on this side"
    static let blockWrongSide = "Wrong side? Switch"
    static let blockCheckSigns = "Always check the posted signs."
    static let blockForwardLink = "Next time you park here, WePark tells you this before you walk away."
    static let blockHappeningNow = "Street cleaning is happening on this side right now."
    static let blockNoRule = "We don't have a street-cleaning rule for this block yet."
    static let blockDenied = "No problem. You can look up any block in the full app."
    static let blockFailed = "Couldn't load this block."

    // MARK: Reminders (design section 6)

    static func reminderBody(name: String) -> String { "\(name) is waiting for your spot." }
    static let reminderHiddenBody = "A neighbor is waiting for your spot."
    static let lastCallTitle = "Still leaving?"
    static func lastCallBody(name: String) -> String { "\(name)'s pass wraps up in 5 minutes." }
    static let actionLeavingNow = "Leaving now"
    static let actionFiveMore = "5 more min"
    static let actionNotLeaving = "Not leaving"

    // MARK: Live Activity

    static func activityCaption(name: String) -> String { "\(name) is waiting" }
    /// C4 (design 5.4): the lock-screen caption while the armed-window auto-detect is running. Full app only.
    static let autoDetectCaption = "auto heads-up on"
    static let activityPassed = "You passed a spot."
    static let activityEnded = "This pass has ended. Thanks for being ready, neighbor."
    static let activityLeavingNow = "Leaving now"

    // MARK: Time formatting (the driver sees real clock times; the seeker never does)

    static func clockTime(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
