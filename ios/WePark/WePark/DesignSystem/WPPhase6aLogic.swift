//
//  WPPhase6aLogic.swift
//  WePark
//
//  Stoop Phase 6a (B1 onboarding + coach marks, B15 More / Settings): the pure copy and decision
//  logic behind the round-2 screens. Used only while `AppConstants.designSystemV2Enabled` is true.
//  Nothing here touches UserDefaults, permissions or scheduling: the existing gates
//  (`OnboardingStoryGate`, `OnboardingCoachGate`, `LocationPrimingCardGate`), the story / coach
//  sequencing (`OnboardingStoryModel.swift`, `OnboardingCoachModel.swift`) and the reminder
//  scheduler stay exactly as they are. This file only supplies the round-2 words and summaries.
//
//  Every member is `nonisolated` (the target defaults to MainActor isolation) so sync XCTests can
//  call them.
//

import Foundation
import UserNotifications

// MARK: - Story deck copy (B1.1 to B1.3)

extension OnboardingStoryCard {

    /// "1 of 3" over the headline.
    nonisolated var v2Progress: String { "\(cardNumber) of \(OnboardingStoryCard.allCases.count)" }

    nonisolated var v2Title: String {
        switch self {
        case .problem: return "See where you can park before you circle the block"
        case .ask: return "Free always comes with an end time"
        case .payoff: return "Say how long you\u{2019}re staying"
        }
    }

    nonisolated var v2Sub: String {
        switch self {
        case .problem: return "WePark reads the parking signs on every curb, so you don\u{2019}t have to."
        case .ask: return "Tap any curb to see how long you can stay and which sign says so."
        case .payoff: return "The map turns green only where you can stay that long."
        }
    }

    /// Cards 1 and 2 are "Continue"; the last card finishes the deck and lands on the map, so it
    /// keeps the existing "Let's go" wording (the mock's third "Continue" leads to a location
    /// screen that, here, is the floating priming card the map flow already shows).
    nonisolated var v2PrimaryLabel: String { continueLabel }
}

/// The illustrative end-time card on story card 2 (B1.2). It is a sample, not a real curb, and is
/// labelled as one, because WePark never shows a fake spot as a real one.
enum WPStoryExample {
    nonisolated static let label = "Example"
    nonisolated static let factLead = "Free to stay until"
    nonisolated static let factTime = "Mon 9:00 AM"
    nonisolated static let factNext = "Then street cleaning, 9 to 10:30 AM"
    nonisolated static let remindTitle = "We remind you before it changes"
    nonisolated static let remindBody = "You pick how long before, in Settings."
    nonisolated static let longerStayTitle = "A longer stay means fewer green curbs"
    nonisolated static let longerStayBody = "Because more rules get in the way."

    /// The three goal chips on story card 3. "For days" never claims a fixed week: the real window
    /// is adaptive (DECISIONS: the 8, 4, 2 day ladder).
    nonisolated static let goalChips: [(title: String, sub: String)] = [
        ("A few hours", "3 hours"),
        ("Overnight", "until morning"),
        ("For days", "several days"),
    ]
    nonisolated static let selectedChipIndex = 1
}

/// Two-state map teaching on story card 1 (B1.1): the only thing onboarding teaches about colors.
enum WPStoryLines {
    nonisolated static let parkTitle = "Park"
    nonisolated static let parkSub = "A solid green curb"
    nonisolated static let dontTitle = "Don\u{2019}t"
    nonisolated static let dontSub = "A dashed coral curb"
}

// MARK: - Location priming copy (B1.4)

enum WPLocationPrimingCopy {
    nonisolated static let title = "Let WePark see where you are"
    nonisolated static let sub = "iOS will ask next. Choose Allow While Using App."
    nonisolated static let allow = "Allow location"
    nonisolated static let notNow = "Not now"
    nonisolated static let skip = "Skip"
    nonisolated static let facts = [
        "Shows the curbs around you",
        "Tells you which side of the street to park on",
        "Remembers where you left the car",
    ]
}

// MARK: - Coach mark copy (B1.6 to B1.8)

extension OnboardingCoachMark {

    /// "1 of 3".
    nonisolated var v2Progress: String { "\(rawValue + 1) of \(OnboardingCoachMark.allCases.count)" }

