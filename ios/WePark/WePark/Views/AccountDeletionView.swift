//
//  AccountDeletionView.swift
//  WePark
//
//  Open item #38 — Settings "Delete account" row + confirmation screen (Apple guideline
//  5.1.1(v)). Dark-shipped: `SettingsView` mounts `AccountDeletionSection` only when
//  `AppConstants.accountDeletionRowVisible()` is true (`accountDeletionEnabled`, false today).
//
//  Placement: the LAST section of Settings (below About) — destructive actions live at the
//  bottom of the list, set apart from everyday toggles. WePark has no sign-out (identity is a
//  silent anonymous session), so there is no adjacent Log-out row to order against.
//
//  Confirmation (Apple review expects it): a full sheet that states plainly what happens —
//  pins and chat stay but lose the name; profile, notification registrations, votes and
//  evidence photos are deleted; it cannot be undone — with a large red destructive button and a
//  large Cancel (Kevin's standing "bigger touch targets" preference). Copy is neutral
//  compliance wording; no enforcement-evasion language anywhere (spec constraint).
//
//  Behavior lives in `AccountDeletionModel` (pure state machine, driven by the
//  `AccountDeleting` protocol so it is unit-tested without a network): the first tap moves
//  `idle -> deleting` SYNCHRONOUSLY, so a second tap in the same run-loop turn is a no-op
//  (double-tap guard); a failure returns to `idle` with a plain-language message and nothing
//  changed, so the user can retry; success moves to `deleted`.
//
//  The environment's `SupabaseAuthService` is injected at the app root (`WeParkApp`'s
//  `.environment(authService)`) — read as an OPTIONAL so previews/tests that don't inject it
//  simply render no row instead of crashing. This keeps `ContentView.swift` untouched.
//
//  [COMPILE-UNVERIFIED] Written on a Linux VPS with no Swift toolchain.
//

import SwiftUI

// MARK: - AccountDeletionPhase

enum AccountDeletionPhase {
    case idle
    case deleting
    case deleted
}

// MARK: - AccountDeletionModel

@MainActor
@Observable
final class AccountDeletionModel {

    /// Fallback shown for any failure that is not an `AccountDeletionError` (never raw
    /// `localizedDescription`: it can contain technical text).
    nonisolated static let genericFailureMessage =
        "We couldn't delete your account. Please check your connection and try again."

    private(set) var phase: AccountDeletionPhase = .idle
    private(set) var errorMessage: String? = nil

    private let deleter: any AccountDeleting

    init(deleter: any AccountDeleting) {
        self.deleter = deleter
    }

    var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    var isDeleting: Bool {
        if case .deleting = phase { return true }
        return false
    }

    var isDeleted: Bool {
        if case .deleted = phase { return true }
        return false
    }

    /// Runs the deletion once. A call while one is already running (or after success) is a
    /// no-op — the phase flips BEFORE the first suspension point, so back-to-back taps cannot
    /// start two runs.
    func confirmDeletion() async {
        guard isIdle else { return }
        phase = .deleting
        errorMessage = nil
        do {
            try await deleter.deleteAccount()
            phase = .deleted
        } catch {
            if let deletionError = error as? AccountDeletionError {
                errorMessage = deletionError.errorDescription ?? Self.genericFailureMessage
            } else {
                errorMessage = Self.genericFailureMessage
            }
            phase = .idle
        }
    }
}

// MARK: - AccountDeletionSection (the Settings row)

/// The last Settings section. Mounted by `SettingsView` only while the flag is on.
struct AccountDeletionSection: View {

    @Environment(SupabaseAuthService.self) private var authService: SupabaseAuthService?
    @Environment(\.dismiss) private var dismissSettings

    @State private var model: AccountDeletionModel? = nil
    @State private var showConfirm = false

    var body: some View {
        Section {
            Button(role: .destructive) {
                presentConfirmation()
            } label: {
                Label("Delete account", systemImage: "trash")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(authService == nil)
            .accessibilityHint("Permanently deletes your WePark account. You will be asked to confirm.")
            .sheet(isPresented: $showConfirm, onDismiss: handleConfirmationDismissed) {
                if let model {
                    DeleteAccountConfirmView(
                        model: model,
                        onFinished: { showConfirm = false }
                    )
                }
            }
        } footer: {
            Text("Permanently deletes your profile and photos. Your pins and chat messages stay, without your name.")
        }
    }

    private func presentConfirmation() {
        guard let authService else { return }
        // A fresh model per presentation, so an earlier failure message never lingers.
        model = AccountDeletionModel(deleter: AccountDeletionService(authService: authService))
        showConfirm = true
    }

    /// Runs after the confirmation sheet has fully dismissed. On success: thank the user, then
    /// close Settings (the app is already on its replacement anonymous identity).
    private func handleConfirmationDismissed() {
        guard let model, model.isDeleted else { return }
        ToastService.shared.show(message: "Your account was deleted")
        dismissSettings()
    }
}

// MARK: - DeleteAccountConfirmView

struct DeleteAccountConfirmView: View {

