//
//  SpotPassSeekerStore.swift
//  Services/SpotPass
//
//  Spot Pass C1: the seeker's one source of truth (`docs/specs/qr-spot-handoff.md` §3, §9, §10;
//  `docs/design/spot-pass-design.md` §2.5, §9). Owns the active pass, the phase
//  (`SpotPassReducer` decides every transition), polling, persistence, the success haptic and the
//  outcome/karma round trip. Views only read it and call its intents.
//
//  How it hears about changes (spec §3 sequence 6, §8):
//    - POLL `api.fetchStatus` (4 s while the QR is showing, 15 s armed, 30 s once departed). The
//      poll is the truth and the only path that works with notifications off.
//    - PUSH (`armed` / `departed` alerts) only triggers an immediate refresh via `handlePush`.
//    - Foreground: the flow view calls `refresh()` when the scene becomes active.
//
//  Safety (spec §9): nothing here ever derives or stores a clock time for the driver's departure.
//  The store keeps the server's `leave_at` only so the VIEW can compute a coarse band.
//

import Foundation
import Observation

@MainActor
@Observable
final class SpotPassSeekerStore {

    // MARK: - Observable state

    private(set) var phase: SpotPassPhase = .idle
    private(set) var session: SpotPassSession?
    /// The latest server row, once one has arrived (and the synthetic `created` row from create).
    private(set) var snapshot: SpotPassSnapshot?
    /// The seeker's own karma, for the bucket chip. Nil until fetched; the chip then reads "New neighbor".
    private(set) var karma: SpotPassKarma?
    /// True while an outcome tap is in flight (the buttons disable, never double-send).
    private(set) var isSubmittingOutcome = false
    /// True after a failed outcome submit, so the view can say so and let the seeker retry.
    private(set) var outcomeSubmitFailed = false

    // MARK: - Derived

    var leaveAt: Date? { snapshot?.leaveAt }
    var expiresAt: Date? { snapshot?.expiresAt ?? session?.expiresAt }

    /// The karma bucket for the badge chip (design §2.4).
    var karmaBucketLabel: String { (karma ?? .zero).bucketLabel }

    // MARK: - Dependencies

