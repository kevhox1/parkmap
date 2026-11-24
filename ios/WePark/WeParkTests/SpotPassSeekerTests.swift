//
//  SpotPassSeekerTests.swift
//  Spot Pass C1 (docs/specs/qr-spot-handoff.md §3, §8, §9, §10, §14;
//  docs/design/spot-pass-design.md §1.5, §2, §9): the seeker flow's pure logic and store, against
//  `FakeSpotPassAPI` only. No network, no haptics, no real notification center.
//
//  Groups:
//    1. Countdown banding + TTL formatting
//    2. State machine (SpotPassReducer)
//    3. Seeker store flows (fake API)
//    4. QR: URL budget, generation, CIDetector round trip, quiet zone
//    5. Wire decoding + request building
//    6. Notification category merge
//    7. Push parsing + router inertness
//    8. More-sheet row visibility (flag off = hidden)
//    9. Copy lint, karma buckets, glyphs, name filter, preferences, brightness policy
//

import XCTest
import CoreImage
import UserNotifications
import SwiftUI
@testable import WePark

// MARK: - 1. Countdown

final class SpotPassCountdownTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func band(minutesToLeave: Double, graceExpires: Bool = false) -> SpotPassBand {
        let leaveAt = t0.addingTimeInterval(minutesToLeave * 60)
        return SpotPassCountdown.band(leaveAt: leaveAt, expiresAt: nil, now: t0)
    }

    func testBand_moreThanFiftyFive_isAboutAnHour() {
        XCTAssertEqual(band(minutesToLeave: 90), .aboutAnHour)
        XCTAssertEqual(band(minutesToLeave: 55.5), .aboutAnHour)
    }

    func testBand_fortyFiveToFiftyFive_isAboutFifty() {
        XCTAssertEqual(band(minutesToLeave: 55), .about(minutes: 50))
        XCTAssertEqual(band(minutesToLeave: 50), .about(minutes: 50))
        XCTAssertEqual(band(minutesToLeave: 45), .about(minutes: 50))
    }

    func testBand_roundsToNearestFiveAboveTen() {
        XCTAssertEqual(band(minutesToLeave: 30), .about(minutes: 30))
        XCTAssertEqual(band(minutesToLeave: 32), .about(minutes: 30))
        XCTAssertEqual(band(minutesToLeave: 33), .about(minutes: 35))
        XCTAssertEqual(band(minutesToLeave: 12), .about(minutes: 10))
        XCTAssertEqual(band(minutesToLeave: 13), .about(minutes: 15))
        XCTAssertEqual(band(minutesToLeave: 44), .about(minutes: 45))
    }

    func testBand_tenToFive_isAboutTen() {
        XCTAssertEqual(band(minutesToLeave: 10), .about(minutes: 10))
        XCTAssertEqual(band(minutesToLeave: 7), .about(minutes: 10))
        XCTAssertEqual(band(minutesToLeave: 5.5), .about(minutes: 10))
    }

    func testBand_fiveOrLess_isAnyMinuteNow() {
        XCTAssertEqual(band(minutesToLeave: 5), .anyMinuteNow)
        XCTAssertEqual(band(minutesToLeave: 1), .anyMinuteNow)
        XCTAssertEqual(band(minutesToLeave: 0.1), .anyMinuteNow)
    }

    func testBand_afterLeaveAtWithinGrace_isShouldBeHeadingOut_notLate() {
        let leaveAt = t0.addingTimeInterval(-5 * 60)
        let result = SpotPassCountdown.band(leaveAt: leaveAt, expiresAt: nil, now: t0)
        XCTAssertEqual(result, .shouldBeHeadingOut)
        XCTAssertEqual(result.line, "Should be heading out soon.")
        XCTAssertFalse(result.line.lowercased().contains("late"))
        XCTAssertFalse(result.line.lowercased().contains("delay"))
    }

    func testBand_afterGrace_isEnded_usingLeaveAtPlusFifteen() {
        let leaveAt = t0.addingTimeInterval(-15 * 60)
        XCTAssertEqual(SpotPassCountdown.band(leaveAt: leaveAt, expiresAt: nil, now: t0), .ended)
        let justBefore = t0.addingTimeInterval(-14.9 * 60)
        XCTAssertEqual(SpotPassCountdown.band(leaveAt: justBefore, expiresAt: nil, now: t0), .shouldBeHeadingOut)
    }

    func testBand_prefersServerExpiresAt() {
        let leaveAt = t0.addingTimeInterval(-20 * 60)
        let extended = t0.addingTimeInterval(5 * 60)
        XCTAssertEqual(SpotPassCountdown.band(leaveAt: leaveAt, expiresAt: extended, now: t0), .shouldBeHeadingOut)
    }

    func testBandLines_exactCopy_andNeverAClockTime() {
        XCTAssertEqual(SpotPassBand.aboutAnHour.line, "Leaving in about an hour.")
        XCTAssertEqual(SpotPassBand.about(minutes: 30).line, "Leaving in about 30 min.")
        XCTAssertEqual(SpotPassBand.anyMinuteNow.line, "Leaving any minute now.")
        let bands: [SpotPassBand] = [
            .aboutAnHour, .about(minutes: 10), .about(minutes: 30), .about(minutes: 50),
            .anyMinuteNow, .shouldBeHeadingOut, .ended
        ]
        for item in bands {
            // Safety (spec §9 item 2, design F4): no "h:mm" / "mm:ss" and no am/pm in any seeker line.
            XCTAssertNil(item.line.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression), item.line)
            XCTAssertNil(item.spokenLine.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression), item.spokenLine)
            XCTAssertFalse(item.line.lowercased().contains("am") && item.line.lowercased().contains("pm"))
        }
    }

    func testTTLClockString_floorsAndNeverNegative() {
        XCTAssertEqual(SpotPassCountdown.clockString(19 * 60 + 42.9), "19:42")
        XCTAssertEqual(SpotPassCountdown.clockString(72), "1:12")
        XCTAssertEqual(SpotPassCountdown.clockString(-5), "0:00")
    }

    func testTTLSpokenString() {
        XCTAssertEqual(SpotPassCountdown.spokenString(19 * 60 + 42), "19 minutes 42 seconds")
        XCTAssertEqual(SpotPassCountdown.spokenString(61), "1 minute 1 second")
        XCTAssertEqual(SpotPassCountdown.spokenString(45), "45 seconds")
    }

    func testIsEnding_underTwoMinutes() {
        XCTAssertTrue(SpotPassCountdown.isEnding(119))
        XCTAssertFalse(SpotPassCountdown.isEnding(120))
    }

    func testSafeRange_neverTraps() {
        let later = t0.addingTimeInterval(100)
        let range = SpotPassCountdown.safeRange(from: later, to: t0)
        XCTAssertEqual(range.lowerBound, range.upperBound)
    }
}

// MARK: - 2. Reducer

