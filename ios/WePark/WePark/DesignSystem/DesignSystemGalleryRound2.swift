//
//  DesignSystemGalleryRound2.swift
//  WePark
//
//  DEBUG-only gallery sections for the round-2 shared parts (docs/design/wepark-round2/README.md,
//  "Parts added in round 2"). Each section shows the part in a light panel and a dark panel side by
//  side (stacked), so one screenshot covers both appearances. The gallery's own "AX5 text" toggle
//  (and the `#Preview ... AX5` previews) cover the largest Dynamic Type size.
//

#if DEBUG

import SwiftUI

/// Renders `content` once in light and once in dark, each on its own ground.
struct WPGalleryBothSchemes<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s3) {
            panel(.light, label: "LIGHT", ground: WP.Hex.paper)
            panel(.dark, label: "DARK", ground: WP.Hex.darkBackground)
        }
    }

    private func panel(_ scheme: ColorScheme, label: String, ground: UInt32) -> some View {
        VStack(alignment: .leading, spacing: WP.Space.s3) {
            Text(label).wpText(.label).foregroundStyle(WP.muted)
            content()
        }
        .environment(\.colorScheme, scheme)
        .padding(WP.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(wpHex: ground))
        .clipShape(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
                .strokeBorder(Color(wpHex: WP.Hex.hairline), lineWidth: 1)
        )
    }
}

// MARK: - Toolbar and lever

struct WPGalleryMapParts: View {
    @State private var hour = 7
    @State private var lever: WPLeverState = .change

    var body: some View {
        WPGalleryBothSchemes {
            GalleryLabel("Map toolbar (search, More, Locate)")
            ZStack {
                WP.mapBlock
                WPMapToolbar(onSearch: {}, onMore: {}, onLocate: {})
                    .padding(.horizontal, 14)
                    .padding(.vertical, WP.Space.s4)
            }
            .clipShape(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous))

            GalleryLabel("Overnight headline with the lever")
            WPEndTimeHeadline(
                lead: "Green curbs are free from now until",
                end: "\(hour) AM tomorrow",
                sub: "8 h 49 min from now",
                lever: lever,
                onLever: { lever = lever == .change ? .done : .change }
            )
            if lever == .done {
                WPHourChipRow(selectedHour: hour) { hour = $0 }
            }
            GalleryLabel("Not Overnight: no lever")
            WPEndTimeHeadline(lead: "Green curbs are free from now until", end: "1:11 AM", sub: "2 h from now")
        }
    }
}

// MARK: - Verdict block

struct WPGalleryVerdictBlock: View {
    var body: some View {
        WPGalleryBothSchemes {
            WPVerdictBlock(kind: .park, over: "Free to stay until", big: "Mon 9:00 AM",
                           sub: "4 days 11 h left, then street cleaning", fractionLeft: 0.9)
            WPVerdictBlock(kind: .soon, over: "Free until", big: "6:00 AM",
                           sub: "7 h 49 min left, then street cleaning. That is before your Overnight window ends at 7 AM.")
            WPVerdictBlock(kind: .dont, over: "No parking right now", big: "Street cleaning",
                           sub: "Free again Mon 9:00 AM")
            WPVerdictBlock(kind: .meter, over: "Metered now", big: "Pay until 7 PM",
                           sub: "Free after 7 PM")
            WPVerdictBlock(kind: .nodata, over: "No sign data", big: "Read the signs",
                           sub: "WePark has no rules for this curb. Check the posted signs.")
            WPVerdictBlock(kind: .planpark, over: "Free for your whole trip, until", big: "Sun 6 PM",
                           sub: "From Sat 10 AM")
                .padding(WP.Space.s2)
            WPVerdictBlock(kind: .plandont, over: "Not free for the whole trip", big: "Sun 8 AM",
                           sub: "Street cleaning starts then.")
        }
    }
}

// MARK: - Scaffold

struct WPGalleryScaffold: View {
    var body: some View {
        WPGalleryBothSchemes {
            GalleryLabel("Commitment (taxi, raised, 72) with text secondary")
            scaffoldSample(kind: .commitment, clip: false)
            GalleryLabel("Navigation (ink, 64), App Clip badge")
            scaffoldSample(kind: .navigation, clip: true)
        }
    }

