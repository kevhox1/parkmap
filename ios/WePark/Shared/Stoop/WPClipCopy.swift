//
//  WPClipCopy.swift
//  Shared/Stoop
//
//  Stoop Phase 5b (round-2 B11 App Clip, B13 notifications): the wording the mocks changed,
//  kept pure so tests pin it. Used only behind `StoopFlag.designSystemV2Enabled`; the shipping
//  copy stays in `ClipCopy`. Voice rules carry over: no "ping", "claim", "token", "hurry";
//  never a location; the exclamation mark is retired in round 2 ("Thanks, neighbor.").
//
//  Privacy (docs/design-kit/BRIEF.md): the driver is told, in words, that the neighbor will not see
//  who they are OR where they are. The mock's second sentence only covered "who"; the line here
//  adds "or where you are" so the promise matches the brief.
//

import Foundation

nonisolated enum WPClipCopy {

    // MARK: B11.2 first screen

    static func headline(name: String?) -> String { "\(name ?? "A neighbor") is waiting for your spot" }
    static let subline = "Leaving soon? Tell them when. They get a heads-up as you pull out."
    static let privacyTitle = "No sign-up. Two taps."
    static let privacyBody = "They won't see who you are or where you are. You won't see where they are."
    static let leavingSoon = "I'm leaving soon"
    static let notLeaving = "I'm not leaving"
    static let appClipPill = "App Clip"
    static let back = "Back"

    // MARK: B11.3 reminder permission

    static let reminderHeadline = "One reminder, when it's time"
    static let reminderSub = "It has a Leaving now button, so you can answer from the lock screen."
    static let reminderOnly = "That's the only notification you'll get."
    static let allowReminder = "Allow one reminder"
    static let skip = "Skip"

    /// B13 driver reminder title ("Still leaving around 4:45?"). The notification and the B11.3 preview share it.
    static func reminderTitle(around: String) -> String { "Still leaving around \(around)?" }

    // MARK: B11.4 time

    static let timeTitle = "When are you leaving?"
    static let pickTime = "Pick a time"

    static func chipTitle(_ choice: LeaveChoice) -> String {
        switch choice {
        case .now: return "Now"
        case .minutes(let m): return m == 60 ? "About 1 hour" : "About \(m) min"
        case .custom: return pickTime
        }
    }

    static func tell(name: String?) -> String { "Tell \(name ?? "your neighbor")" }

    // MARK: B11.5 armed

    static let armedHeadline = "You're on, neighbor."

    static func armedSub(name: String, around: String?) -> String {
        if let around { return "We'll tell \(name) when you leave, around \(around)." }
        return "We'll tell \(name) when you leave."
    }

    static let lockTitle = "Look at your lock screen"
    static let lockBody = "Tap Leaving now there. No need to unlock."
    static let leavingNow = "Leaving now"
    static let notLeavingAfterAll = "Not leaving after all"

    // MARK: B11.7 countdown

    static let almostTime = "Almost time"
    static let timeToGo = "Time to go?"
    static let leavingIn = "Leaving in"
    static func isWaiting(name: String) -> String { "\(name) is waiting" }
    static let fiveMore = "5 more min"
    static let notLeavingShort = "Not leaving"
    static let safety = "Tap Leaving now right before you go. Don't use your phone while driving."
    static func headsUpSent(name: String) -> String { "\(name) knows you're pulling out. Drive safe." }
    static let headsUpTitle = "Heads-up sent"

    // MARK: B11.8 / B11.9 finished

    static let thanksTitle = "Thanks, neighbor."
    static func thanksSub(name: String) -> String { "\(name) says thanks for the spot." }
    static let passedTitle = "You passed a spot."
    static let passedSub = "A neighbor is pulling in because of you."
    static let stamp = "Spot passed"
    static let karmaPending = "+5 karma lands when they say thanks."
    static let keepKarmaTitle = "Next time, keep the karma"
    static let keepKarmaBody = "The app shows every curb you can park on and reminds you before street cleaning."
    static let appName = "WePark"
    static let appTagline = "NYC street parking"
    static let get = "Get"
    static let done = "Done"

    // MARK: Block card (existing on-demand lookup, restyled)

    static let curbRules = "This curb's rules"
}

// MARK: - Clock text for the reminder title

nonisolated enum WPClipClock {

    /// "4:45" on a 12-hour locale (the mock drops AM/PM in the notification title), "16:45" otherwise.
    static func bare(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let uses12h = (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "").contains("a")
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = uses12h ? "h:mm" : "HH:mm"
        return formatter.string(from: date)
    }
}