final class SpotPassReducerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func next(_ phase: SpotPassPhase, _ snapshot: SpotPassSnapshot, at now: Date? = nil) -> SpotPassPhase {
        SpotPassReducer.next(from: phase, snapshot: snapshot, now: now ?? t0)
    }

    func testCreated_staysOpen() {
        XCTAssertEqual(next(.open, SpotPassSnapshot(status: .created, expiresAt: t0.addingTimeInterval(600))), .open)
    }

    func testCreated_pastExpiry_endsExpired() {
        XCTAssertEqual(next(.open, SpotPassSnapshot(status: .created, expiresAt: t0.addingTimeInterval(-1))), .ended(.expired))
    }

    func testOpenToArmed() {
        let armed = SpotPassSnapshot(status: .armed, leaveAt: t0.addingTimeInterval(1800), expiresAt: t0.addingTimeInterval(2700))
        XCTAssertEqual(next(.open, armed), .armed)
    }

    func testOpenToDeparted_skippingArmed() {
        XCTAssertEqual(next(.open, SpotPassSnapshot(status: .departed, departedAt: t0)), .departed)
    }

    func testArmedToDeparted() {
        XCTAssertEqual(next(.armed, SpotPassSnapshot(status: .departed, departedAt: t0)), .departed)
    }

    func testStaleSnapshots_neverRegress() {
        let armed = SpotPassSnapshot(status: .armed, leaveAt: t0.addingTimeInterval(600), expiresAt: t0.addingTimeInterval(1500))
        XCTAssertEqual(next(.departed, armed), .departed)
        XCTAssertEqual(next(.armed, SpotPassSnapshot(status: .created, expiresAt: t0.addingTimeInterval(600))), .armed)
        XCTAssertEqual(next(.departed, SpotPassSnapshot(status: .created)), .departed)
    }

    func testArmed_pastEnd_endsExpired() {
        let leaveAt = t0.addingTimeInterval(-16 * 60)
        XCTAssertEqual(next(.armed, SpotPassSnapshot(status: .armed, leaveAt: leaveAt)), .ended(.expired))
    }

    func testDriverCancelAndExpiry_areIndistinguishable() {
        XCTAssertEqual(next(.armed, SpotPassSnapshot(status: .cancelled)), .ended(.expired))
        XCTAssertEqual(next(.open, SpotPassSnapshot(status: .expired)), .ended(.expired))
    }

    func testSuspended_endsPaused() {
        XCTAssertEqual(next(.open, SpotPassSnapshot(status: .suspended)), .ended(.suspended))
    }

    func testDeparted_autoEndsAfterThirtyMinutesWithNoChoice() {
        let departedAt = t0.addingTimeInterval(-31 * 60)
        XCTAssertEqual(next(.departed, SpotPassSnapshot(status: .departed, departedAt: departedAt)), .ended(.expired))
        let recent = t0.addingTimeInterval(-29 * 60)
        XCTAssertEqual(next(.departed, SpotPassSnapshot(status: .departed, departedAt: recent)), .departed)
    }

    func testOutcomeAlreadyRecorded_showsReceipt() {
        XCTAssertEqual(
            next(.departed, SpotPassSnapshot(status: .departed, departedAt: t0, outcome: .gotSpot)),
            .settled(.gotSpot, karmaDelta: nil)
        )
    }

    func testTerminalPhases_doNotMove() {
        let armed = SpotPassSnapshot(status: .armed, leaveAt: t0.addingTimeInterval(600))
        XCTAssertEqual(next(.ended(.expired), armed), .ended(.expired))
        XCTAssertEqual(next(.settled(.noLuck, karmaDelta: nil), armed), .settled(.noLuck, karmaDelta: nil))
        XCTAssertEqual(next(.idle, armed), .idle)
        XCTAssertEqual(next(.creating, armed), .creating)
    }

    func testPhaseFlags() {
        XCTAssertTrue(SpotPassPhase.open.isLive)
        XCTAssertTrue(SpotPassPhase.departed.isLive)
        XCTAssertFalse(SpotPassPhase.ended(.expired).isLive)
        XCTAssertTrue(SpotPassPhase.armed.isCancellable)
        XCTAssertFalse(SpotPassPhase.departed.isCancellable)
        XCTAssertTrue(SpotPassEndReason.stopped.closesFlow)
        XCTAssertTrue(SpotPassEndReason.parked.closesFlow)
        XCTAssertFalse(SpotPassEndReason.expired.closesFlow)
        XCTAssertFalse(SpotPassEndReason.suspended.closesFlow)
    }
}

// MARK: - 3. Store (fake API)