    private func scaffoldSample(kind: WPPrimaryKind, clip: Bool) -> some View {
        WPScreenScaffold(
            showsClipBadge: clip,
            onClose: {},
            title: "Bodega Cat is waiting for your spot",
            sub: "When are you leaving? They won't see who you are.",
            primary: (title: "Tell Bodega Cat", kind: kind, action: {}),
            secondary: (title: "I'm not leaving", action: {})
        ) {
            WPChoiceChip(title: "About 10 min", isSelected: true) {}
            WPChoiceChip(title: "About 30 min") {}
        }
        .frame(height: 560)
        .clipShape(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous))
    }
}

// MARK: - Choice chips

struct WPGalleryChoices: View {
    @State private var chosen = 1
    private let options = ["Now", "About 10 min", "About 30 min", "About 1 hour"]

    var body: some View {
        WPGalleryBothSchemes {
            GalleryLabel("Chosen = taxi, 2.5 line, raised 4. Tap to swap.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(options.indices, id: \.self) { index in
                    WPChoiceChip(title: options[index], isSelected: chosen == index) { chosen = index }
                }
            }
            WPChoiceChip(title: "Pick a time", height: 56) {}
        }
    }
}

// MARK: - List card

struct WPGalleryLists: View {
    @State private var reminders = true
    @State private var autoHeadsUp = false

    var body: some View {
        WPGalleryBothSchemes {
            WPListCard {
                WPListRow(title: "Reminders", trailing: .chevron) {}
                WPListDivider()
                WPListRow(title: "Home block", subtitle: "E 1st St", trailing: .value("Set")) {}
                WPListDivider()
                WPListToggleRow(title: "Remind me before it changes", subtitle: "1 hr before + the night before", isOn: $reminders)
                WPListDivider()
                WPListToggleRow(title: "Auto heads-up", subtitle: "Off by default", isOn: $autoHeadsUp)
                WPListDivider()
                WPListRow(title: "Version", trailing: .value("1.0"))
            }
        }
    }
}

// MARK: - Limit row

struct WPGalleryLimit: View {
    var body: some View {
        WPGalleryBothSchemes {
            WPLimitRow(message: "WePark can't notice when you drive off.", fixTitle: "Settings") {}
            WPListCard {
                WPListRow(title: "Remind me before it changes", subtitle: "Needs notifications")
            }
        }
    }
}

// MARK: - Coach

struct WPGalleryCoach: View {
    @State private var selected = 1

    var body: some View {
        WPGalleryBothSchemes {
            GalleryLabel("Coach card above the ringed target (no scrim)")
            WPCoachCard(step: 1, title: "Pick how long you're staying",
                        message: "The end time above the tiles changes with it.",
                        onSkip: {}, onNext: {})
            HStack(spacing: WP.Space.s2) {
                ForEach(0..<3, id: \.self) { index in
                    WPGoalTile(
                        title: ["A few hours", "Overnight", "For days"][index],
                        subtitle: ["until 1:11 AM", "until 7 AM", "until Wed 12/2"][index],
                        isSelected: index == selected
                    ) { selected = index }
                }
            }
            .padding(WP.Space.s2)
            .wpCoachRing(cornerRadius: WP.Radius.tile)
            .padding(WP.Space.s2)
        }
    }
}

// MARK: - Trip frame

struct WPGalleryTrip: View {
    var body: some View {
        WPGalleryBothSchemes {
            GalleryLabel("Tag (stripes 135 degrees) and frame")
            WPTripPlanTag(dates: "Sat 11/28 10 AM to Sun 11/29 6 PM")
            ZStack(alignment: .topLeading) {
                WP.mapBlock
                WPTripPlanTag(dates: "Sat 11/28 10 AM to Sun 11/29 6 PM")
                    .padding(WP.Space.s4)
            }
            // minHeight, not height: the tag grows with Dynamic Type instead of being clipped.
            .frame(minHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous))
            .wpTripFrame()
        }
    }
}

// MARK: - Stamp, hollow token, karma sticker

struct WPGalleryStatus: View {
    @State private var replay = 0

    var body: some View {
        WPGalleryBothSchemes {
            HStack(spacing: WP.Space.s6) {
                WPSpotPassedStamp()
                WPHollowToken()
                WPKarmaSticker(amount: 5).id(replay)
            }
            .padding(.vertical, WP.Space.s4)
            Button("Replay pop-in") { replay += 1 }.buttonStyle(.wpSecondary)
        }
    }
}

#endif
