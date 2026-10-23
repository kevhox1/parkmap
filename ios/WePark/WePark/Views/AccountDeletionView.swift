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

    var body: some View {
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