    /// Round-2 headline. Mark 1 teaches the goal window, mark 2 the two-state map, mark 3
    /// drag-to-park. At accessibility sizes the resting car token is hidden (the goal sheet fills
    /// the screen) and the goal tiles collapse to one card, so marks 1 and 3 name what is there.
    nonisolated func v2Title(accessibilityLayout: Bool) -> String {
        switch self {
        case .goalTiles:
            return accessibilityLayout ? "Tap the goal card to pick how long you\u{2019}re staying"
                                       : "Pick how long you\u{2019}re staying"
        case .colorMeaning:
            return "Solid green: park. Dashed coral: don\u{2019}t."
        case .tapABlock:
            return accessibilityLayout ? "Tap a green curb, then Park here" : "Drag the car to park"
        }
    }

    nonisolated func v2Message(accessibilityLayout: Bool) -> String {
        switch self {
        case .goalTiles:
            return "Overnight means from now until the morning."
        case .colorMeaning:
            return "Tap any curb for its end time and its signs."
        case .tapABlock:
            return accessibilityLayout
                ? "WePark saves where you parked and can remind you before it changes."
                : "Hold the car and drag it to a green curb."
        }
    }

    nonisolated var v2NextLabel: String {
        switch self {
        case .goalTiles, .colorMeaning: return "Next"
        case .tapABlock: return "Got it"
        }
    }

    /// Round-2 real-control rule. Only the goal tiles advance mark 1 (mark 2 is about the curbs, so
    /// picking a goal must not skip it). A curb tap advances mark 2 (see `v2DismissedByCurbTap`).
    nonisolated var v2DismissedByGoalTileTap: Bool { self == .goalTiles }
    nonisolated var v2DismissedByCurbTap: Bool { self == .colorMeaning }
}

// MARK: - Settings

enum WPSettingsLogic {

    // MARK: Reminder option set (DECISIONS #8: the same set as My Car)

    /// The lead-time options, in the order My Car shows them. Labels match My Car's chips.
    nonisolated enum LeadOption: CaseIterable, Equatable {
        case min15, min30, hour1, hours2

        nonisolated var chipTitle: String {
            switch self {
            case .min15: return "15 min"
            case .min30: return "30 min"
            case .hour1: return "1 hr"
            case .hours2: return "2 hr"
            }
        }

        nonisolated var summaryTitle: String {
            switch self {
            case .min15: return "15 min"
            case .min30: return "30 min"
            case .hour1: return "1 hour"
            case .hours2: return "2 hours"
            }
        }

        nonisolated func isOn(in offsets: ReminderOffsets) -> Bool {
            switch self {
            case .min15: return offsets.remind15Min
            case .min30: return offsets.remind30Min
            case .hour1: return offsets.remind1Hour
            case .hours2: return offsets.remind2Hours
            }
        }

        nonisolated func toggled(in offsets: ReminderOffsets) -> ReminderOffsets {
            var copy = offsets
            switch self {
            case .min15: copy.remind15Min.toggle()
            case .min30: copy.remind30Min.toggle()
            case .hour1: copy.remind1Hour.toggle()
            case .hours2: copy.remind2Hours.toggle()
            }
            return copy
        }
    }

    /// "1 hour before", "15 min, 1 hour before", "1 hour before and the night before", "Off".
    /// `muted` is the global "park reminders" switch; when it is on nothing fires.
    nonisolated static func reminderSummary(offsets: ReminderOffsets, muted: Bool) -> String {
        if muted { return "Off" }
        let leads = LeadOption.allCases.filter { $0.isOn(in: offsets) }.map(\.summaryTitle)
        switch (leads.isEmpty, offsets.remindNightBefore) {
        case (true, false): return "None picked"
        case (true, true): return "The night before"
        case (false, false): return leads.joined(separator: ", ") + " before"
        case (false, true): return leads.joined(separator: ", ") + " before and the night before"
        }
    }

    /// "8:00 PM" for a 24h hour; callers pass `AppConstants.nightBeforeHourET` (the scheduler's fixed night-before hour).
    nonisolated static func nightBeforeTimeLabel(hour: Int) -> String {
        let clamped = min(max(hour, 0), 23)
        let suffix = clamped >= 12 ? "PM" : "AM"
        let twelve = clamped % 12 == 0 ? 12 : clamped % 12
        return "\(twelve):00 \(suffix)"
    }

    // MARK: Notification status (the Settings "Notifications" row)

    nonisolated static func notificationStatusLabel(_ status: UNAuthorizationStatus?) -> String {
        guard let status else { return "Checking\u{2026}" }
        switch status {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Off in iOS Settings"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Not asked yet"
        }
    }

    // MARK: Rows

    nonisolated enum Row: Equatable {
        case reminders, voice, notifications
        case regulars, suggestNeighborhood, deleteAccount
        case help, about
    }

