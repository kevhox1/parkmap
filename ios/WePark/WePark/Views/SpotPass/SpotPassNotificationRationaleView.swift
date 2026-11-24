//
//  SpotPassNotificationRationaleView.swift
//  Views/SpotPass
//
//  Spot Pass follow-up (F1): the seeker's own notification rationale (design §8.3, §9.2), shown
//  once before the first pass is created. Indigo chrome and Spot Pass voice; it replaces the
//  street-cleaning rationale the flow used to borrow. Scrolls, so it never truncates at AX5.
//
//  "Not now" is remembered (`SpotPassPreferences.notificationRationaleSeen`): the flow then just
//  creates the pass and relies on polling plus the badge's "notifications are off" banner.
//

import SwiftUI
import UserNotifications

struct SpotPassNotificationRationaleView: View {

    /// Called when the user has answered (allowed, system-denied, or "Not now"). The flow
    /// dismisses the sheet and creates the pass.
    let onFinished: () -> Void
    /// Called after the user allows notifications, so the app can register for remote pushes.
    let onPermissionGranted: () -> Void

    var body: some View {
        ZStack {
            SpotPassTheme.screenBackground
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(SpotPassTheme.lavender)
                        .padding(.top, 24)
                        .accessibilityHidden(true)

                    Text(SpotPassCopy.rationaleTitle)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    Text(SpotPassCopy.rationaleBody)
                        .font(.body)
                        .foregroundStyle(SpotPassTheme.lavender)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 12) {
                        Button {
                            allow()
                        } label: {
                            Text(SpotPassCopy.rationaleAllow)
                        }
                        .buttonStyle(SpotPassButtonStyle(kind: .primary))

                        Button {
                            notNow()
                        } label: {
                            Text(SpotPassCopy.rationaleNotNow)
                        }
                        .buttonStyle(SpotPassButtonStyle(kind: .secondary))
                        .accessibilityHint("You can still watch this screen for updates.")
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .preferredColorScheme(.dark)
    }

    private func allow() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                SpotPassPreferences().notificationRationaleSeen = true
                if granted { onPermissionGranted() }
                onFinished()
            }
        }
    }

    private func notNow() {
        SpotPassPreferences().notificationRationaleSeen = true
        onFinished()
    }
}
