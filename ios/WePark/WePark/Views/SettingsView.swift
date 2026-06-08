//
//  SettingsView.swift
//  WePark
//
//  W7 (§3.B / §4.B): Global settings sheet.
//  FT-6: Added "Move-Your-Car Reminders" section with 5 preset toggles.
//
//  Presented via ActiveSheet.settings. Detents: .medium. DragIndicator: visible.
//
//  Content — four sections:
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
//    Section 3 — Move-Your-Car Reminders (FT-6):
//      Five preset toggles bound to $offsets fields.
//      Disabled when global notifications mute is ON (prevents confusing state).
//      Changes persist via .onChange(of: offsets) → save + onOffsetsChange().
//
//    Section 4 — About:
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

    /// Binding to ContentView's @State reminderOffsets (backed by UserDefaults).
    /// FT-6: The five preset toggles bind directly to this value's fields.
    @Binding var offsets: ReminderOffsets

    /// Called when the toggle flips from OFF → ON (unmute).
    /// ContentView uses this to reschedule notifications for the current pin (if any)
    /// and fire the "Reminders re-enabled" toast.
    let onUnmute: () -> Void

    /// Called whenever any reminder-offset toggle changes (FT-6).
    /// ContentView uses this to persist the new offsets and reschedule notifications.
    let onOffsetsChange: () -> Void

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

                // MARK: Section 3 — Move-Your-Car Reminders (FT-6)

                Section("Move-Your-Car Reminders") {
                    Toggle("15 minutes before", isOn: $offsets.remind15Min)
                    Toggle("30 minutes before", isOn: $offsets.remind30Min)
                    Toggle("1 hour before",     isOn: $offsets.remind1Hour)
                    Toggle("2 hours before",    isOn: $offsets.remind2Hours)
                    Toggle("Night before (8 PM)", isOn: $offsets.remindNightBefore)
                }
                .disabled(notificationsMuted)

                // MARK: Section 4 — About

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
            .onChange(of: offsets) { _, newOffsets in
                ReminderOffsets.save(newOffsets, to: .standard)
                onOffsetsChange()
            }
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
        offsets: .constant(ReminderOffsets.default),
        onUnmute: {},
        onOffsetsChange: {},
        appVersion: "1.0",
        buildNumber: "42"
    )
    .presentationDetents([.medium])
}