    @ObservationIgnored private let api: any SpotPassAPI
    @ObservationIgnored private let persistence: any SpotPassPersistence
    @ObservationIgnored private let feedback: any SpotPassFeedback
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(
        api: any SpotPassAPI,
        persistence: any SpotPassPersistence,
        feedback: any SpotPassFeedback,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.api = api
        self.persistence = persistence
        self.feedback = feedback
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Polling cadence (pure, testable)

    /// Seconds between polls for a phase, or nil when nothing should poll.
    nonisolated static func pollInterval(for phase: SpotPassPhase) -> TimeInterval? {
        switch phase {
        case .open: return 4
        case .armed: return 15
        case .departed: return 30
        default: return nil
        }
    }

    // MARK: - Intents

    /// Brings back a pass that was live when the app last closed (and re-checks it with the server).
    /// No-op unless the store is idle.
    func restoreIfNeeded() async {
        guard phase == .idle, let saved = persistence.load() else { return }
        session = saved
        let synthetic = SpotPassSnapshot(status: .created, expiresAt: saved.expiresAt)
        snapshot = synthetic
        phase = SpotPassReducer.next(from: .open, snapshot: synthetic, now: now())
        if phase.isLive {
            await refresh()
            startPollingIfNeeded()
        } else {
            // Dead on arrival (expired while the app was closed): forget it quietly so the next
            // entry offers a fresh pass instead of an old "Pass ended" screen.
            finishTerminal()
            session = nil
            snapshot = nil
            phase = .idle
        }
    }

    /// Creates a pass (design §9.2). Safe to call repeatedly: a live pass is left alone ("Already
    /// active pass: opens it").
    func createPass(showName: Bool, localDisplayName: String? = nil) async {
        if phase.isLive { return }
        phase = .creating
        session = nil
        snapshot = nil
        outcomeSubmitFailed = false
        do {
            var created = try await api.createHandoff(showName: showName)
            // The contract returns no name; when the seeker opted in and the server did not echo
            // `display_name`, show the name we sent the toggle for (the badge must match the driver).
            if showName, created.displayName == nil, let localDisplayName {
                created = SpotPassSession(
                    id: created.id,
                    token: created.token,
                    alias: created.alias,
                    glyph: created.glyph,
                    displayName: localDisplayName,
                    createdAt: created.createdAt,
                    expiresAt: created.expiresAt
                )
            }
            session = created
            snapshot = SpotPassSnapshot(status: .created, expiresAt: created.expiresAt)
            phase = .open
            persistence.save(created)
            karma = (try? await api.fetchKarma()) ?? karma
            startPollingIfNeeded()
        } catch let error as SpotPassAPIError {
            phase = .createFailed(error == .offline ? .offline : .generic)
        } catch {
            phase = .createFailed(.generic)
        }
    }

    /// One poll. Network failures are ignored (the next poll retries); a purged row ends the pass.
    func refresh() async {
        guard phase.isLive, let session else { return }
        do {
            let latest = try await api.fetchStatus(id: session.id)
            apply(latest)
        } catch SpotPassAPIError.notFound {
            transition(to: .ended(.expired))
        } catch {
            // Offline or a transient error: re-evaluate the clock so a pass still expires on time.
            if let snapshot { apply(snapshot) }
        }
    }

    /// A push arrived (`armed` / `departed`): refresh now instead of waiting for the next poll.
    func handlePush(_ event: SpotPassPushEvent) async {
        switch event.kind {
        case .armed, .departed:
            if let id = event.handoffID, let session, id != session.id { return }
            await refresh()
        case .thanks, .handoffEnded:
            // Driver-side kinds. Nothing for the seeker to do.
            break
        }
    }

    /// "Stop waiting": releases the pass locally at once and cancels it server-side. The driver
    /// is never told (spec §3).
    func stopWaiting() async {
        guard phase.isLive, let session else { return }
        transition(to: .ended(.stopped))
        try? await api.cancelHandoff(id: session.id)
    }

    /// Auto-end when the seeker parks (spec §3). Only open/armed passes end: a `departed` pass is
    /// the success case and still owes the "Got it, thanks!" confirm. Returns true if it ended one.
    @discardableResult
    func endBecauseSeekerParked() async -> Bool {
        await autoEnd(reason: .parked)
    }

    /// Auto-end when drive mode ends (spec §3). Same rule as parking.
    @discardableResult
    func endBecauseDriveEnded() async -> Bool {
        await autoEnd(reason: .driveEnded)
    }

    /// "Got it, thanks!" / "Didn't work out". On success the phase becomes `.settled` with the
    /// server-confirmed karma change; on failure the seeker stays on the outcome screen and can retry.
    func confirmOutcome(_ outcome: SpotPassOutcome) async {
        guard phase == .departed, let session, !isSubmittingOutcome else { return }
        isSubmittingOutcome = true
        outcomeSubmitFailed = false
        defer { isSubmittingOutcome = false }

        let result: SpotPassConfirmResult
        do {
            result = try await api.confirmHandoffOutcome(id: session.id, outcome: outcome)
        } catch {
            outcomeSubmitFailed = true
            return
        }
        // `ok: false` = the server did not accept it (state moved on). Keep the buttons so the
        // seeker can retry; the next poll shows the real state.
        guard result.ok else {
            outcomeSubmitFailed = true
            return
        }
        // Karma shown is what the server actually granted (`seeker_points`; caps and pair
        // cooldowns can make it 0), never a nominal promise.
        if let refreshed = try? await api.fetchKarma() { karma = refreshed }
        if outcome == .gotSpot { feedback.success() }
        transition(to: .settled(outcome, karmaDelta: result.seekerPoints > 0 ? result.seekerPoints : nil))
    }

    /// The first name the "Show my first name" toggle would use, or nil when there is none (the
    /// toggle is then disabled: design F12). Mirrors the server's rule.
    func loadFirstName() async -> String? {
        let username = try? await api.fetchUsername()
        return SpotPassNameFilter.firstName(fromUsername: username ?? nil)
    }

    /// Clears a terminal pass so the next entry starts fresh ("Make a new pass").
    func reset() {
        guard !phase.isLive else { return }
        stopPolling()
        session = nil
        snapshot = nil
        outcomeSubmitFailed = false
        phase = .idle
        persistence.clear()
        SpotPassQRImageCache.clear()
    }

    // MARK: - Polling

    func startPollingIfNeeded() {
        guard pollTask == nil, SpotPassSeekerStore.pollInterval(for: phase) != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let interval = SpotPassSeekerStore.pollInterval(for: self.phase) else { break }
                await self.sleep(interval)
                if Task.isCancelled { break }
                await self.refresh()
            }
            self?.pollTask = nil
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Transitions

    private func autoEnd(reason: SpotPassEndReason) async -> Bool {
        guard phase.isCancellable, let session else { return false }
        transition(to: .ended(reason))
        try? await api.cancelHandoff(id: session.id)
        return true
    }

    private func apply(_ latest: SpotPassSnapshot) {
        snapshot = latest
        let next = SpotPassReducer.next(from: phase, snapshot: latest, now: now())
        transition(to: next)
    }

    private func transition(to next: SpotPassPhase) {
        let previous = phase
        guard next != previous else { return }
        phase = next

        switch next {
        case .armed where previous == .open:
            // The seeker is holding the phone out of a window and cannot see the screen (F2).
            feedback.success()
            if let leaveAt = snapshot?.leaveAt {
                let band = SpotPassCountdown.band(leaveAt: leaveAt, expiresAt: snapshot?.expiresAt, now: now())
                feedback.announce("A neighbor scanned. \(band.spokenLine)")
            } else {
                feedback.announce("A neighbor scanned.")
            }
        case .departed:
            feedback.success()
            feedback.announce("Spot opening up. Your neighbor is pulling out now.")
        default:
            break
        }

        if next.isLive == false { finishTerminal() }
    }

    /// A terminal phase: stop polling and forget the persisted pass (its token is dead).
    private func finishTerminal() {
        stopPolling()
        persistence.clear()
        SpotPassQRImageCache.clear()
    }
}