@MainActor
final class SpotPassSeekerStoreTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore(
        api: FakeSpotPassAPI,
        persistence: InMemorySpotPassPersistence? = nil,
        feedback: RecordingSpotPassFeedback? = nil
    ) -> SpotPassSeekerStore {
        let store = SpotPassSeekerStore(
            api: api,
            persistence: persistence ?? InMemorySpotPassPersistence(),
            feedback: feedback ?? RecordingSpotPassFeedback(),
            now: { [unowned self] in self.clock },
            // Never fires during a test: polling is exercised by calling `refresh()` directly.
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )
        addTeardownBlock { @MainActor in store.stopPolling() }
        return store
    }

    private func session(displayName: String? = nil) -> SpotPassSession {
        FakeSpotPassAPI.sampleSession(displayName: displayName, now: t0)
    }

    private func armedSnapshot(minutes: Double = 30) -> SpotPassSnapshot {
        let leaveAt = t0.addingTimeInterval(minutes * 60)
        return SpotPassSnapshot(status: .armed, leaveAt: leaveAt, expiresAt: leaveAt.addingTimeInterval(15 * 60))
    }

    // MARK: create

    func testCreate_success_opensAndPersists_andLoadsKarma() async {
        let api = FakeSpotPassAPI(
            createResult: .success(session()),
            karmaResult: .success(SpotPassKarma(reputation: 5, helpedCount: 12))
        )
        let persistence = InMemorySpotPassPersistence()
        let store = makeStore(api: api, persistence: persistence)

        await store.createPass(showName: false)

        XCTAssertEqual(store.phase, .open)
        XCTAssertEqual(api.createCalls, [false])
        XCTAssertEqual(persistence.stored?.id, session().id)
        XCTAssertEqual(store.karmaBucketLabel, "Helped 10+")
        XCTAssertEqual(store.expiresAt, t0.addingTimeInterval(20 * 60))
    }

    func testCreate_offline_failsWithOffline_andPersistsNothing() async {
        let api = FakeSpotPassAPI(createResult: .failure(SpotPassAPIError.offline))
        let persistence = InMemorySpotPassPersistence()
        let store = makeStore(api: api, persistence: persistence)
        await store.createPass(showName: false)
        XCTAssertEqual(store.phase, .createFailed(.offline))
        XCTAssertNil(persistence.stored)
    }

    func testCreate_otherError_isGeneric() async {
        let api = FakeSpotPassAPI(createResult: .failure(SpotPassAPIError.rejected(statusCode: 500)))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        XCTAssertEqual(store.phase, .createFailed(.generic))
    }

    func testCreate_whenAlreadyLive_isNoOp() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        await store.createPass(showName: false)
        XCTAssertEqual(api.createCalls.count, 1)
    }

    func testCreate_showNameOn_usesLocalNameWhenServerDoesNotEcho() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: true, localDisplayName: "Maya")
        XCTAssertEqual(api.createCalls, [true])
        XCTAssertEqual(store.session?.shownName, "Maya")
        XCTAssertEqual(store.session?.alias, "Bodega Cat")
    }

    func testCreate_showNameOff_showsAlias() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false, localDisplayName: "Maya")
        XCTAssertEqual(store.session?.shownName, "Bodega Cat")
    }

    func testCreate_serverEchoedName_wins() async {
        let api = FakeSpotPassAPI(createResult: .success(session(displayName: "Sam")))
        let store = makeStore(api: api)
        await store.createPass(showName: true, localDisplayName: "Maya")
        XCTAssertEqual(store.session?.shownName, "Sam")
    }

    // MARK: states + haptic

    func testScanned_armsOnce_withSuccessHapticAndAnnouncement() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let feedback = RecordingSpotPassFeedback()
        let store = makeStore(api: api, feedback: feedback)
        await store.createPass(showName: false)

        api.statusResult = .success(armedSnapshot())
        await store.refresh()
        XCTAssertEqual(store.phase, .armed)
        XCTAssertEqual(feedback.successCount, 1)
        XCTAssertEqual(feedback.announcements, ["A neighbor scanned. Leaving in about 30 minutes."])
        XCTAssertEqual(store.leaveAt, t0.addingTimeInterval(30 * 60))

        await store.refresh()
        XCTAssertEqual(feedback.successCount, 1, "A repeat poll must not buzz again")
    }

    func testDeparted_firesSuccessHaptic() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let feedback = RecordingSpotPassFeedback()
        let store = makeStore(api: api, feedback: feedback)
        await store.createPass(showName: false)

        api.statusResult = .success(SpotPassSnapshot(status: .departed, departedAt: t0))
        await store.refresh()
        XCTAssertEqual(store.phase, .departed)
        XCTAssertEqual(feedback.successCount, 1)
        XCTAssertEqual(feedback.announcements.last, "Spot opening up. Your neighbor is pulling out now.")
    }

    func testRefresh_rowGone_endsExpired_andClearsPersistence() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let persistence = InMemorySpotPassPersistence()
        let store = makeStore(api: api, persistence: persistence)
        await store.createPass(showName: false)

        api.statusResult = .failure(SpotPassAPIError.notFound)
        await store.refresh()
        XCTAssertEqual(store.phase, .ended(.expired))
        XCTAssertNil(persistence.stored)
    }

    func testRefresh_offline_keepsPhase_butClockStillExpires() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)

        api.statusResult = .failure(SpotPassAPIError.offline)
        await store.refresh()
        XCTAssertEqual(store.phase, .open)

        clock = t0.addingTimeInterval(21 * 60)
        await store.refresh()
        XCTAssertEqual(store.phase, .ended(.expired))
    }

    func testDriverCancel_readsAsPassEnded_withNoReason() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        api.statusResult = .success(armedSnapshot())
        await store.refresh()

        api.statusResult = .success(SpotPassSnapshot(status: .cancelled))
        await store.refresh()
        XCTAssertEqual(store.phase, .ended(.expired))
    }

    func testSuspended_endsPaused() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        api.statusResult = .success(SpotPassSnapshot(status: .suspended))
        await store.refresh()
        XCTAssertEqual(store.phase, .ended(.suspended))
    }

    // MARK: stop + auto-end

    func testStopWaiting_endsLocally_cancelsServer_clearsPersistence() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let persistence = InMemorySpotPassPersistence()
        let store = makeStore(api: api, persistence: persistence)
        await store.createPass(showName: false)

        await store.stopWaiting()
        XCTAssertEqual(store.phase, .ended(.stopped))
        XCTAssertEqual(api.cancelledIDs, [session().id])
        XCTAssertNil(persistence.stored)
    }

    func testParking_endsOpenPass_andReportsIt() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        let ended = await store.endBecauseSeekerParked()
        XCTAssertTrue(ended)
        XCTAssertEqual(store.phase, .ended(.parked))
        XCTAssertEqual(api.cancelledIDs.count, 1)
    }

    func testDriveEnd_endsArmedPass() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        api.statusResult = .success(armedSnapshot())
        await store.refresh()
        let ended = await store.endBecauseDriveEnded()
        XCTAssertTrue(ended)
        XCTAssertEqual(store.phase, .ended(.driveEnded))
    }

    func testParking_doesNotEndDepartedPass_theSuccessCase() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        api.statusResult = .success(SpotPassSnapshot(status: .departed, departedAt: t0))
        await store.refresh()

        let ended = await store.endBecauseSeekerParked()
        XCTAssertFalse(ended)
        XCTAssertEqual(store.phase, .departed)
        XCTAssertTrue(api.cancelledIDs.isEmpty)
    }

    func testAutoEnd_withNoPass_isNoOp() async {
        let store = makeStore(api: FakeSpotPassAPI())
        let ended = await store.endBecauseSeekerParked()
        XCTAssertFalse(ended)
        XCTAssertEqual(store.phase, .idle)
    }

    // MARK: outcome + karma

    private func departedStore(api: FakeSpotPassAPI, feedback: RecordingSpotPassFeedback? = nil) async -> SpotPassSeekerStore {
        let store = makeStore(api: api, feedback: feedback)
        await store.createPass(showName: false)
        api.statusResult = .success(SpotPassSnapshot(status: .departed, departedAt: t0))
        await store.refresh()
        return store
    }

    func testGotIt_settlesWithServerConfirmedKarmaDelta() async {
        let api = FakeSpotPassAPI(
            createResult: .success(session()),
            karmaResult: .success(SpotPassKarma(reputation: 5, helpedCount: 2))
        )
        api.confirmResult = .success(SpotPassConfirmResult(ok: true, seekerPoints: 3))
        let feedback = RecordingSpotPassFeedback()
        let store = await departedStore(api: api, feedback: feedback)

        await store.confirmOutcome(.gotSpot)
        XCTAssertEqual(store.phase, .settled(.gotSpot, karmaDelta: 3))
        XCTAssertEqual(api.confirmations.map(\.outcome), [.gotSpot])
        XCTAssertEqual(api.confirmations.map(\.id), [session().id])
        XCTAssertEqual(feedback.successCount, 2, "departed + got-it")
    }

    func testGotIt_whenServerAwardedNothing_showsNoKarma() async {
        let api = FakeSpotPassAPI(createResult: .success(session()), karmaResult: .success(SpotPassKarma(reputation: 5, helpedCount: 2)))
        // seeker_points 0: caps / pair cooldown awarded nothing.
        api.confirmResult = .success(SpotPassConfirmResult(ok: true, seekerPoints: 0))
        let store = await departedStore(api: api)
        await store.confirmOutcome(.gotSpot)
        XCTAssertEqual(store.phase, .settled(.gotSpot, karmaDelta: nil))
    }

    func testDidntWorkOut_settlesNoLuck_noSuccessHaptic() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let feedback = RecordingSpotPassFeedback()
        let store = await departedStore(api: api, feedback: feedback)
        await store.confirmOutcome(.noLuck)
        XCTAssertEqual(store.phase, .settled(.noLuck, karmaDelta: nil))
        XCTAssertEqual(api.confirmations.map(\.outcome), [.noLuck])
        XCTAssertEqual(feedback.successCount, 1, "only the departed haptic")
    }

    func testConfirmFailure_staysDeparted_andCanRetry() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = await departedStore(api: api)
        api.confirmResult = .failure(SpotPassAPIError.offline)

        await store.confirmOutcome(.gotSpot)
        XCTAssertEqual(store.phase, .departed)
        XCTAssertTrue(store.outcomeSubmitFailed)
        XCTAssertFalse(store.isSubmittingOutcome)

        api.confirmResult = .success(SpotPassConfirmResult(ok: true, seekerPoints: 0))
        await store.confirmOutcome(.gotSpot)
        XCTAssertEqual(store.phase, .settled(.gotSpot, karmaDelta: nil))
        XCTAssertFalse(store.outcomeSubmitFailed)
    }

    func testConfirm_serverNotOk_staysDeparted_andCanRetry() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = await departedStore(api: api)
        api.confirmResult = .success(SpotPassConfirmResult(ok: false, seekerPoints: 0))
        await store.confirmOutcome(.gotSpot)
        XCTAssertEqual(store.phase, .departed)
        XCTAssertTrue(store.outcomeSubmitFailed)
    }

    func testConfirm_outsideDeparted_isIgnored() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        await store.confirmOutcome(.gotSpot)
        XCTAssertTrue(api.confirmations.isEmpty)
        XCTAssertEqual(store.phase, .open)
    }

    // MARK: restore

    func testRestore_liveSession_comesBack_andRefreshes() async {
        let api = FakeSpotPassAPI(statusResult: .success(armedSnapshot()))
        let persistence = InMemorySpotPassPersistence(stored: session())
        let store = makeStore(api: api, persistence: persistence)
        await store.restoreIfNeeded()
        XCTAssertEqual(store.phase, .armed)
        XCTAssertEqual(store.session?.id, session().id)
    }

    func testRestore_expiredWhileClosed_isForgottenQuietly() async {
        let api = FakeSpotPassAPI()
        let persistence = InMemorySpotPassPersistence(stored: session())
        clock = t0.addingTimeInterval(60 * 60)
        let store = makeStore(api: api, persistence: persistence)
        await store.restoreIfNeeded()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.session)
        XCTAssertNil(persistence.stored)
        XCTAssertEqual(api.statusCallCount, 0, "dead on arrival needs no network")
    }

    func testRestore_nothingSaved_staysIdle() async {
        let store = makeStore(api: FakeSpotPassAPI())
        await store.restoreIfNeeded()
        XCTAssertEqual(store.phase, .idle)
    }

    // MARK: push

    func testPush_armed_triggersRefresh() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        api.statusResult = .success(armedSnapshot())
        await store.handlePush(SpotPassPushEvent(kind: .armed, handoffID: nil, opened: false))
        XCTAssertEqual(store.phase, .armed)
    }

    func testPush_forAnotherPass_isIgnored() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        api.statusResult = .success(armedSnapshot())
        let other = UUID(uuidString: "99999999-9999-9999-9999-999999999999")
        await store.handlePush(SpotPassPushEvent(kind: .armed, handoffID: other, opened: false))
        XCTAssertEqual(store.phase, .open)
    }

    func testPush_driverKinds_doNothing() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        let before = api.statusCallCount
        await store.handlePush(SpotPassPushEvent(kind: .thanks, handoffID: nil, opened: false))
        await store.handlePush(SpotPassPushEvent(kind: .handoffEnded, handoffID: nil, opened: false))
        XCTAssertEqual(api.statusCallCount, before)
    }

    // MARK: reset

    func testReset_afterTerminal_returnsToIdle() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        await store.stopWaiting()
        store.reset()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.session)
    }

    func testReset_whileLive_isIgnored() async {
        let api = FakeSpotPassAPI(createResult: .success(session()))
        let store = makeStore(api: api)
        await store.createPass(showName: false)
        store.reset()
        XCTAssertEqual(store.phase, .open)
    }

    // MARK: polling cadence

    func testPollInterval_perPhase() {
        XCTAssertEqual(SpotPassSeekerStore.pollInterval(for: .open), 4)
        XCTAssertEqual(SpotPassSeekerStore.pollInterval(for: .armed), 15)
        XCTAssertEqual(SpotPassSeekerStore.pollInterval(for: .departed), 30)
        XCTAssertNil(SpotPassSeekerStore.pollInterval(for: .idle))
        XCTAssertNil(SpotPassSeekerStore.pollInterval(for: .settled(.gotSpot, karmaDelta: nil)))
        XCTAssertNil(SpotPassSeekerStore.pollInterval(for: .ended(.expired)))
    }
}

