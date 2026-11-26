//
//  SuggestNeighborhoodSheet.swift
//  WePark
//
//  Open item #39 — "Suggest a neighborhood". A small form sheet reachable from the
//  out-of-coverage destination card (`BrowseSearchAreaView`) and a Settings row. Dark-shipped:
//  both entry points render only when `AppConstants.coverageSuggestionVisible()` is true
//  (`coverageRequestsEnabled`, false today).
//
//  Fields (mirroring `supabase/11-coverage-requests.sql`, via `CoverageRequestRules`):
//    - Neighborhood or city: required, 2...80 visible characters; an inline hint appears
//      instead of the user ever seeing a 4xx.
//    - Note: optional, <= 500.
//  Location: the sheet is handed the VIEWED area's coordinate (the searched destination from
//  `BrowseSearchAreaView`; nothing at all from Settings) — never the user's own GPS. It is
//  rounded to 2 decimals before sending.
//
//  Behavior lives in `SuggestNeighborhoodModel` (unit-tested without a network through the
//  `CoverageRequestSubmitting` protocol). Submit is guarded against double-taps the same way
//  `AccountDeletionModel` is: the phase flips before the first suspension point.
//
//  Copy: thanks is "Thanks — we'll use this to decide where to launch next." (the SQL header's
//  suggestion). A rate-limit response shows the NEUTRAL, non-blaming message from
//  `CoverageRequestError.rateLimited` (the global cap can trip for reasons that are not the
//  user's fault).
//
//  Large touch targets throughout (Kevin's standing preference): 56pt Submit.
//
//  [COMPILE-UNVERIFIED] Written on a Linux VPS with no Swift toolchain.
//

import SwiftUI

// MARK: - SuggestNeighborhoodPhase

enum SuggestNeighborhoodPhase {
    case editing
    case submitting
    case sent
}

// MARK: - SuggestNeighborhoodModel

@MainActor
@Observable
final class SuggestNeighborhoodModel {

    /// Success copy (the SQL header's suggestion).
    nonisolated static let thanksMessage = "Thanks \u{2014} we\u{2019}ll use this to decide where to launch next."

    /// Shown if no submitter could be attached (no auth service in the environment).
    nonisolated static let unavailableMessage = "We couldn't connect just yet. Please try again in a moment."

    var city: String = ""
    var note: String = ""

    private(set) var phase: SuggestNeighborhoodPhase = .editing
    private(set) var errorMessage: String? = nil

    let viewedLatitude: Double?
    let viewedLongitude: Double?

    private var submitter: (any CoverageRequestSubmitting)?

    init(
        viewedLatitude: Double?,
        viewedLongitude: Double?,
        submitter: (any CoverageRequestSubmitting)? = nil
    ) {
        self.viewedLatitude = viewedLatitude
        self.viewedLongitude = viewedLongitude
        self.submitter = submitter
    }

    /// Attaches the submitter lazily (the view can only read the environment after it exists).
    /// Never replaces one that is already attached.
    func attachSubmitterIfNeeded(_ make: () -> any CoverageRequestSubmitting) {
        if submitter == nil {
            submitter = make()
        }
    }

    var isEditing: Bool {
        if case .editing = phase { return true }
        return false
    }

    var isSubmitting: Bool {
        if case .submitting = phase { return true }
        return false
    }

    var isSent: Bool {
        if case .sent = phase { return true }
        return false
    }

    /// Inline hint under the city field (nil when fine or still empty).
    var cityHint: String? {
        CoverageRequestRules.cityIssueMessage(city)
    }

    /// Inline hint under the note field.
    var noteHint: String? {
        CoverageRequestRules.noteIssueMessage(note)
    }

    var canSubmit: Bool {
        isEditing && CoverageRequestRules.isFormSubmittable(city: city, note: note)
    }

    /// Sends the suggestion once. No-op unless the form is valid and idle.
    func submit() async {
        guard canSubmit else { return }
        guard let draft = CoverageRequestRules.makeDraft(
            city: city,
            note: note,
            viewedLatitude: viewedLatitude,
            viewedLongitude: viewedLongitude
        ) else { return }
        guard let submitter else {
            errorMessage = Self.unavailableMessage
            return
        }
        phase = .submitting
        errorMessage = nil
        do {
            try await submitter.submit(draft)
            phase = .sent
        } catch {
            if let requestError = error as? CoverageRequestError {
                errorMessage = requestError.errorDescription ?? CoverageRequestError.serverRejected.errorDescription
            } else {
                errorMessage = CoverageRequestError.serverRejected.errorDescription
            }
            phase = .editing
        }
    }
}

// MARK: - SuggestNeighborhoodSheet

struct SuggestNeighborhoodSheet: View {

    @Environment(SupabaseAuthService.self) private var authService: SupabaseAuthService?
    @Environment(\.dismiss) private var dismiss

    @State private var model: SuggestNeighborhoodModel

    /// - Parameters:
    ///   - viewedLatitude/viewedLongitude: the VIEWED area (searched destination / map centre),
    ///     or nil for both when there is no such area (e.g. opened from Settings). Never pass
    ///     the user's own GPS fix.
    init(viewedLatitude: Double?, viewedLongitude: Double?) {
        _model = State(initialValue: SuggestNeighborhoodModel(
            viewedLatitude: viewedLatitude,
            viewedLongitude: viewedLongitude
        ))
    }

    var body: some View {
        if AppConstants.designSystemV2Enabled {
            stoopBody
        } else {
            legacyBody
        }
    }

    // MARK: Stoop (B15.5)

