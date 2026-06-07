//
//  SettingsView.swift
//  WePark
//
//  W7 (§3.B / §4.B): Global settings sheet.
//
//  Presented via ActiveSheet.settings. Detents: .medium. DragIndicator: visible.
//
//  Content — three sections:
//    Section 1 — Help:
//      "Help & FAQ" row — NavigationLink to FAQHelpView (beginner NYC parking guide).
//      Placed first so new users find it immediately without scrolling.
//
//    Section 2 — Notifications:
//      Toggle "Park-reminder notifications" — logical inverse of notificationsMutedKey.
//      Toggle OFF: writes true to UserDefaults (mute). Cancels pending notifications.
//      Toggle ON: writes false to UserDefaults (unmute). Re-schedules via onUnmute closure.
//                 Fires ToastService.shared.show(message: "Reminders re-enabled") via onUnmute.
//
//    Section 3 — About:
//      Version row: "Version" label + "<version> (<build>)" trailing text.
//
//  No termsURL constant, no Link row — deferred per resolved OQ-W7-1.
//  The engineer has been explicitly instructed NOT to add any Terms/Privacy affordance.
//
//  Dependency injection via binding + closures — no direct reference to
//  NotificationScheduler, TileLoader, or ParkPinService. ContentView owns those.
//
//  No Calendar.current use.
//

import SwiftUI

struct SettingsView: View {

    // MARK: - Inputs

    /// Binding to ContentView's @State notificationsMuted (backed by UserDefaults).
    /// True = muted (toggle shows OFF). False = active (toggle shows ON).
    @Binding var notificationsMuted: Bool

    /// Called when the toggle flips from OFF → ON (unmute).
    /// ContentView uses this to reschedule notifications for the current pin (if any)
    /// and fire the "Reminders re-enabled" toast.
    let onUnmute: () -> Void

    /// CFBundleShortVersionString (e.g., "1.0")
    let appVersion: String

    /// CFBundleVersion (e.g., "42")
    let buildNumber: String

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Section 1 — Help

                Section("Help") {
                    NavigationLink {
                        FAQHelpView()
                    } label: {
                        Label("Help & FAQ", systemImage: "questionmark.circle")
                    }
                }

                // MARK: Section 2 — Notifications

                Section("Notifications") {
                    Toggle(isOn: notificationsActiveBinding) {
                        Text("Park-reminder notifications")
                    }
                }

                // MARK: Section 3 — About

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(appVersion) (\(buildNumber))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Toggle binding (logical inverse of notificationsMuted)

    /// The toggle shows the ACTIVE state, which is the logical inverse of the mute flag.
    /// When toggled ON: sets notificationsMuted = false, calls onUnmute.
    /// When toggled OFF: sets notificationsMuted = true (muting).
    private var notificationsActiveBinding: Binding<Bool> {
        Binding<Bool>(
            get: { !notificationsMuted },
            set: { isActive in
                let wasMuted = notificationsMuted
                notificationsMuted = !isActive
                // Only fire onUnmute when transitioning from muted → active.
                if wasMuted && isActive {
                    onUnmute()
                }
            }
        )
    }
}

// MARK: - Preview

#Preview {
    SettingsView(
        notificationsMuted: .constant(false),
        onUnmute: {},
        appVersion: "1.0",
        buildNumber: "42"
    )
    .presentationDetents([.medium])
}