// MARK: - 4. QR

@MainActor
final class SpotPassQRTests: XCTestCase {

    private let token = "AbCdEfGhIjKlMnOpQrSt_-"

    private func decode(_ image: UIImage) -> String? {
        guard let cgImage = image.cgImage else { return nil }
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: CIImage(cgImage: cgImage)) ?? []
        return (features.first as? CIQRCodeFeature)?.messageString
    }

    func testURL_isExactlyTheContractShape_andWithinTheByteBudget() throws {
        let urlString = try XCTUnwrap(SpotPassQR.urlString(token: token))
        XCTAssertEqual(urlString, "https://getwepark.com/p#t=\(token)")
        XCTAssertEqual(urlString.utf8.count, 48)
        XCTAssertLessThanOrEqual(urlString.utf8.count, SpotPassQR.urlByteBudget)
        XCTAssertEqual(SpotPassQR.urlByteBudget, 62)
    }

    func testURL_parsesBackToTheSameTokenViaTheC0Parser() throws {
        let url = try XCTUnwrap(SpotPassQR.url(token: token))
        XCTAssertEqual(SpotPassLink(url: url)?.token, token)
    }

    func testURL_rejectsMalformedTokens() {
        XCTAssertNil(SpotPassQR.urlString(token: "short"))
        XCTAssertNil(SpotPassQR.urlString(token: token + "x"))
        XCTAssertNil(SpotPassQR.urlString(token: "AbCdEfGhIjKlMnOpQrS!_-"))
    }

    func testMatrix_isVersion4_33Modules() throws {
        let urlString = try XCTUnwrap(SpotPassQR.urlString(token: token))
        let matrix = try XCTUnwrap(SpotPassQR.matrix(for: urlString))
        XCTAssertEqual(matrix.size, SpotPassQR.expectedModuleCount)
        XCTAssertEqual(matrix.modules.count, 33 * 33)
        // Finder pattern corners are dark.
        XCTAssertTrue(matrix.isDark(row: 0, col: 0))
        XCTAssertTrue(matrix.isDark(row: 0, col: 32))
        XCTAssertTrue(matrix.isDark(row: 32, col: 0))
    }

    func testPlateGeometry_is328pt_withFourModuleQuietZone() {
        XCTAssertEqual(SpotPassQRRenderer.plateSide(moduleCount: 33), 328)
        XCTAssertEqual(SpotPassQR.moduleSizePoints, 8)
        XCTAssertEqual(SpotPassQR.quietZoneModules, 4)
    }

    func testBrandedRender_decodesBackToTheURL() throws {
        let urlString = try XCTUnwrap(SpotPassQR.urlString(token: token))
        let matrix = try XCTUnwrap(SpotPassQR.matrix(for: urlString))
        let image = SpotPassQRRenderer.image(for: matrix, scale: 3, centerMark: true)
        XCTAssertEqual(image.size.width, 328)
        XCTAssertEqual(image.cgImage?.width, 984, "24 px modules at 3x: an integer pixel multiple")
        XCTAssertEqual(decode(image), urlString)
    }

    func testBrandedRender_withoutCenterMark_alsoDecodes() throws {
        let urlString = try XCTUnwrap(SpotPassQR.urlString(token: token))
        let matrix = try XCTUnwrap(SpotPassQR.matrix(for: urlString))
        let image = SpotPassQRRenderer.image(for: matrix, scale: 3, centerMark: false)
        XCTAssertEqual(decode(image), urlString)
    }

    func testBrandedRender_decodesAt2x() throws {
        let urlString = try XCTUnwrap(SpotPassQR.urlString(token: token))
        let matrix = try XCTUnwrap(SpotPassQR.matrix(for: urlString))
        let image = SpotPassQRRenderer.image(for: matrix, scale: 2, centerMark: true)
        XCTAssertEqual(decode(image), urlString)
    }

    func testQuietZone_isPureWhite() throws {
        let urlString = try XCTUnwrap(SpotPassQR.urlString(token: token))
        let matrix = try XCTUnwrap(SpotPassQR.matrix(for: urlString))
        let image = SpotPassQRRenderer.image(for: matrix, scale: 1, centerMark: true)
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drew: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drew)
        let quiet = SpotPassQR.quietZoneModules * Int(SpotPassQR.moduleSizePoints)
        var nonWhite = 0
        for row in 0..<height {
            for col in 0..<width where row < quiet || row >= height - quiet || col < quiet || col >= width - quiet {
                if pixels[row * width + col] != 255 { nonWhite += 1 }
            }
        }
        XCTAssertEqual(nonWhite, 0, "nothing may be drawn inside the quiet zone")
    }

    func testImageCache_returnsSameImageForSameKey() {
        SpotPassQRImageCache.clear()
        let first = SpotPassQRImageCache.image(token: token, scale: 3)
        let second = SpotPassQRImageCache.image(token: token, scale: 3)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertNil(SpotPassQRImageCache.image(token: "bad", scale: 3))
        SpotPassQRImageCache.clear()
    }
}

// MARK: - 5. Wire + requests

@MainActor
final class SpotPassWireTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testDecodeCreated_object() throws {
        let json = """
        {"id":"11111111-2222-3333-4444-555555555555","token":"AbCdEfGhIjKlMnOpQrSt_-","alias":"Bodega Cat","glyph":"cat","expires_at":"2026-11-23T20:15:00.123456+00:00"}
        """
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = try SpotPassWire.decodeCreated(data(json), now: now)
        XCTAssertEqual(session.alias, "Bodega Cat")
        XCTAssertEqual(session.glyph, "cat")
        XCTAssertEqual(session.token, "AbCdEfGhIjKlMnOpQrSt_-")
        XCTAssertEqual(session.createdAt, now)
        XCTAssertNil(session.displayName)
        XCTAssertEqual(session.id, UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    }

    func testDecodeCreated_arrayForm_andEchoedName() throws {
        let json = """
        [{"id":"11111111-2222-3333-4444-555555555555","token":"AbCdEfGhIjKlMnOpQrSt_-","alias":"Stoop Pup","glyph":"dog.fill","expires_at":"2026-11-23T20:15:00Z","display_name":"Maya"}]
        """
        let session = try SpotPassWire.decodeCreated(data(json), now: Date())
        XCTAssertEqual(session.displayName, "Maya")
        XCTAssertEqual(session.shownName, "Maya")
    }

    func testDecodeCreated_rejectsBadTokenOrMissingFields() {
        let badToken = """
        {"id":"11111111-2222-3333-4444-555555555555","token":"nope","alias":"A","glyph":"cat","expires_at":"2026-11-23T20:15:00Z"}
        """
        XCTAssertThrowsError(try SpotPassWire.decodeCreated(data(badToken), now: Date()))
        XCTAssertThrowsError(try SpotPassWire.decodeCreated(data("{}"), now: Date()))
        XCTAssertThrowsError(try SpotPassWire.decodeCreated(data("not json"), now: Date()))
    }

