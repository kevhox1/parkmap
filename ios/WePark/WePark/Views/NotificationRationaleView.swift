//
//  NotificationRationaleView.swift
//  WePark
//
//  W6: One-time rationale sheet shown on first pin drop.
//  Triggered by ContentView.onReceive(parkPinService.firstPinDropped).
//  Gated by UserDefaults flag "wepark_notification_rationale_shown".
//
//  States:
//    .preRequest  — initial state, "Enable Reminders" / "Not now" buttons.
//    .denied      — shown after system prompt returns .denied.
//                   "Open Settings" / "Done" buttons.
//  No .granted state needed — sheet dismisses on grant (spec §3.1).
//
//  Sheet modifiers (applied in ContentView):
//    .presentationDetents([.medium])
//    .interactiveDismissDisabled(true)
//
//  Accessibility (AC-W6.19):
//    - Sheet title is first focusable element (.accessibilityAddTraits(.isHeader)).
//    - "Enable Reminders" → .accessibilityLabel("Enable parking reminders").
//    - "Not now" → .accessibilityLabel("Skip, do not enable reminders now").
//    - "Open Settings" → .accessibilityLabel("Open WePark in iOS Settings to enable notifications").
//

import SwiftUI
import UserNotifications

struct NotificationRationaleView: View {

    // MARK: - Inputs

    /// Called when the sheet should be dismissed (both grant and "Not now" paths).
    let onDismiss: () -> Void

    /// Called after permission is granted; the caller schedules notifications.
    /// Fired immediately after `requestAuthorization` returns `.authorized`.
    let onPermissionGranted: () -> Void

    // MARK: - State

    /// Sheet display state — transitions from preRequest to denied after a denied system prompt.
    @State private var sheetState: SheetState = .preRequest

    private enum SheetState {
        case preRequest
        case denied
    }

    // MARK: - Body

    var body: some View {
        switch sheetState {
        case .preRequest:
            preRequestContent
        case .denied:
            deniedContent
        }
    }

    // MARK: - Pre-request content (spec §3.1)

    private var preRequestContent: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "bell.badge.fill")
                .font(.system(size: 48))
                .foregroundStyle(ParkingColors.restrictionComingSoon)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("Stay ahead of street cleaning")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    // First focusable a11y element (AC-W6.19a).
                    .accessibilityAddTraits(.isHeader)

                Text(AppConstants.notificationRationale)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            VStack(spacing: 12) {
                Button {
                    requestPermission()
                } label: {
                    Text("Enable Reminders")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Enable parking reminders")

                Button {
                    notNow()
                } label: {
                    Text("Not now")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Skip, do not enable reminders now")
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .padding(.vertical, 16)
    }

    // MARK: - Denied content (spec §3.1)

    private var deniedContent: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "bell.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.gray)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("Reminders are off")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text("To get parking reminders, enable notifications for WePark in Settings.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            VStack(spacing: 12) {
                Button {
                    openSettings()
                } label: {
                    Text("Open Settings")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Open WePark in iOS Settings to enable notifications")

                Button {
                    onDismiss()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Dismiss this screen")
            }
            .padding(.horizontal, 32)

            Spacer()
        }
        .padding(.vertical, 16)
    }

    // MARK: - Actions

    /// Requests notification authorization and handles the result.
    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                // Always mark rationale as shown, regardless of user choice.
                UserDefaults.standard.set(true, forKey: AppConstants.notificationRationaleShownKey)

                if granted {
                    // Dismiss sheet; caller schedules notifications for current pin.
                    onPermissionGranted()
                    onDismiss()
                } else {
                    // Transition to denied state within the same sheet (spec §3.1).
                    sheetState = .denied
                }
            }
        }
    }

    /// "Not now" — marks rationale shown, dismisses, no notification scheduled.
    private func notNow() {
        UserDefaults.standard.set(true, forKey: AppConstants.notificationRationaleShownKey)
        onDismiss()
    }

    /// Opens iOS Settings for this app (spec §3.1 denied state).
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Preview

#Preview {
    NotificationRationaleView(
        onDismiss: {},
        onPermissionGranted: {}
    )
    .presentationDetents([.medium])
}