    /// Stoop Phase 6a: the round-2 form. Same model, validation, submit and thanks copy; only the
    /// skin differs. Reachable only while `coverageRequestsEnabled` is on (off today).
    private var stoopBody: some View {
        Group {
            if model.isSent {
                WPScreenScaffold(
                    closeLabel: "Done",
                    onClose: { dismiss() },
                    title: "Thank you!",
                    sub: SuggestNeighborhoodModel.thanksMessage
                ) { EmptyView() }
                .task {
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    dismiss()
                }
            } else {
                WPScreenScaffold(
                    closeLabel: "Back",
                    onClose: { dismiss() },
                    title: "Where should WePark go next?",
                    // TODO: the coverage area has no name in code (`AppConstants.manhattanCoverageBounds`
                    // is bounds only), so "Manhattan" is still a literal here. Source it from a named
                    // coverage definition when coverage grows past Manhattan.
                    sub: "We cover Manhattan today. Suggestions decide the order of what comes after.",
                    primary: stoopPrimary
                ) {
                    stoopForm
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.isSubmitting)
        .onAppear {
            if let authService {
                model.attachSubmitterIfNeeded { CoverageRequestService(authService: authService) }
            }
        }
    }

    private var stoopPrimary: (title: String, kind: WPPrimaryKind, action: () -> Void) {
        if model.isSubmitting {
            return (title: "Sending\u{2026}", kind: WPPrimaryKind.navigation, action: {})
        }
        return (title: "Send suggestion", kind: WPPrimaryKind.navigation, action: { Task { await model.submit() } })
    }

    private var stoopForm: some View {
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            Text("Neighborhood")
                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                .foregroundStyle(WP.text)
            TextField("Astoria, Queens", text: $model.city)
                .textInputAutocapitalization(.words)
                .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                .foregroundStyle(WP.text)
                .padding(.horizontal, WP.Space.s4)
                .frame(minHeight: WP.Target.standard)
                .background(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).fill(WP.card))
                .overlay(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).strokeBorder(WP.line, lineWidth: WP.Border.fact))
                .accessibilityLabel("Neighborhood or city")
            if let hint = model.cityHint {
                Text(hint)
                    .font(WP.Font.fredoka(13, .regular, relativeTo: .caption))
                    .foregroundStyle(WP.muted)
            }
            Text("Anything we should know? (optional)")
                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                .foregroundStyle(WP.text)
                .padding(.top, WP.Space.s2)
            TextField("Street cleaning days, tricky blocks\u{2026}", text: $model.note, axis: .vertical)
                .lineLimit(3...6)
                .font(WP.Font.fredoka(17, .regular, relativeTo: .body))
                .foregroundStyle(WP.text)
                .padding(WP.Space.s4)
                .frame(minHeight: 120, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).fill(WP.card))
                .overlay(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous).strokeBorder(WP.line, lineWidth: WP.Border.fact))
                .accessibilityLabel("Note, optional")
            if let hint = model.noteHint {
                Text(hint)
                    .font(WP.Font.fredoka(13, .regular, relativeTo: .caption))
                    .foregroundStyle(WP.muted)
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .foregroundStyle(WP.noParkText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error. \(message)")
            }
        }
    }

    private var legacyBody: some View {
        NavigationStack {
            Group {
                if model.isSent {
                    thanksView
                } else {
                    formView
                }
            }
            .navigationTitle("Suggest a neighborhood")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isSent ? "Done" : "Cancel") {
                        dismiss()
                    }
                    .disabled(model.isSubmitting)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.isSubmitting)
        .onAppear {
            if let authService {
                model.attachSubmitterIfNeeded { CoverageRequestService(authService: authService) }
            }
        }
    }

    // MARK: Form

    private var formView: some View {
        Form {
            Section {
                TextField("Neighborhood or city", text: $model.city)
                    .textInputAutocapitalization(.words)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Neighborhood or city")
                if let hint = model.cityHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Where should we go next?")
            } footer: {
                Text("e.g. Park Slope, Brooklyn \u{00B7} Hoboken, NJ")
            }

            Section {
                TextField("Anything we should know? (optional)", text: $model.note, axis: .vertical)
                    .lineLimit(3...6)
                    .frame(minHeight: 44, alignment: .topLeading)
                    .accessibilityLabel("Note, optional")
                if let hint = model.noteHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = model.errorMessage {
                Section {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error. \(message)")
                }
            }

            Section {
                Button {
                    Task { await model.submit() }
                } label: {
                    HStack(spacing: 10) {
                        if model.isSubmitting {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(model.isSubmitting ? "Sending\u{2026}" : "Submit")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmit)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    // MARK: Thanks

    private var thanksView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Thank you!")
                .font(.title2.weight(.bold))
            Text(SuggestNeighborhoodModel.thanksMessage)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        // Friendly auto-close; the Done button above closes immediately. The task is cancelled
        // automatically if the sheet is dismissed first.
        .task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            dismiss()
        }
    }
}

// MARK: - SuggestNeighborhoodSettingsRow

/// The Settings entry point ("Suggest a neighborhood"). Mounted by `SettingsView` only while
/// `AppConstants.coverageSuggestionVisible()` is true. No viewed area from here: the sheet
/// sends the text only (both coordinates omitted).
struct SuggestNeighborhoodSettingsRow: View {

    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Label("Suggest a neighborhood", systemImage: "mappin.and.ellipse")
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .contentShape(Rectangle())
        }
        .sheet(isPresented: $showSheet) {
            SuggestNeighborhoodSheet(viewedLatitude: nil, viewedLongitude: nil)
        }
    }
}