    func testParseDate_formats() {
        let plain = SpotPassWire.parseDate("2026-11-23T20:15:00Z")
        let millis = SpotPassWire.parseDate("2026-11-23T20:15:00.250Z")
        let micros = SpotPassWire.parseDate("2026-11-23T20:15:00.250999+00:00")
        let offset = SpotPassWire.parseDate("2026-11-23T15:15:00-05:00")
        XCTAssertNotNil(plain)
        XCTAssertNotNil(millis)
        XCTAssertNotNil(micros)
        XCTAssertEqual(plain, offset)
        XCTAssertEqual(millis?.timeIntervalSince(plain ?? .distantPast) ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(micros?.timeIntervalSince(plain ?? .distantPast) ?? 0, 0.25, accuracy: 0.001)
        XCTAssertNil(SpotPassWire.parseDate("yesterday"))
    }

    func testDecodeSnapshot_armed() throws {
        let json = """
        [{"status":"armed","leave_at":"2026-11-23T20:30:00+00:00","expires_at":"2026-11-23T20:45:00+00:00","departed_at":null,"outcome":null}]
        """
        let snapshot = try SpotPassWire.decodeSnapshot(data(json))
        XCTAssertEqual(snapshot.status, .armed)
        XCTAssertNotNil(snapshot.leaveAt)
        XCTAssertNotNil(snapshot.expiresAt)
        XCTAssertNil(snapshot.departedAt)
        XCTAssertNil(snapshot.outcome)
    }

    func testDecodeSnapshot_departedWithOutcome() throws {
        let json = #"{"status":"departed","departed_at":"2026-11-23T20:30:00Z","outcome":"got_spot"}"#
        let snapshot = try SpotPassWire.decodeSnapshot(data(json))
        XCTAssertEqual(snapshot.status, .departed)
        XCTAssertEqual(snapshot.outcome, .gotSpot)
    }

    func testDecodeSnapshot_emptyArray_isNotFound() {
        XCTAssertThrowsError(try SpotPassWire.decodeSnapshot(data("[]"))) { error in
            XCTAssertEqual(error as? SpotPassAPIError, .notFound)
        }
    }

    func testDecodeSnapshot_unknownStatus_isMalformed() {
        XCTAssertThrowsError(try SpotPassWire.decodeSnapshot(data(#"[{"status":"weird"}]"#))) { error in
            XCTAssertEqual(error as? SpotPassAPIError, .malformedResponse)
        }
    }

    func testDecodeKarma() throws {
        XCTAssertEqual(
            try SpotPassWire.decodeKarma(data(#"[{"reputation":42,"helped_count":7}]"#)),
            SpotPassKarma(reputation: 42, helpedCount: 7)
        )
        XCTAssertEqual(try SpotPassWire.decodeKarma(data("[]")), .zero)
        XCTAssertEqual(try SpotPassWire.decodeKarma(data("{}")), .zero)
    }

    // MARK: requests

    private let base = URL(string: "https://example.supabase.co")!

    func testRPCRequest_createHandoff_matchesContract() throws {
        let request = try SupabaseSpotPassAPI.rpcRequest(
            baseURL: base, anonKey: "anon", jwt: "jwt", function: "create_handoff", arguments: ["show_name": true]
        )
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/rest/v1/rpc/create_handoff")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Bool]
        XCTAssertEqual(body, ["show_name": true])
    }

    func testRPCRequest_confirm_usesIdAndOutcomeKeys() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let request = try SupabaseSpotPassAPI.rpcRequest(
            baseURL: base, anonKey: "k", jwt: "j", function: "confirm_handoff_outcome",
            arguments: ["id": id.uuidString.lowercased(), "outcome": SpotPassOutcome.gotSpot.rawValue]
        )
        XCTAssertTrue(request.url?.absoluteString.hasSuffix("/rpc/confirm_handoff_outcome") ?? false)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "outcome": "got_spot"])
    }

    func testStatusRequest_readsOnlyTheSeekersOwnRowColumns() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let request = try SupabaseSpotPassAPI.statusRequest(baseURL: base, anonKey: "k", jwt: "j", id: id)
        XCTAssertEqual(request.httpMethod, "GET")
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.path, "/rest/v1/spot_handoffs")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "id" })?.value, "eq.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "select" })?.value,
            "id,status,leave_at,expires_at,departed_at,outcome"
        )
        XCTAssertNil(request.httpBody)
    }

    func testUsernameRequest_readsProfilesUsername() throws {
        let uid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let request = try SupabaseSpotPassAPI.usernameRequest(baseURL: base, anonKey: "k", jwt: "j", userId: uid)
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.path, "/rest/v1/profiles")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "select" })?.value, "username")
    }

    func testKarmaRequest_isTheGetMyHandoffKarmaRPC() throws {
        let request = try SupabaseSpotPassAPI.rpcRequest(
            baseURL: base, anonKey: "k", jwt: "j", function: "get_my_handoff_karma", arguments: [:]
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.absoluteString.hasSuffix("/rest/v1/rpc/get_my_handoff_karma") ?? false)
    }

    func testDecodeKarma_rpcObject() throws {
        let json = #"{"spots_passed":2,"spots_caught":1,"helped_count":12,"reputation":31}"#
        XCTAssertEqual(
            try SpotPassWire.decodeKarma(Data(json.utf8)),
            SpotPassKarma(reputation: 31, helpedCount: 12)
        )
    }

    func testDecodeConfirm() throws {
        let ok = try SpotPassWire.decodeConfirm(Data(#"{"ok":true,"outcome":"got_spot","seeker_points":3}"#.utf8))
        XCTAssertEqual(ok, SpotPassConfirmResult(ok: true, seekerPoints: 3))
        let rejected = try SpotPassWire.decodeConfirm(Data(#"{"ok":false,"outcome":null,"seeker_points":0}"#.utf8))
        XCTAssertEqual(rejected, SpotPassConfirmResult(ok: false, seekerPoints: 0))
        XCTAssertThrowsError(try SpotPassWire.decodeConfirm(Data("{}".utf8)))
    }

    func testDecodeUsername() {
        XCTAssertEqual(SpotPassWire.decodeUsername(Data(#"[{"username":"Maya Smith"}]"#.utf8)), "Maya Smith")
        XCTAssertNil(SpotPassWire.decodeUsername(Data("[]".utf8)))
    }

    func testErrorMapping() {
        XCTAssertEqual(SupabaseSpotPassAPI.map(statusCode: 401), .notSignedIn)
        XCTAssertEqual(SupabaseSpotPassAPI.map(statusCode: 404), .notFound)
        XCTAssertEqual(SupabaseSpotPassAPI.map(statusCode: 500), .rejected(statusCode: 500))
        XCTAssertEqual(SupabaseSpotPassAPI.map(urlError: URLError(.notConnectedToInternet)), .offline)
    }
}

// MARK: - 6. Notification categories (merge-safe)

@MainActor
private final class FakeCategoryCenter: NotificationCategoryCenter {
    var current: Set<UNNotificationCategory>
    private(set) var replaceCount = 0

    init(current: Set<UNNotificationCategory> = []) {
        self.current = current
    }

    func registeredCategories() async -> Set<UNNotificationCategory> { current }

    func replaceCategories(_ categories: Set<UNNotificationCategory>) {
        replaceCount += 1
        current = categories
    }

    var identifiers: Set<String> { Set(current.map(\.identifier)) }
}

@MainActor
final class NotificationCategoryRegistryTests: XCTestCase {

    private func category(_ id: String) -> UNNotificationCategory {
        UNNotificationCategory(identifier: id, actions: [], intentIdentifiers: [], options: [])
    }

    func testMerged_keepsExisting_andAdds() {
        let result = NotificationCategoryRegistry.merged(existing: [category("a")], adding: [category("b")])
        XCTAssertEqual(Set(result.map(\.identifier)), ["a", "b"])
    }

    func testMerged_replacesSameIdentifier() {
        let old = UNNotificationCategory(
            identifier: "a", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "old", options: []
        )
        let new = UNNotificationCategory(
            identifier: "a", actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "new", options: []
        )
        let result = NotificationCategoryRegistry.merged(existing: [old], adding: [new])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.hiddenPreviewsBodyPlaceholder, "new")
    }

    func testLaunchCategories_followTheFlags() {
        XCTAssertTrue(NotificationCategoryRegistry.launchCategories(addressEnabled: false, spotPassEnabled: false).isEmpty)
        let addressOnly = NotificationCategoryRegistry.launchCategories(addressEnabled: true, spotPassEnabled: false)
        XCTAssertEqual(addressOnly.map(\.identifier), [NotificationScheduler.addressCategoryID])
        let spotOnly = NotificationCategoryRegistry.launchCategories(addressEnabled: false, spotPassEnabled: true)
        XCTAssertEqual(spotOnly.map(\.identifier), [NotificationCategoryRegistry.spotPassSeekerCategoryID])
        let both = NotificationCategoryRegistry.launchCategories(addressEnabled: true, spotPassEnabled: true)
        XCTAssertEqual(Set(both.map(\.identifier)), [
            NotificationScheduler.addressCategoryID, NotificationCategoryRegistry.spotPassSeekerCategoryID
        ])
    }

    func testBothFlagsOff_neverTouchesTheCenter() async {
        let center = FakeCategoryCenter(current: [category("existing")])
        await NotificationCategoryRegistry.registerLaunchCategories(addressEnabled: false, spotPassEnabled: false, center: center)
        XCTAssertEqual(center.replaceCount, 0)
        XCTAssertEqual(center.identifiers, ["existing"])
    }

    func testBothFlagsOn_registerTogether_andPreserveForeignCategories() async {
        let center = FakeCategoryCenter(current: [category("someone-elses")])
        await NotificationCategoryRegistry.registerLaunchCategories(addressEnabled: true, spotPassEnabled: true, center: center)
        XCTAssertEqual(center.identifiers, [
            "someone-elses", NotificationScheduler.addressCategoryID, NotificationCategoryRegistry.spotPassSeekerCategoryID
        ])
        XCTAssertEqual(center.replaceCount, 1, "one merge, so neither registration can clobber the other")
    }

    func testSequentialRegistrations_neverClobberEachOther() async {
        let center = FakeCategoryCenter()
        // PR #158's path, then Spot Pass's, then PR #158's again: all survive.
        await NotificationCategoryRegistry.register([NotificationScheduler.addressCategory()], center: center)
        await NotificationCategoryRegistry.register([NotificationCategoryRegistry.spotPassSeekerCategory()], center: center)
        XCTAssertEqual(center.identifiers, [
            NotificationScheduler.addressCategoryID, NotificationCategoryRegistry.spotPassSeekerCategoryID
        ])
        await NotificationCategoryRegistry.register([NotificationScheduler.addressCategory()], center: center)
        XCTAssertEqual(center.identifiers.count, 2)
    }

    func testSeekerCategory_hasNoActions_andHidesPreview() {
        let seeker = NotificationCategoryRegistry.spotPassSeekerCategory()
        XCTAssertEqual(seeker.identifier, "wepark_spot_pass_seeker")
        XCTAssertTrue(seeker.actions.isEmpty)
        XCTAssertEqual(seeker.hiddenPreviewsBodyPlaceholder, "Spot Pass")
    }
}

// MARK: - 7. Push

@MainActor
final class SpotPassPushTests: XCTestCase {

    func testParse_handoffKindKey() {
        let id = "11111111-2222-3333-4444-555555555555"
        let event = SpotPassPushEvent.parse(userInfo: ["handoff_kind": "departed", "handoff_id": id], opened: true)
        XCTAssertEqual(event?.kind, .departed)
        XCTAssertEqual(event?.handoffID, UUID(uuidString: id))
        XCTAssertEqual(event?.opened, true)
    }

    func testParse_kindFallbackKey_andEndedRawValue() {
        XCTAssertEqual(SpotPassPushEvent.parse(userInfo: ["kind": "armed"], opened: false)?.kind, .armed)
        XCTAssertEqual(SpotPassPushEvent.parse(userInfo: ["kind": "handoff_ended"], opened: false)?.kind, .handoffEnded)
    }

    func testParse_ignoresForeignPayloads() {
        XCTAssertNil(SpotPassPushEvent.parse(userInfo: ["pin_type": "sweeper", "zone_id": "z"], opened: false))
        XCTAssertNil(SpotPassPushEvent.parse(userInfo: ["kind": "something_else"], opened: false))
        XCTAssertNil(SpotPassPushEvent.parse(userInfo: [:], opened: false))
    }

    func testRouter_flagOff_isInert_noInbox_noPost() {
        let inbox = SpotPassPushInbox()
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(forName: .spotPassPushReceived, object: nil, queue: nil) { _ in posts += 1 }
        defer { center.removeObserver(token) }

        let handled = SpotPassPushRouter.handle(userInfo: ["kind": "armed"], opened: true, enabled: false, inbox: inbox, center: center)
        XCTAssertFalse(handled)
        XCTAssertNil(inbox.pending)
        XCTAssertEqual(posts, 0)
    }

    func testRouter_realDefault_isInert() {
        let inbox = SpotPassPushInbox()
        XCTAssertFalse(SpotPassPushRouter.handle(userInfo: ["kind": "armed"], opened: true, inbox: inbox))
        XCTAssertNil(inbox.pending)
    }

    func testRouter_flagOn_buffersAndPosts() {
        let inbox = SpotPassPushInbox()
        let center = NotificationCenter()
        var received: SpotPassPushEvent?
        let token = center.addObserver(forName: .spotPassPushReceived, object: nil, queue: nil) { note in
            received = note.object as? SpotPassPushEvent
        }
        defer { center.removeObserver(token) }

        let handled = SpotPassPushRouter.handle(userInfo: ["kind": "departed"], opened: true, enabled: true, inbox: inbox, center: center)
        XCTAssertTrue(handled)
        XCTAssertEqual(inbox.pending?.kind, .departed)
        XCTAssertEqual(received?.kind, .departed)
    }

    func testRouter_flagOn_ignoresNonSpotPassPush() {
        let inbox = SpotPassPushInbox()
        XCTAssertFalse(SpotPassPushRouter.handle(userInfo: ["pin_type": "sweeper"], opened: false, enabled: true, inbox: inbox))
        XCTAssertNil(inbox.pending)
    }
}

// MARK: - 8. More row

final class SpotPassMoreRowTests: XCTestCase {

    func testRow_hiddenWhenFlagOff_everyCombination() {
        for community in [true, false] {
            for replay in [true, false] {
                for car in [true, false] {
                    for palette in [true, false] {
                        let rows = moreMenuVisibleRows(
                            communityEnabled: community,
                            onboardingReplayAvailable: replay,
                            hasParkedCar: car,
                            fullPaletteMode: palette,
                            spotPassEnabled: false
                        )
                        XCTAssertFalse(rows.contains(.spotPass))
                    }
                }
            }
        }
    }

    func testRow_flagOff_listIsByteIdenticalToTheOldOrdering() {
        let rows = moreMenuVisibleRows(
            communityEnabled: true, onboardingReplayAvailable: true, hasParkedCar: true, fullPaletteMode: true
        )
        XCTAssertEqual(rows, [
            .report, .howWeParkWorks, .mapKey, .parking101, .showAllRules, .findMyCar, .parkUntil, .settings
        ])
    }

    @MainActor
    func testRow_hiddenWithTheRealShippedFlag() {
        // Guard: the shipped default hides the row (the flag is false in this PR).
        XCTAssertFalse(AppConstants.spotHandoffEnabled)
        let rows = moreMenuVisibleRows(
            communityEnabled: true, onboardingReplayAvailable: true, hasParkedCar: true, fullPaletteMode: true,
            spotPassEnabled: AppConstants.spotHandoffEnabled
        )
        XCTAssertFalse(rows.contains(.spotPass))
    }

    func testRow_flagOn_sitsDirectlyBelowReport_aboveEverythingElse() {
        let rows = moreMenuVisibleRows(
            communityEnabled: true, onboardingReplayAvailable: true, hasParkedCar: true, fullPaletteMode: true,
            spotPassEnabled: true
        )
        XCTAssertEqual(rows, [
            .report, .spotPass, .howWeParkWorks, .mapKey, .parking101, .showAllRules, .findMyCar, .parkUntil, .settings
        ])
    }

    func testRow_flagOn_isFirstWhenCommunityIsOff() {
        let rows = moreMenuVisibleRows(
            communityEnabled: false, onboardingReplayAvailable: false, hasParkedCar: false, fullPaletteMode: false,
            spotPassEnabled: true
        )
        XCTAssertEqual(rows.first, .spotPass)
    }

    func testRow_content() {
        XCTAssertEqual(MoreMenuRow.spotPass.title, "Spot Pass")
        XCTAssertEqual(MoreMenuRow.spotPass.subtitle, "Ask a neighbor for their spot")
        XCTAssertEqual(MoreMenuRow.spotPass.symbolName, "ticket.fill")
    }
}

// MARK: - 9. Copy, karma, glyph, name, preferences, brightness

final class SpotPassCopyTests: XCTestCase {

    private var allCopy: [String] {
        var strings: [String] = [
            SpotPassCopy.rowTitle, SpotPassCopy.rowSubtitle, SpotPassCopy.signLine1, SpotPassCopy.signLine2,
            SpotPassCopy.armedHeadline, SpotPassCopy.armedFallbackLine, SpotPassCopy.courtesyLine,
            SpotPassCopy.stopWaiting, SpotPassCopy.nightTip, SpotPassCopy.notificationsOffBanner,
            SpotPassCopy.explainerTitle, SpotPassCopy.explainerPosture, SpotPassCopy.showFirstName,
            SpotPassCopy.showFirstNameOff, SpotPassCopy.showFirstNameOn, SpotPassCopy.showFirstNameDisabled,
            SpotPassCopy.createButton, SpotPassCopy.creating, SpotPassCopy.offline, SpotPassCopy.createFailed,
            SpotPassCopy.tryAgain, SpotPassCopy.departedTitle, SpotPassCopy.departedSubtitle,
            SpotPassCopy.departedSafety, SpotPassCopy.gotIt, SpotPassCopy.didntWorkOut,
            SpotPassCopy.outcomeSubmitFailed, SpotPassCopy.thanksTitle, SpotPassCopy.thanksSubtitle,
            SpotPassCopy.noLuckTitle, SpotPassCopy.keepLooking, SpotPassCopy.done, SpotPassCopy.passEnded,
            SpotPassCopy.passPaused, SpotPassCopy.makeNewPass, SpotPassCopy.parkedToast,
            SpotPassCopy.karmaReceipt(3), SpotPassCopy.noLuckKarmaReceipt(1)
        ]
        strings.append(contentsOf: SpotPassCopy.explainerSteps)
        return strings
    }

    func testExactDesignCopy() {
        XCTAssertEqual(SpotPassCopy.signLine1, "Leaving soon?")
        XCTAssertEqual(SpotPassCopy.signLine2, "Scan to pass me your spot.")
        XCTAssertEqual(SpotPassCopy.courtesyLine, "It's a courtesy, not a promise.")
        XCTAssertEqual(SpotPassCopy.departedTitle, "Spot opening up.")
        XCTAssertEqual(SpotPassCopy.departedSubtitle, "Your neighbor is pulling out now.")
        XCTAssertEqual(SpotPassCopy.gotIt, "Got it, thanks!")
        XCTAssertEqual(SpotPassCopy.didntWorkOut, "Didn't work out")
        XCTAssertEqual(SpotPassCopy.thanksTitle, "Thanks, neighbor.")
        XCTAssertEqual(SpotPassCopy.passEnded, "Pass ended.")
        XCTAssertEqual(SpotPassCopy.passPaused, "This Spot Pass has been paused.")
        XCTAssertEqual(SpotPassCopy.karmaReceipt(3), "+3 karma")
    }

    func testVoiceRules_noJargon_noPressureWords_noDollars() {
        let banned = ["ping", "hurry", "last chance", "don't miss", "running out", "grab", "steal", "score",
                      "claim", "token", "free spot", "avoid", "ticket", "fine", "dodge", "evade", "$", "reward", "points"]
        for string in allCopy {
            let lowered = string.lowercased()
            for word in banned {
                XCTAssertFalse(lowered.contains(word), "\"\(string)\" contains \"\(word)\"")
            }
        }
    }

    func testExclamationPoints_onlyOnTheThanksLine() {
        for string in allCopy where string.contains("!") {
            XCTAssertEqual(string, "Got it, thanks!")
        }
    }

    func testNoClockTimesInSeekerCopy() {
        for string in allCopy {
            XCTAssertNil(string.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression), string)
        }
    }
}

final class SpotPassModelTests: XCTestCase {

    func testKarmaBuckets_matchDesign() {
        XCTAssertEqual(SpotPassKarma.bucketLabel(helpedCount: 0), "New neighbor")
        XCTAssertEqual(SpotPassKarma.bucketLabel(helpedCount: 1), "Helped a few")
        XCTAssertEqual(SpotPassKarma.bucketLabel(helpedCount: 9), "Helped a few")
        XCTAssertEqual(SpotPassKarma.bucketLabel(helpedCount: 10), "Helped 10+")
        XCTAssertEqual(SpotPassKarma.bucketLabel(helpedCount: 24), "Helped 10+")
        XCTAssertEqual(SpotPassKarma.bucketLabel(helpedCount: 25), "Helped 25+")
        XCTAssertEqual(SpotPassKarma.bucketLabel(helpedCount: 49), "Helped 25+")
        XCTAssertEqual(SpotPassKarma.bucketLabel(helpedCount: 50), "Helped 50+")
        XCTAssertEqual(SpotPassKarma.bucketLabel(helpedCount: 99), "Helped 50+")
        XCTAssertEqual(SpotPassKarma.bucketLabel(helpedCount: 100), "Helped 100+")
        XCTAssertEqual(SpotPassKarma.bucketLabel(helpedCount: 5000), "Helped 100+")
    }

    func testKarmaBucket_neverLeaksTheExactCount() {
        for count in [1, 7, 13, 31, 77, 123] {
            let label = SpotPassKarma.bucketLabel(helpedCount: count)
            XCTAssertFalse(label.contains("\(count)"), label)
        }
    }

    func testGlyphSymbols() {
        XCTAssertEqual(SpotPassGlyph.symbolName(for: "bodega_cat"), "cat.fill")
        for slug in ["bodega_cat", "stoop_pigeon", "corner_slice", "subway_rat", "fire_escape_fern",
                     "brownstone_bear", "hydrant_hound", "ferry_gull", "rooftop_owl", "egg_cream",
                     "yellow_cab", "bagel_bandit", "metrocard_mouse", "park_squirrel", "bridge_bat", "cart_pretzel"] {
            XCTAssertNotEqual(SpotPassGlyph.symbolName(for: slug), SpotPassGlyph.fallbackSymbol, slug)
        }
        XCTAssertEqual(SpotPassGlyph.symbolName(for: "cat"), "cat.fill")
        XCTAssertEqual(SpotPassGlyph.symbolName(for: "Pup"), "dog.fill")
        XCTAssertEqual(SpotPassGlyph.symbolName(for: "gecko"), "lizard.fill")
        XCTAssertEqual(SpotPassGlyph.symbolName(for: "hare.fill"), "hare.fill")
        XCTAssertEqual(SpotPassGlyph.symbolName(for: "unknown-thing"), SpotPassGlyph.fallbackSymbol)
        XCTAssertEqual(SpotPassGlyph.symbolName(for: ""), SpotPassGlyph.fallbackSymbol)
    }

    func testTintIndex_isStable_andInRange() {
        let id = UUID(uuidString: "07000000-0000-0000-0000-000000000000")!
        XCTAssertEqual(SpotPassGlyph.tintIndex(for: id), 3)
        XCTAssertEqual(SpotPassGlyph.tintIndex(for: id), SpotPassGlyph.tintIndex(for: id))
        for _ in 0..<50 {
            let tint = SpotPassGlyph.tintIndex(for: UUID())
            XCTAssertTrue((0...3).contains(tint))
        }
    }

    func testSession_codableRoundTrip() throws {
        let original = FakeSpotPassAPI.sampleSession(displayName: "Maya", now: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(SpotPassSession.self, from: data), original)
    }

    func testNameFilter() {
        XCTAssertEqual(SpotPassNameFilter.cleaned("Maya"), "Maya")
        XCTAssertEqual(SpotPassNameFilter.cleaned("  Maya Smith "), "Maya", "first name only, never a last name")
        XCTAssertEqual(SpotPassNameFilter.cleaned("Anne-Marie"), "Anne-Marie")
        XCTAssertNil(SpotPassNameFilter.cleaned(nil))
        XCTAssertNil(SpotPassNameFilter.cleaned("   "))
        XCTAssertNil(SpotPassNameFilter.cleaned("Maya99"))
        XCTAssertNil(SpotPassNameFilter.cleaned("Officer Cop"))
        XCTAssertNil(SpotPassNameFilter.cleaned("Police"))
        XCTAssertNil(SpotPassNameFilter.cleaned(String(repeating: "a", count: 21)))
    }
}

@MainActor
final class SpotPassSupportTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "SpotPassSupportTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testPreferences_defaultToThePrivateChoices() {
        let preferences = SpotPassPreferences(defaults: freshDefaults())
        XCTAssertFalse(preferences.showFirstName, "show my first name is OFF by default")
        XCTAssertFalse(preferences.hasSeenExplainer)
        XCTAssertFalse(preferences.nightMode)
    }

    func testPreferences_roundTrip() {
        let defaults = freshDefaults()
        let preferences = SpotPassPreferences(defaults: defaults)
        preferences.showFirstName = true
        preferences.hasSeenExplainer = true
        preferences.nightMode = true
        let again = SpotPassPreferences(defaults: defaults)
        XCTAssertTrue(again.showFirstName)
        XCTAssertTrue(again.hasSeenExplainer)
        XCTAssertTrue(again.nightMode)
    }

    func testPersistence_roundTrip_andClear() {
        let persistence = UserDefaultsSpotPassPersistence(defaults: freshDefaults())
        XCTAssertNil(persistence.load())
        let session = FakeSpotPassAPI.sampleSession(now: Date(timeIntervalSince1970: 1_800_000_000))
        persistence.save(session)
        XCTAssertEqual(persistence.load(), session)
        persistence.clear()
        XCTAssertNil(persistence.load())
    }

    func testFirstName_fromUsername_followsTheServerRule() {
        XCTAssertEqual(SpotPassNameFilter.firstName(fromUsername: "Maya Smith"), "Maya")
        XCTAssertNil(SpotPassNameFilter.firstName(fromUsername: "neighbor-a1b2c3d4"), "auto handles disable the toggle")
        XCTAssertNil(SpotPassNameFilter.firstName(fromUsername: nil))
        XCTAssertNil(SpotPassNameFilter.firstName(fromUsername: "Police"))
    }

    func testStore_loadFirstName() async {
        let api = FakeSpotPassAPI()
        api.usernameResult = .success("Maya Smith")
        let store = SpotPassSeekerStore(
            api: api, persistence: InMemorySpotPassPersistence(), feedback: RecordingSpotPassFeedback()
        )
        let named = await store.loadFirstName()
        XCTAssertEqual(named, "Maya")
        api.usernameResult = .success("neighbor-12345678")
        let auto = await store.loadFirstName()
        XCTAssertNil(auto)
        api.usernameResult = .failure(SpotPassAPIError.offline)
        let failed = await store.loadFirstName()
        XCTAssertNil(failed)
    }

    func testBrightnessPolicy() {
        XCTAssertEqual(SpotPassBrightnessPolicy.target(night: false), 1.0)
        XCTAssertEqual(SpotPassBrightnessPolicy.target(night: true), 0.7)
        XCTAssertTrue(SpotPassBrightnessPolicy.shouldBoost(phase: .open, isSceneActive: true))
        XCTAssertFalse(SpotPassBrightnessPolicy.shouldBoost(phase: .open, isSceneActive: false), "backgrounded: restore")
        XCTAssertFalse(SpotPassBrightnessPolicy.shouldBoost(phase: .armed, isSceneActive: true), "armed: restore")
        XCTAssertFalse(SpotPassBrightnessPolicy.shouldBoost(phase: .departed, isSceneActive: true))
        XCTAssertFalse(SpotPassBrightnessPolicy.shouldBoost(phase: .ended(.expired), isSceneActive: true))
        XCTAssertFalse(SpotPassBrightnessPolicy.shouldBoost(phase: .idle, isSceneActive: true))
    }

    func testDemoFake_scriptProgressesCreatedArmedDeparted() async throws {
        let api = FakeSpotPassAPI.demo()
        _ = try await api.createHandoff(showName: false)
        let first = try await api.fetchStatus(id: UUID())
        XCTAssertEqual(first.status, .created)
    }

    // MARK: - Follow-up: routing by payload keys, not category

    func testParse_routesByKindAndHandoffID_withoutCategory() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Spot Pass", "body": "Your neighbor is pulling out now."], "thread-id": "spot-pass"],
            "kind": "departed",
            "handoff_id": id.uuidString
        ]
        let event = SpotPassPushEvent.parse(userInfo: userInfo, opened: true)
        XCTAssertEqual(event?.kind, .departed)
        XCTAssertEqual(event?.handoffID, id)
    }

    func testParse_routesIdenticallyWithOrWithoutCategory() {
        let id = UUID().uuidString
        let without: [AnyHashable: Any] = ["aps": ["alert": "x"], "kind": "armed", "handoff_id": id]
        let withCategory: [AnyHashable: Any] = ["aps": ["alert": "x", "category": "wepark_spot_pass_seeker"], "kind": "armed", "handoff_id": id]
        let other: [AnyHashable: Any] = ["aps": ["alert": "x", "category": "some_other_category"], "kind": "armed", "handoff_id": id]
        XCTAssertEqual(SpotPassPushEvent.parse(userInfo: without, opened: false),
                       SpotPassPushEvent.parse(userInfo: withCategory, opened: false))
        XCTAssertEqual(SpotPassPushEvent.parse(userInfo: without, opened: false),
                       SpotPassPushEvent.parse(userInfo: other, opened: false))
        XCTAssertNotNil(SpotPassPushEvent.parse(userInfo: without, opened: false))
    }

    func testRouter_categorylessPayload_isHandledWhenEnabled() {
        let inbox = SpotPassPushInbox()
        let userInfo: [AnyHashable: Any] = ["aps": ["alert": "x"], "kind": "armed", "handoff_id": UUID().uuidString]
        XCTAssertTrue(SpotPassPushRouter.handle(userInfo: userInfo, opened: true, enabled: true, inbox: inbox, center: NotificationCenter()))
        XCTAssertEqual(inbox.pending?.kind, .armed)
    }

    // MARK: - Follow-up F1: Spot Pass rationale shown once

    func testRationale_shownOnlyWhenUndeterminedAndUnseen() {
        XCTAssertTrue(SpotPassPreferences.shouldShowRationale(authorizationStatus: .notDetermined, alreadySeen: false))
        XCTAssertFalse(SpotPassPreferences.shouldShowRationale(authorizationStatus: .notDetermined, alreadySeen: true))
        XCTAssertFalse(SpotPassPreferences.shouldShowRationale(authorizationStatus: .denied, alreadySeen: false))
        XCTAssertFalse(SpotPassPreferences.shouldShowRationale(authorizationStatus: .authorized, alreadySeen: false))
    }

    func testRationaleSeenFlag_persistsAndDefaultsFalse() {
        let suite = "spotpass.rationale.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("no suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = SpotPassPreferences(defaults: defaults)
        XCTAssertFalse(prefs.notificationRationaleSeen)
        prefs.notificationRationaleSeen = true
        XCTAssertTrue(SpotPassPreferences(defaults: defaults).notificationRationaleSeen)
    }

    func testRationaleCopy_usesHeadsUpNotPing() {
        let copy = [SpotPassCopy.rationaleTitle, SpotPassCopy.rationaleBody, SpotPassCopy.rationaleAllow, SpotPassCopy.rationaleNotNow]
        for line in copy { XCTAssertFalse(line.lowercased().contains("ping"), line) }
    }

    // MARK: - Follow-up F5: pinned Stop button only when it cannot cover content

    func testStopButtonPinning() {
        XCTAssertTrue(SpotPassBadgeView.pinsStopButton(short: false, landscape: false, dynamicTypeSize: .large))
        XCTAssertTrue(SpotPassBadgeView.pinsStopButton(short: true, landscape: false, dynamicTypeSize: .large))
        XCTAssertFalse(SpotPassBadgeView.pinsStopButton(short: true, landscape: false, dynamicTypeSize: .xxxLarge))
        XCTAssertFalse(SpotPassBadgeView.pinsStopButton(short: false, landscape: false, dynamicTypeSize: .accessibility5))
        XCTAssertFalse(SpotPassBadgeView.pinsStopButton(short: false, landscape: true, dynamicTypeSize: .large))
    }
}
