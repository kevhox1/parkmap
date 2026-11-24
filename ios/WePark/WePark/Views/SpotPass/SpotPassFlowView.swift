//
//  SpotPassFlowView.swift
//  Views/SpotPass
//
//  Spot Pass C1: the seeker flow's root. Hosted by a `.fullScreenCover` in `ContentView` (an
//  independent presentation layer, like the onboarding story deck) and shown only when
//  `AppConstants.spotHandoffEnabled` is on. It owns no business logic: it maps the store's phase
//  to a screen and forwards taps to the store.
//
//    idle / creating / createFailed  -> explainer (first time) or spinner / failure
//    open / armed                    -> `SpotPassBadgeView` (QR, then "a neighbor's on it")
//    departed                        -> `SpotPassDepartedView` ("Spot opening up")
//    settled                         -> `SpotPassSettledView` (receipt, karma)
//    ended                           -> `SpotPassEndedView` ("Pass ended"), or closes when the
//                                       seeker caused it (Stop waiting, parked, drive ended)
//
//  Notification permission is asked at the first action that needs it (creating a pass), through
//  the existing `NotificationRationaleView` (spec §6.3). Declining is fine: the badge polls while
//  it is open and says so.
//

import SwiftUI
import UserNotifications

struct SpotPassFlowView: View {

    let store: SpotPassSeekerStore
    let onClose: () -> Void

    @State private var showFirstName: Bool
    @State private var explainerSeen: Bool
    @State private var showRationale = false
    /// Loaded from the server on appear; nil disables the toggle (design F12).
    @State private var firstName: String?

    @Environment(\.scenePhase) private var scenePhase

    init(
        store: SpotPassSeekerStore,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.onClose = onClose
        let preferences = SpotPassPreferences()
        _showFirstName = State(initialValue: preferences.showFirstName)
        _explainerSeen = State(initialValue: preferences.hasSeenExplainer)
    }

    var body: some View {
        content
            .animation(.easeInOut(duration: 0.25), value: store.phase)
            .sheet(isPresented: $showRationale, onDismiss: {
                Task { await createPass() }
            }) {
                NotificationRationaleView(
                    onDismiss: { showRationale = false },
                    onPermissionGranted: {}
                )
                .presentationDetents([.medium])
                .interactiveDismissDisabled(true)
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(20)
            }
            .task { await start() }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task {
                    await store.refresh()
                    store.startPollingIfNeeded()
                }
            }
            .onChange(of: store.phase) { _, newPhase in
                // The seeker caused this end (Stop waiting / parked / drive ended): just close.
                if case .ended(let reason) = newPhase, reason.closesFlow {
                    store.reset()
                    onClose()
                }
            }
    }

    // MARK: - Phase to screen

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle:
            if explainerSeen {
                SpotPassCreatingView(mode: .working, onRetry: {}, onClose: close)
            } else {
                SpotPassExplainerView(
                    firstName: firstName,
                    showFirstName: $showFirstName,
                    onCreate: {
                        let preferences = SpotPassPreferences()
                        preferences.showFirstName = showFirstName
                        preferences.hasSeenExplainer = true
                        explainerSeen = true
                        Task { await requestCreate() }
                    },
                    onClose: close
                )
            }

        case .creating:
            SpotPassCreatingView(mode: .working, onRetry: {}, onClose: close)

        case .createFailed(let failure):
            SpotPassCreatingView(
                mode: .failed(failure),
                onRetry: { Task { await requestCreate() } },
                onClose: close
            )

        case .open, .armed:
            if let session = store.session {
                SpotPassBadgeView(store: store, session: session, onDone: close)
            } else {
                SpotPassCreatingView(mode: .working, onRetry: {}, onClose: close)
            }

        case .departed:
            if let session = store.session {
                SpotPassDepartedView(
                    session: session,
                    isSubmitting: store.isSubmittingOutcome,
                    submitFailed: store.outcomeSubmitFailed,
                    onGotIt: { Task { await store.confirmOutcome(.gotSpot) } },
                    onDidntWorkOut: { Task { await store.confirmOutcome(.noLuck) } }
                )
            } else {
                SpotPassCreatingView(mode: .working, onRetry: {}, onClose: close)
            }

        case .settled(let outcome, let karmaDelta):
            SpotPassSettledView(
                outcome: outcome,
                karmaDelta: karmaDelta,
                onKeepLooking: makeNewPass,
                onDone: finish
            )

        case .ended(let reason):
            SpotPassEndedView(reason: reason, onMakeNew: makeNewPass, onDone: finish)
        }
    }

    // MARK: - Actions

    private func start() async {
        firstName = await store.loadFirstName()
        // A pass the seeker (or parking / drive end) already ended while this screen was closed
        // has nothing to show: start fresh.
        if case .ended(let reason) = store.phase, reason.closesFlow { store.reset() }
        await store.restoreIfNeeded()
        switch store.phase {
        case .idle:
            if explainerSeen { await requestCreate() }
        case .open, .armed, .departed:
            store.startPollingIfNeeded()
        default:
            break
        }
    }

    /// Asks for notification permission the first time (existing rationale sheet), then creates.
    private func requestCreate() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            showRationale = true
        } else {
            await createPass()
        }
    }

    private func createPass() async {
        // The toggle only counts if a first name is actually on file.
        let name = showFirstName ? firstName : nil
        await store.createPass(showName: name != nil, localDisplayName: name)
    }

    private func makeNewPass() {
        store.reset()
        Task { await requestCreate() }
    }

    /// "Done" on a result screen: forget the finished pass and close.
    private func finish() {
        store.reset()
        onClose()
    }

    /// "Done"/"Close" while a pass is live just closes the screen; the pass stays active.
    private func close() {
        onClose()
    }
}
