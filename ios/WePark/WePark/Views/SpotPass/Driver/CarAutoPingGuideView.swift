//
//  CarAutoPingGuideView.swift
//  Views/SpotPass/Driver
//
//  Spot Pass C2 (spec 7.5, design item 8): the auto heads-up. WePark exposes the "I'm leaving"
//  App Intent; the user builds the Shortcuts automation ("when my phone connects to my car")
//  themselves because Apple does not allow an app to create or share a personal automation.
//  The app can only GUIDE. No location permission is involved.
//
//  Honest copy: runs without asking where the OS allows it (CarPlay; Bluetooth may still ask,
//  device-verify), and does nothing at all when no Spot Pass is armed.
//

import SwiftUI

nonisolated enum CarAutoPingGuideContent {
    static let title = "Auto heads\u{2011}up from your car"
    static let intro = "Skip the tap. Your phone can give your neighbor a heads-up the moment it connects to your car."
    static let steps: [String] = [
        "Open Shortcuts and tap Automation.",
        "Tap New Automation, then choose CarPlay or Bluetooth, pick your car, and choose Is Connected.",
        "Tap Add Action, search for WePark, and choose \u{201C}I'm leaving\u{201D}.",
        "Choose Run Immediately, then tap Done."
    ]
    static let honestNote = "Apple only lets you create automations yourself, so WePark can't set this up for you. It does nothing unless you have an active Spot Pass, and it never uses your location."
    static let openShortcuts = "Open Shortcuts"
    static let close = "Done"
    /// The Shortcuts app's URL scheme.
    static let shortcutsURL = URL(string: "shortcuts://")
}

struct CarAutoPingGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(CarAutoPingGuideContent.intro)
                        .font(.title3).foregroundStyle(SpotPassTheme.lavender)
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(CarAutoPingGuideContent.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 14) {
                                Text("\(index + 1)")
                                    .font(.headline.weight(.bold)).foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(SpotPassTheme.indigo, in: Circle())
                                    .accessibilityHidden(true)
                                Text(step).font(.body).foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Step \(index + 1). \(step)")
                        }
                    }
                    Text(CarAutoPingGuideContent.honestNote)
                        .font(.footnote).foregroundStyle(SpotPassTheme.lavender)
                    if let url = CarAutoPingGuideContent.shortcutsURL {
                        Button(CarAutoPingGuideContent.openShortcuts) { openURL(url) }
                            .buttonStyle(DriverHeroButtonStyle(minHeight: SpotPassTheme.buttonHeight))
                    }
                }
                .padding(20)
            }
            .background(DriverBackdrop())
            .navigationTitle(CarAutoPingGuideContent.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(CarAutoPingGuideContent.close) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(SpotPassTheme.indigo)
    }
}
