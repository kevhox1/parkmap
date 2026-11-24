//
//  WeParkClipApp.swift
//  WePark Clip (com.kevinhoxha.wepark.Clip)
//
//  Spot Pass C0 scaffold: a placeholder entry that only proves the invocation plumbing. It
//  receives the QR / link invocation (NSUserActivityTypeBrowsingWeb) and parses it into a
//  `SpotPassLink`. No network, no permission requests, no background work. C3 builds the real
//  clip UI on top of this entry.
//

import SwiftUI

@main
struct WeParkClipApp: App {

    /// The most recent invocation, if it was a Spot Pass link.
    @State private var invocation: SpotPassLink?

    var body: some Scene {
        WindowGroup {
            ClipPlaceholderView(hasToken: invocation?.token != nil)
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    invocation = SpotPassLink(url: url)
                }
                .preferredColorScheme(.dark)
        }
    }
}

/// Static placeholder. The token is deliberately never rendered.
private struct ClipPlaceholderView: View {
    let hasToken: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "parkingsign.circle")
                .font(.system(size: 64))
                .accessibilityHidden(true)
            Text("Pass the spot")
                .font(.largeTitle.bold())
            Text(hasToken
                 ? "Spot Pass is almost ready."
                 : "Looking for a spot? Open WePark and tap Spot Pass.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }
}