    /// The Settings cards, top to bottom. Account deletion and "suggest a neighborhood" are
    /// dark-shipped (their existing flags are off today), so they only appear when told to. The
    /// mock's Account row (alias and karma) has no data behind it in the app today and is not
    /// drawn.
    nonisolated static func sections(
        suggestVisible: Bool,
        deleteVisible: Bool,
        regularsVisible: Bool
    ) -> [[Row]] {
        var result: [[Row]] = [[.reminders, .voice, .notifications]]
        if deleteVisible { result.append([.deleteAccount]) }
        var more: [Row] = []
        if regularsVisible { more.append(.regulars) }
        if suggestVisible { more.append(.suggestNeighborhood) }
        more.append(.help)
        more.append(.about)
        result.append(more)
        return result
    }

    // MARK: About

    nonisolated static func versionLabel(version: String, build: String) -> String {
        "\(version) (\(build))"
    }

    nonisolated static let aboutTagline = "NYC street parking. The sign on the street always wins."
}

// MARK: - Colors screen (B15.6)

enum WPColorsCopy {
    nonisolated static let mapHeader = "The map"
    nonisolated static let parkTitle = "Park"
    nonisolated static let parkSub = "free for the time you picked"
    nonisolated static let dontTitle = "Don\u{2019}t"
    nonisolated static let dontSub = "not free for that long"
    nonisolated static let detailHeader = "With \u{201C}Show all sign details\u{201D} on"
    nonisolated static let pinsHeader = "Pins from neighbors"

    /// Curb-line rows with sign details on. Order and labels follow the in-map legend card.
    nonisolated static let detailRows: [(kind: CurbLineKind, label: String)] = [
        (.park, "Free"),
        (.soon, "Changes soon"),
        (.metered, "Metered"),
        (.dont, "No parking"),
        (.noData, "No sign data"),
    ]

    /// Only pins the map really draws (see `MapKeyLegendView`: the legend never promises a marker
    /// the map does not draw). The mock also lists "No parking today", "Filming" and
    /// "Construction", which the app does not draw as markers today.
    nonisolated static let pinLabels = ["Open spot", "Leaving soon", "Street swept", "Ticketing now"]
}

// MARK: - Help (B15.7)

nonisolated struct WPHelpTopic: Equatable, Identifiable {
    let id: String
    let question: String
    let answer: String

    /// Spot Pass and karma questions only show when Spot Pass itself is live.
    nonisolated static func topics(spotPassEnabled: Bool) -> [WPHelpTopic] {
        var list: [WPHelpTopic] = [
            WPHelpTopic(
                id: "disagree",
                question: "What if the app and the sign disagree?",
                answer: "Trust the sign. WePark reads city data, which can lag behind what is posted on the street. The sign on the street always wins."
            ),
            WPHelpTopic(
                id: "source",
                question: "Where do the parking rules come from?",
                answer: "From NYC\u{2019}s public parking data: posted sign records, the alternate side parking calendar and metered parking. WePark turns them into a green or coral line for the time you picked."
            ),
            WPHelpTopic(
                id: "reminders",
                question: "How do reminders work?",
                answer: "When you park, WePark can remind you before street cleaning or a no-parking time starts on that curb. You pick how long before in Settings. Reminders are only about your own parked car."
            ),
        ]
        if spotPassEnabled {
            list.append(WPHelpTopic(
                id: "spotpass",
                question: "What is a Spot Pass?",
                answer: "A Spot Pass lets a driver who is leaving pass their curb on to a neighbor who is looking. It takes two taps."
            ))
            list.append(WPHelpTopic(
                id: "karma",
                question: "What is karma for?",
                answer: "Karma is a thank-you count for helping a neighbor park. It is just a number."
            ))
        }
        return list
    }
}

// MARK: - About

enum WPAboutSources {
    /// The official NYC sources already used by the existing Help screen (the signs are the final word).
    nonisolated static let links: [(title: String, url: String)] = [
        ("NYC alternate side parking and suspension calendar",
         "https://www.nyc.gov/html/dot/html/motorist/alternate-side-parking.shtml"),
        ("2026 ASP suspension calendar (PDF)",
         "https://www.nyc.gov/html/dot/downloads/pdf/asp-calendar-2026.pdf"),
        ("NYC parking rules and signs",
         "https://www.nyc.gov/html/dot/html/motorist/parking-regulations.shtml"),
    ]
    nonisolated static let note = "WePark is a community helper, not the city. Always confirm with the posted street signs and the official NYC sources below. The signs are the final word."
}