    @Bindable var model: AccountDeletionModel

    /// Called when the sheet should close (Cancel, or success).
    let onFinished: () -> Void

    /// What deletion does NOT touch (the SQL contract: parked car and reminders are device-local,
    /// not account data) and what the app does next. Exposed for a copy test.
    nonisolated static let keptOnDeviceCopy =
        "Your parked car and reminders on this device are kept. WePark keeps working, with a fresh anonymous profile."

    var body: some View {
        if AppConstants.designSystemV2Enabled {
            stoopBody
        } else {
            legacyBody
        }
    }

    /// Stoop Phase 6a (B15.4): the round-2 confirmation. Same model, same buttons' behavior; the
    /// consequence copy stays the accurate flag-off wording (what deletion really does), not the
    /// mock's placeholder text.
    private var stoopBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WP.Space.s3) {
                Text("Delete your account?")
                    .font(WP.Font.fredoka(28, .bold, relativeTo: .title))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("This can\u{2019}t be undone.")
                    .font(WP.Font.fredoka(17, .regular, relativeTo: .body))
                    .foregroundStyle(WP.text)
                WPListCard {
                    stoopConsequence("Your pins and chat messages stay on the map, but they no longer carry your name. They\u{2019}ll show as \u{201C}Former neighbor.\u{201D}")
                    WPListDivider()
                    stoopConsequence("Your profile, notification registrations, votes and evidence photos are deleted.")
                    WPListDivider()
                    stoopConsequence(DeleteAccountConfirmView.keptOnDeviceCopy)
                }
                if let message = model.errorMessage {
                    Text(message)
                        .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                        .foregroundStyle(WP.noParkText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Error. \(message)")
                }
                Button {
                    Task { await model.confirmDeletion() }
                } label: {
                    HStack(spacing: WP.Space.s2) {
                        if model.isDeleting { ProgressView().tint(WP.noParkText) }
                        Text(model.isDeleting ? "Deleting\u{2026}" : "Delete account")
                    }
                }
                .buttonStyle(WPDestructiveOutlineStyle())
                .disabled(!model.isIdle)
                .accessibilityHint("Permanently deletes your account. This can\u{2019}t be undone.")
                Button("Keep my account") { onFinished() }
                    .buttonStyle(InkPillButtonStyle(labelColor: .white))
                    .disabled(model.isDeleting)
            }
            .padding(.horizontal, WP.Space.screenMargin)
            .padding(.top, WP.Space.s6)
            .padding(.bottom, WP.Space.s4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(WP.card.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(model.isDeleting)
        .onChange(of: model.isDeleted) { _, deleted in
            if deleted { onFinished() }
        }
    }

    private func stoopConsequence(_ text: String) -> some View {
        Text(text)
            .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
            .foregroundStyle(WP.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, WP.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var legacyBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)

                Text("Delete your account?")
                    .font(.title2.weight(.bold))

                VStack(alignment: .leading, spacing: 14) {
                    consequenceRow(
                        systemImage: "person.2.fill",
                        text: "Your pins and chat messages stay on the map, but they no longer carry your name \u{2014} they\u{2019}ll show as \u{201C}Former neighbor.\u{201D}"
                    )
                    consequenceRow(
                        systemImage: "trash.fill",
                        text: "Your profile, notification registrations, votes and evidence photos are deleted."
                    )
                    consequenceRow(
                        systemImage: "car.fill",
                        text: DeleteAccountConfirmView.keptOnDeviceCopy
                    )
                    consequenceRow(
                        systemImage: "exclamationmark.circle.fill",
                        text: "This can\u{2019}t be undone."
                    )
                }

                if let message = model.errorMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Error. \(message)")
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await model.confirmDeletion() }
                    } label: {
                        HStack(spacing: 10) {
                            if model.isDeleting {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(model.isDeleting ? "Deleting\u{2026}" : "Delete my account")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!model.isIdle)
                    .accessibilityHint("Permanently deletes your account. This can\u{2019}t be undone.")

                    Button {
                        onFinished()
                    } label: {
                        Text("Cancel")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isDeleting)
                }
            }
            .padding(24)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(model.isDeleting)
        .onChange(of: model.isDeleted) { _, deleted in
            if deleted {
                onFinished()
            }
        }
    }

    private func consequenceRow(systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stoop destructive button (B15.4)

/// Delete account: card fill, 2.5pt red line, red 17/700 label, 64 tall. Flat (it is not the thing
/// you want to press, so it is not raised or taxi).
struct WPDestructiveOutlineStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = Capsule()
            configuration.label
                .font(WP.Font.fredoka(20, .bold, relativeTo: .title3))
                .foregroundStyle(isEnabled ? WP.noParkText : WP.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, WP.Space.s6)
                .frame(maxWidth: .infinity, minHeight: WP.Control.mediumHeight)
                .background(shape.fill(configuration.isPressed ? WP.lifted : WP.card))
                .overlay(shape.strokeBorder(isEnabled ? WP.noParkText : WP.hairline, lineWidth: WP.Border.control))
                .contentShape(shape)
        }
    }
}
