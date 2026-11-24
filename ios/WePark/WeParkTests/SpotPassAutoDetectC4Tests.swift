//
//  SpotPassAutoDetectC4Tests.swift
//  WeParkTests
//
//  Spot Pass C4 (spec 7.4, 9, 14): armed-window auto-detect.
//    1. Departure rule on synthetic fixes: drive, walk, GPS jitter, accuracy gate, one shot.
//    2. Window policy, availability matrix, capability (background mode) parsing.
//    3. Controller lifecycle: preconditions (flag, background mode, opt-in, saved car, authorization,
//       foreground, 30 min lead), every hard stop, the 60 min cap, one shot, When In Use only.
//    4. Flow integration: detection departs ONCE with source `auto`; every terminal closes the window.
//    5. No coordinates in any request.
//
//  All pure helpers under test are `nonisolated`; fakes are MainActor (the module default).
//

import CoreLocation
import XCTest
@testable import WePark

// MARK: - Fix helpers

private let anchorLat = 40.7128
private let anchorLon = -74.0060
private let testAnchor = AutoDetectAnchor(latitude: anchorLat, longitude: anchorLon)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
/// Degrees of latitude per meter at the haversine radius used by `AutoDetectGeometry`.
private let degreesPerMeter = 180.0 / (Double.pi * 6_371_000.0)

/// A fix `metersNorth` of the anchor, `seconds` after `t0`.
private func makeFix(metersNorth: Double, seconds: Double, speed: Double, accuracy: Double = 10) -> AutoDetectFix {
    AutoDetectFix(
        latitude: anchorLat + metersNorth * degreesPerMeter, longitude: anchorLon,
        horizontalAccuracy: accuracy, speed: speed, timestamp: t0.addingTimeInterval(seconds)
    )
}

/// Runs `fixes` through a fresh detector; returns the indices on which it fired.
private func firedIndices(_ fixes: [AutoDetectFix], rule: DepartureRule = .spec) -> [Int] {
    var detector = DepartureDetector(anchor: testAnchor, rule: rule)
    var fired: [Int] = []
    for (index, fix) in fixes.enumerated() {
        if detector.ingest(fix) { fired.append(index) }
    }
    return fired
}

/// 1 Hz fixes driving north at `speed` m/s from the anchor.
private func driveFixes(speed: Double, seconds: Int, accuracy: Double = 10) -> [AutoDetectFix] {
    (0...seconds).map { makeFix(metersNorth: speed * Double($0), seconds: Double($0), speed: speed, accuracy: accuracy) }
}

// MARK: - 1. Departure rule

@MainActor
final class AutoDetectDepartureRuleTests: XCTestCase {

    func testSpecNumbers() {
        let rule = DepartureRule.spec
        XCTAssertEqual(rule.maxAccuracy, 65)
        XCTAssertEqual(rule.minDistance, 60)
        XCTAssertEqual(rule.minSpeed, 3)
        XCTAssertEqual(rule.sustain, 5)
        XCTAssertEqual(rule.minFixes, 2)
        XCTAssertEqual(AutoDetectWindowPolicy.maxDuration, 3600)
        XCTAssertEqual(AutoDetectWindowPolicy.openLead, 1800)
    }

    func testDrivingAway_firesOnceAfterSustainedFivesecondsBeyondSixtyMeters() {
        // 10 m/s: 70 m at t=7 starts the streak, 5 s later (t=12) it completes.
        let fired = firedIndices(driveFixes(speed: 10, seconds: 20))
        XCTAssertEqual(fired, [12])
    }

    func testWalkingAway_neverFires() {
        // 1.4 m/s for 3 minutes: far past 60 m, never at driving speed.
        XCTAssertEqual(firedIndices(driveFixes(speed: 1.4, seconds: 180)), [])
    }

    func testJoggingJustUnderTheLine_neverFires() {
        XCTAssertEqual(firedIndices(driveFixes(speed: 2.9, seconds: 120)), [])
    }

    func testExactlySixtyMeters_isNotMoreThanSixty() {
        let fixes = (0...30).map { makeFix(metersNorth: 60, seconds: Double($0), speed: 10) }
        XCTAssertEqual(firedIndices(fixes), [])
    }

    func testFastButNeverLeavesTheSixtyMeterCircle_neverFires() {
        // Circling the block at the car (parking-lot speed): inside 60 m the whole time.
        let fixes = (0...40).map { makeFix(metersNorth: 40, seconds: Double($0), speed: 8) }
        XCTAssertEqual(firedIndices(fixes), [])
    }

    func testSingleJumpedFix_doesNotFire() {
        // One GPS teleport 300 m away at "driving speed", then back at the car.
        var fixes = (0...5).map { makeFix(metersNorth: 0, seconds: Double($0), speed: 0) }
        fixes.append(makeFix(metersNorth: 300, seconds: 6, speed: 12))
        fixes.append(contentsOf: (7...20).map { makeFix(metersNorth: 0, seconds: Double($0), speed: 0) })
        XCTAssertEqual(firedIndices(fixes), [])
    }

    func testPoorAccuracyFixes_areIgnored() {
        // Every fix is 100 m out at 10 m/s but with 200 m accuracy: unusable.
        XCTAssertEqual(firedIndices(driveFixes(speed: 10, seconds: 30, accuracy: 200)), [])
        XCTAssertEqual(firedIndices(driveFixes(speed: 10, seconds: 30, accuracy: 66)), [])
    }

    func testAccuracyAtTheLimit_isUsable() {
        XCTAssertEqual(firedIndices(driveFixes(speed: 10, seconds: 20, accuracy: 65)), [12])
    }

    func testInvalidNegativeAccuracy_isIgnored() {
        XCTAssertEqual(firedIndices(driveFixes(speed: 10, seconds: 30, accuracy: -1)), [])
    }

    func testOneNoisyFixInsideARealDeparture_doesNotBreakIt() {
        var fixes = driveFixes(speed: 10, seconds: 20)
        fixes[9] = makeFix(metersNorth: 90, seconds: 9, speed: 10, accuracy: 300)   // unusable: ignored, not a reset
        XCTAssertEqual(firedIndices(fixes), [12])
    }

    func testSlowdownInsideTheStreak_resetsIt() {
        var fixes = driveFixes(speed: 10, seconds: 25)
        fixes[10] = makeFix(metersNorth: 100, seconds: 10, speed: 0.5)   // stopped at a light: streak restarts
        // New streak begins at t=11, completes at t=16.
        XCTAssertEqual(firedIndices(fixes), [16])
    }

    func testOneShot_neverFiresASecondTime() {
        var detector = DepartureDetector(anchor: testAnchor)
        var fires = 0
        for fix in driveFixes(speed: 10, seconds: 60) {
            if detector.ingest(fix) { fires += 1 }
        }
        XCTAssertEqual(fires, 1)
        XCTAssertTrue(detector.hasFired)
    }

    func testUnknownSpeed_isDerivedFromMovement() {
        let fixes = driveFixes(speed: 10, seconds: 20).map {
            AutoDetectFix(latitude: $0.latitude, longitude: $0.longitude, horizontalAccuracy: $0.horizontalAccuracy, speed: -1, timestamp: $0.timestamp)
        }
        XCTAssertEqual(firedIndices(fixes), [12])
    }

    func testUnknownSpeed_whileWalking_isDerivedAndRejected() {
        let fixes = driveFixes(speed: 1.4, seconds: 120).map {
            AutoDetectFix(latitude: $0.latitude, longitude: $0.longitude, horizontalAccuracy: $0.horizontalAccuracy, speed: -1, timestamp: $0.timestamp)
        }
        XCTAssertEqual(firedIndices(fixes), [])
    }

    func testUnknownSpeedWithNoPriorFix_isIgnored() {
        var detector = DepartureDetector(anchor: testAnchor)
        let lone = AutoDetectFix(latitude: anchorLat + 0.01, longitude: anchorLon, horizontalAccuracy: 5, speed: -1, timestamp: t0)
        XCTAssertFalse(detector.ingest(lone))
    }

    func testOutOfOrderAndDuplicateTimestamps_areIgnored() {
        var detector = DepartureDetector(anchor: testAnchor)
        XCTAssertFalse(detector.ingest(makeFix(metersNorth: 100, seconds: 10, speed: 10)))
        XCTAssertFalse(detector.ingest(makeFix(metersNorth: 100, seconds: 10, speed: 10)))   // duplicate
        XCTAssertFalse(detector.ingest(makeFix(metersNorth: 100, seconds: 5, speed: 10)))    // older
        XCTAssertFalse(detector.ingest(makeFix(metersNorth: 100, seconds: 11, speed: 10)))
    }

    func testHaversine_isStreetAccurate() {
        let distance = AutoDetectGeometry.distance(
            fromLatitude: anchorLat, longitude: anchorLon, toLatitude: anchorLat + 100 * degreesPerMeter, longitude: anchorLon
        )
        XCTAssertEqual(distance, 100, accuracy: 0.5)
    }
}

// MARK: - 2. Policy, availability, capability

@MainActor
final class AutoDetectPolicyTests: XCTestCase {

    func testWindowOpensOnlyWithinThirtyMinutesOfLeaveTime() {
        let expires = t0.addingTimeInterval(4 * 3600)
        XCTAssertTrue(AutoDetectWindowPolicy.shouldOpen(now: t0, leaveAt: t0.addingTimeInterval(29 * 60), expiresAt: expires))
        XCTAssertTrue(AutoDetectWindowPolicy.shouldOpen(now: t0, leaveAt: t0.addingTimeInterval(30 * 60), expiresAt: expires))
        XCTAssertFalse(AutoDetectWindowPolicy.shouldOpen(now: t0, leaveAt: t0.addingTimeInterval(31 * 60), expiresAt: expires))
        // Leave time already past (the driver foregrounds late): still opens.
        XCTAssertTrue(AutoDetectWindowPolicy.shouldOpen(now: t0, leaveAt: t0.addingTimeInterval(-120), expiresAt: expires))
    }

    func testExpiredPass_neverOpens() {
        XCTAssertFalse(AutoDetectWindowPolicy.shouldOpen(now: t0, leaveAt: t0, expiresAt: t0))
        XCTAssertFalse(AutoDetectWindowPolicy.shouldOpen(now: t0, leaveAt: t0, expiresAt: t0.addingTimeInterval(-1)))
    }

    func testDeadline_isTheEarlierOfCapAndExpiry() {
        XCTAssertEqual(AutoDetectWindowPolicy.deadline(openedAt: t0, expiresAt: t0.addingTimeInterval(7200)), t0.addingTimeInterval(3600))
        XCTAssertEqual(AutoDetectWindowPolicy.deadline(openedAt: t0, expiresAt: t0.addingTimeInterval(900)), t0.addingTimeInterval(900))
    }

    func testEndReason_expiryBeatsCap() {
        XCTAssertEqual(AutoDetectWindowPolicy.endReason(now: t0.addingTimeInterval(900), expiresAt: t0.addingTimeInterval(900)), .expired)
        XCTAssertEqual(AutoDetectWindowPolicy.endReason(now: t0.addingTimeInterval(3600), expiresAt: t0.addingTimeInterval(7200)), .capReached)
    }

    func testOnlyCapExpiryAndTurnOffShowTheToast() {
        let all: [AutoDetectEndReason] = [.detected, .departed, .passEnded, .capReached, .expired, .turnedOff, .terminated, .replaced]
        XCTAssertEqual(all.filter(\.showsToast), [.capReached, .expired, .turnedOff])
    }

    func testAvailability_requiresEverything() {
        func canRun(
            flag: Bool = true, bg: Bool = true, optedIn: Bool = true, anchor: Bool = true,
            auth: AutoDetectAuthorization = .authorized
        ) -> Bool {
            AutoDetectAvailability.canRun(
                flagEnabled: flag, backgroundModeDeclared: bg, optedIn: optedIn, hasAnchor: anchor, authorization: auth
            )
        }
        XCTAssertTrue(canRun())
        XCTAssertFalse(canRun(flag: false))
        XCTAssertFalse(canRun(bg: false))
        XCTAssertFalse(canRun(optedIn: false))
        XCTAssertFalse(canRun(anchor: false), "no parked car -> disabled")
        XCTAssertFalse(canRun(auth: .denied))
        XCTAssertFalse(canRun(auth: .notDetermined))
    }

    func testOffer_states() {
        func offer(
            flag: Bool = true, bg: Bool = true, optedIn: Bool = false, anchor: Bool = true,
            auth: AutoDetectAuthorization = .authorized, running: Bool = false
        ) -> AutoDetectOffer {
            AutoDetectAvailability.offer(
                flagEnabled: flag, backgroundModeDeclared: bg, optedIn: optedIn, hasAnchor: anchor,
                authorization: auth, isRunning: running
            )
        }
        XCTAssertEqual(offer(flag: false), .hidden)
        XCTAssertEqual(offer(bg: false), .hidden, "no background mode in the build: manual only, nothing shown")
        XCTAssertEqual(offer(anchor: false), .needsSavedCar)
        XCTAssertEqual(offer(auth: .denied), .locationDenied)
        XCTAssertEqual(offer(), .canEnable)
        XCTAssertEqual(offer(auth: .notDetermined), .canEnable)
        XCTAssertEqual(offer(optedIn: true), .waiting)
        XCTAssertEqual(offer(optedIn: true, running: true), .on)
    }

    func testCapability_readsTheLocationBackgroundMode() {
        XCTAssertFalse(AutoDetectCapability.backgroundModeDeclared(infoDictionary: nil))
        XCTAssertFalse(AutoDetectCapability.backgroundModeDeclared(infoDictionary: [:]))
        XCTAssertFalse(AutoDetectCapability.backgroundModeDeclared(infoDictionary: ["UIBackgroundModes": ["remote-notification"]]))
        XCTAssertTrue(AutoDetectCapability.backgroundModeDeclared(infoDictionary: ["UIBackgroundModes": ["remote-notification", "location"]]))
    }

    func testFlagAndLiveFactory_areDarkByDefault() {
        XCTAssertFalse(AppConstants.spotHandoffAutoDetectEnabled)
        XCTAssertNil(AutoDetectController.makeLive(enabled: false), "flag off builds no location object at all")
    }

    func testAuthorizationMapping_neverTreatsDeniedAsAuthorized() {
        XCTAssertEqual(AutoDetectAuthorizer.map(.notDetermined), .notDetermined)
        XCTAssertEqual(AutoDetectAuthorizer.map(.authorizedWhenInUse), .authorized)
        XCTAssertEqual(AutoDetectAuthorizer.map(.authorizedAlways), .authorized)
        XCTAssertEqual(AutoDetectAuthorizer.map(.denied), .denied)
        XCTAssertEqual(AutoDetectAuthorizer.map(.restricted), .denied)
    }

    func testPurposePlan_perOffer() {
        XCTAssertEqual(AutoDetectPurposePlan.plan(for: .canEnable), .enable)
        XCTAssertEqual(AutoDetectPurposePlan.plan(for: .needsSavedCar), .saveCarFirst)
        XCTAssertEqual(AutoDetectPurposePlan.plan(for: .locationDenied), .openSettings)
    }

    func testCopy_neverSaysPing_andKeepsTheVoice() {
        let lines = [
            DriverCopy.autoDetectOffToast, DriverCopy.autoDetectOnTitle, DriverCopy.autoDetectOnSub(name: "Bodega Cat"),
            DriverCopy.autoDetectTurnOff, DriverCopy.autoDetectOfferTitle, DriverCopy.autoDetectOfferSub,
            DriverCopy.autoDetectWaitingTitle, DriverCopy.autoDetectWaitingSub, DriverCopy.autoDetectNeedsCarTitle,
            DriverCopy.autoDetectNeedsCarSub, DriverCopy.autoDetectDeniedTitle, DriverCopy.autoDetectDeniedSub,
            DriverCopy.purposeTitle, DriverCopy.purposeBullet1Lead, DriverCopy.purposeBullet1Rest,
            DriverCopy.purposeBullet2Lead, DriverCopy.purposeBullet2Rest, DriverCopy.purposeBullet3Lead,
            DriverCopy.purposeBullet3Rest, DriverCopy.purposePrimary, DriverCopy.purposeSecondary,
            DriverCopy.purposeNoCarPrimary, DriverCopy.purposeNoCarHelper, DriverCopy.purposeDeniedHelper,
            ClipCopy.autoDetectCaption
        ]
        for line in lines { XCTAssertFalse(line.lowercased().contains("ping"), line) }
        XCTAssertEqual(DriverCopy.autoDetectOffToast, "Auto heads-up is off.")
        XCTAssertEqual(DriverCopy.purposePrimary, "Turn on auto heads-up")
        XCTAssertEqual(DriverCopy.purposeTitle, "Let WePark tell your neighbor for you")
        XCTAssertEqual(ClipCopy.autoDetectCaption, "auto heads-up on")
    }
}

// MARK: - Fakes

@MainActor
private final class FakeAutoLocation: AutoDetectLocationProviding {
    var authorization: AutoDetectAuthorization = .authorized
    var promptResult: AutoDetectAuthorization = .authorized
    private(set) var whenInUseRequests = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@MainActor (AutoDetectFix) -> Void)?

    func requestWhenInUse() async -> AutoDetectAuthorization {
        whenInUseRequests += 1
        authorization = promptResult
        return promptResult
    }

    func start(onFix: @escaping @MainActor (AutoDetectFix) -> Void) {
        startCount += 1
        handler = onFix
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    /// Delivers a fix only while updates are running (a stopped provider delivers nothing).
    func emit(_ fix: AutoDetectFix) { handler?(fix) }
}

@MainActor
private final class FakeAutoSession: AutoDetectBackgroundSession {
    private(set) var invalidations = 0
    func invalidate() { invalidations += 1 }
}

@MainActor
private final class FakeOptIn: AutoDetectOptInStoring {
    var isOptedIn: Bool
    init(_ value: Bool = true) { isOptedIn = value }
}

private final class WaitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func add(_ value: TimeInterval) { lock.lock(); values.append(value); lock.unlock() }
    var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return values }
}

// MARK: - 3. Controller lifecycle

@MainActor
private final class AutoHarness {
    var clock = t0
    var anchor: AutoDetectAnchor? = testAnchor
    var foreground = true
    let location = FakeAutoLocation()
    let optIn: FakeOptIn
    let waits = WaitBox()
    private(set) var sessions: [FakeAutoSession] = []
    private(set) var runningEvents: [String] = []
    private(set) var detected = 0
    /// Location/session state observed at the instant `onDetected` ran (one shot: stopped FIRST).
    private(set) var locationStoppedWhenDetected = false
    private(set) var sessionInvalidatedWhenDetected = false
    private(set) var controller: AutoDetectController!

    let passID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID()

    init(flag: Bool = true, backgroundMode: Bool = true, optedIn: Bool = true) {
        optIn = FakeOptIn(optedIn)
        controller = AutoDetectController(
            flagEnabled: flag,
            backgroundModeDeclared: { backgroundMode },
            optIn: optIn,
            anchorProvider: { [weak self] in self?.anchor },
            location: location,
            makeSession: { [weak self] in
                let session = FakeAutoSession()
                self?.sessions.append(session)
                return session
            },
            isForeground: { [weak self] in self?.foreground ?? false },
            now: { [weak self] in self?.clock ?? t0 },
            sleeper: { [waits] seconds in waits.add(seconds) }
        )
        controller.onDetected = { [weak self] in
            guard let self else { return }
            self.detected += 1
            self.locationStoppedWhenDetected = self.location.stopCount >= 1
            self.sessionInvalidatedWhenDetected = (self.sessions.last?.invalidations ?? 0) >= 1
        }
        controller.onRunningChanged = { [weak self] running, reason in
            self?.runningEvents.append(running ? "open" : "close:\(reason.map { String(describing: $0) } ?? "none")")
        }
    }

    func open(leaveIn: TimeInterval = 600, expiresIn: TimeInterval = 1500) {
        controller.openIfEligible(
            passID: passID, leaveAt: clock.addingTimeInterval(leaveIn), expiresAt: clock.addingTimeInterval(expiresIn)
        )
    }

    /// Delivers a fix at its own timestamp (the clock follows the fix, so it is never stale).
    func feed(_ fix: AutoDetectFix) {
        clock = fix.timestamp
        location.emit(fix)
    }

    func yield() async { for _ in 0..<20 { await Task.yield() } }
}

@MainActor
final class AutoDetectControllerTests: XCTestCase {

    // MARK: Preconditions

    func testHappyPath_opensWindow_startsLocationAndSession() {
        let h = AutoHarness()
        h.open()
        XCTAssertTrue(h.controller.isRunning)
        XCTAssertEqual(h.location.startCount, 1)
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.runningEvents, ["open"])
        XCTAssertEqual(h.controller.offer, .on)
    }

    func testFlagOff_neverOpens_andShowsNothing() {
        let h = AutoHarness(flag: false)
        h.open()
        XCTAssertFalse(h.controller.isRunning)
        XCTAssertEqual(h.location.startCount, 0)
        XCTAssertTrue(h.sessions.isEmpty)
        XCTAssertEqual(h.controller.offer, .hidden)
    }

    func testBackgroundModeAbsent_degradesToManualOnly() async {
        let h = AutoHarness(backgroundMode: false)
        h.open()
        XCTAssertFalse(h.controller.isRunning)
        XCTAssertEqual(h.location.startCount, 0)
        XCTAssertEqual(h.controller.offer, .hidden)
        let result = await h.controller.enable()
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(h.optIn.isOptedIn, "a refused enable leaves the stored opt-in alone")
    }

    func testNoParkedCar_disablesAutoDetect() async {
        let h = AutoHarness()
        h.anchor = nil
        h.open()
        XCTAssertFalse(h.controller.isRunning)
        XCTAssertEqual(h.location.startCount, 0)
        h.controller.refreshOffer()
        XCTAssertEqual(h.controller.offer, .needsSavedCar)
        let result = await h.controller.enable()
        XCTAssertEqual(result, .needsSavedCar)
    }

    func testNotOptedIn_neverOpens() {
        let h = AutoHarness(optedIn: false)
        h.open()
        XCTAssertFalse(h.controller.isRunning)
        XCTAssertEqual(h.location.startCount, 0)
    }

    func testLocationDenied_neverOpens() {
        let h = AutoHarness()
        h.location.authorization = .denied
        h.open()
        XCTAssertFalse(h.controller.isRunning)
    }

    func testBackground_neverOpens() {
        let h = AutoHarness()
        h.foreground = false
        h.open()
        XCTAssertFalse(h.controller.isRunning, "a background session cannot be created: wait for the foreground")
        h.foreground = true
        h.open()
        XCTAssertTrue(h.controller.isRunning)
    }

    func testLeaveTimeBeyondThirtyMinutes_doesNotOpenYet() {
        let h = AutoHarness()
        h.open(leaveIn: 45 * 60, expiresIn: 4 * 3600)
        XCTAssertFalse(h.controller.isRunning)
        // Thirty minutes later the foreground tick opens it.
        h.clock = h.clock.addingTimeInterval(16 * 60)
        h.controller.openIfEligible(
            passID: h.passID, leaveAt: t0.addingTimeInterval(45 * 60), expiresAt: t0.addingTimeInterval(4 * 3600)
        )
        XCTAssertTrue(h.controller.isRunning)
    }

    func testOpeningTwiceForTheSamePass_isIdempotent() {
        let h = AutoHarness()
        h.open()
        h.open()
        XCTAssertEqual(h.location.startCount, 1)
        XCTAssertEqual(h.sessions.count, 1)
    }

    func testADifferentPass_replacesTheWindow() {
        let h = AutoHarness()
        h.open()
        h.controller.openIfEligible(passID: UUID(), leaveAt: t0.addingTimeInterval(60), expiresAt: t0.addingTimeInterval(900))
        XCTAssertEqual(h.sessions.count, 2)
        XCTAssertEqual(h.sessions.first?.invalidations, 1)
        XCTAssertEqual(h.location.stopCount, 1)
        XCTAssertTrue(h.controller.isRunning)
    }

    // MARK: Authorization: When In Use only

    func testEnable_promptsWhenInUseOnlyWhenUndetermined_thenOptsIn() async {
        let h = AutoHarness(optedIn: false)
        h.location.authorization = .notDetermined
        let result = await h.controller.enable()
        XCTAssertEqual(result, .enabled)
        XCTAssertEqual(h.location.whenInUseRequests, 1)
        XCTAssertTrue(h.optIn.isOptedIn)
    }

    func testEnable_whenAlreadyAuthorized_doesNotPromptAgain() async {
        let h = AutoHarness(optedIn: false)
        let result = await h.controller.enable()
        XCTAssertEqual(result, .enabled)
        XCTAssertEqual(h.location.whenInUseRequests, 0)
    }

    func testEnable_denied_doesNotOptIn() async {
        let h = AutoHarness(optedIn: false)
        h.location.authorization = .notDetermined
        h.location.promptResult = .denied
        let result = await h.controller.enable()
        XCTAssertEqual(result, .locationDenied)
        XCTAssertFalse(h.optIn.isOptedIn)
        XCTAssertEqual(h.controller.offer, .locationDenied)
    }

    // MARK: Detection: one shot, location stops first

    func testDriving_detectsOnce_andStopsLocationBeforeAnnouncing() {
        let h = AutoHarness()
        h.open()
        for fix in driveFixes(speed: 10, seconds: 25) { h.feed(fix) }
        XCTAssertEqual(h.detected, 1)
        XCTAssertTrue(h.locationStoppedWhenDetected)
        XCTAssertTrue(h.sessionInvalidatedWhenDetected)
        XCTAssertFalse(h.controller.isRunning)
        XCTAssertEqual(h.location.stopCount, 1)
        XCTAssertEqual(h.sessions.first?.invalidations, 1)
        XCTAssertEqual(h.runningEvents, ["open", "close:detected"])
    }

    func testWalking_neverDetects_andWindowStaysOpen() {
        let h = AutoHarness()
        h.open()
        for fix in driveFixes(speed: 1.4, seconds: 170) { h.feed(fix) }
        XCTAssertEqual(h.detected, 0)
        XCTAssertTrue(h.controller.isRunning)
    }

    func testStaleCachedFix_isIgnored() {
        let h = AutoHarness()
        h.open()
        // A fix stamped a minute before "now" (a cached one from before the window).
        let stale = makeFix(metersNorth: 500, seconds: -60, speed: 15)
        h.clock = t0
        h.location.emit(stale)
        h.location.emit(makeFix(metersNorth: 510, seconds: -59, speed: 15))
        h.location.emit(makeFix(metersNorth: 520, seconds: -50, speed: 15))
        XCTAssertEqual(h.detected, 0)
    }

    func testFixesAfterClose_areNeverDelivered() {
        let h = AutoHarness()
        h.open()
        h.controller.close(.passEnded)
        for fix in driveFixes(speed: 10, seconds: 25) { h.feed(fix) }
        XCTAssertEqual(h.detected, 0)
    }

    // MARK: Hard stops

    func testEveryHardStop_stopsLocation_invalidatesSession_andClearsState() {
        let reasons: [AutoDetectEndReason] = [.departed, .passEnded, .capReached, .expired, .turnedOff, .terminated, .replaced]
        for reason in reasons {
            let h = AutoHarness()
            h.open()
            h.controller.close(reason)
            XCTAssertFalse(h.controller.isRunning, "\(reason)")
            XCTAssertEqual(h.location.stopCount, 1, "\(reason)")
            XCTAssertEqual(h.sessions.first?.invalidations, 1, "\(reason)")
            XCTAssertEqual(h.runningEvents.last, "close:\(reason)", "\(reason)")
            // A late fix is dropped.
            for fix in driveFixes(speed: 10, seconds: 25) { h.feed(fix) }
            XCTAssertEqual(h.detected, 0, "\(reason)")
        }
    }

    func testClose_isIdempotent() {
        let h = AutoHarness()
        h.open()
        h.controller.close(.passEnded)
        h.controller.close(.departed)
        h.controller.close(.terminated)
        XCTAssertEqual(h.location.stopCount, 1)
        XCTAssertEqual(h.sessions.first?.invalidations, 1)
        XCTAssertEqual(h.runningEvents.count, 2)
    }

    func testClose_whenNeverOpened_isANoOp() {
        let h = AutoHarness()
        h.controller.close(.passEnded)
        XCTAssertEqual(h.location.stopCount, 0)
        XCTAssertTrue(h.runningEvents.isEmpty)
    }

    func testAppTermination_stopsEverything() {
        let h = AutoHarness()
        h.open()
        h.controller.appWillTerminate()
        XCTAssertFalse(h.controller.isRunning)
        XCTAssertEqual(h.location.stopCount, 1)
        XCTAssertEqual(h.sessions.first?.invalidations, 1)
    }

    func testTurnOff_closesAndWithdrawsOptIn() {
        let h = AutoHarness()
        h.open()
        h.controller.turnOff()
        XCTAssertFalse(h.controller.isRunning)
        XCTAssertFalse(h.optIn.isOptedIn, "the next pass must not start a window the driver turned off")
        XCTAssertEqual(h.controller.offer, .canEnable)
        h.open()
        XCTAssertFalse(h.controller.isRunning)
    }

    // MARK: 60 minute cap

    func testSixtyMinuteCap_closesOnTheNextFix() {
        let h = AutoHarness()
        h.open(leaveIn: 60, expiresIn: 4 * 3600)
        h.clock = t0.addingTimeInterval(3599)
        XCTAssertFalse(h.controller.enforceDeadline())
        h.clock = t0.addingTimeInterval(3600)
        h.location.emit(makeFix(metersNorth: 500, seconds: 3600, speed: 15))
        XCTAssertFalse(h.controller.isRunning)
        XCTAssertEqual(h.runningEvents.last, "close:capReached")
        XCTAssertEqual(h.location.stopCount, 1)
    }

    func testPassExpiry_beforeTheCap_endsAsExpired() {
        let h = AutoHarness()
        h.open(leaveIn: 60, expiresIn: 900)
        h.clock = t0.addingTimeInterval(900)
        XCTAssertTrue(h.controller.enforceDeadline())
        XCTAssertEqual(h.runningEvents.last, "close:expired")
    }

    func testExtension_movesTheExpiryButNeverPastTheCap() {
        let h = AutoHarness()
        h.open(leaveIn: 60, expiresIn: 900)
        h.controller.passExtended(expiresAt: t0.addingTimeInterval(1200))
        h.clock = t0.addingTimeInterval(1000)
        XCTAssertFalse(h.controller.enforceDeadline(), "extended past the old expiry")
        h.controller.passExtended(expiresAt: t0.addingTimeInterval(10_000))
        h.clock = t0.addingTimeInterval(3600)
        XCTAssertTrue(h.controller.enforceDeadline(), "the 60 minute cap still wins")
    }

    func testDeadlineTimer_isScheduledForTheEarlierOfCapAndExpiry() async {
        let capped = AutoHarness()
        capped.open(leaveIn: 60, expiresIn: 4 * 3600)
        await capped.yield()
        XCTAssertEqual(capped.waits.all.last ?? 0, 3600, accuracy: 0.001)

        let expiring = AutoHarness()
        expiring.open(leaveIn: 60, expiresIn: 900)
        await expiring.yield()
        XCTAssertEqual(expiring.waits.all.last ?? 0, 900, accuracy: 0.001)
    }
}

// MARK: - 4. Flow integration

@MainActor
private final class AutoFlowAPI: HandoffDriverAPI {
    private(set) var departSources: [HandoffDepartSource] = []
    private(set) var calls: [String] = []
    var departResults: [Result<Bool, HandoffAPIError>] = []
    let passID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID()

    func peek(token: String) async throws -> HandoffPeekResult {
        .open(HandoffPassPreview(alias: "Bodega Cat", glyph: "bodega_cat", displayName: nil))
    }

    func claim(_ request: HandoffClaimRequest, userJWT: String?) async throws -> HandoffClaimResult {
        .armed(HandoffArmedGrant(
            passID: passID, leaveAt: t0.addingTimeInterval(600), expiresAt: t0.addingTimeInterval(1500),
            secret: ClaimerSecret("SECRET-SECRET-SECRET-1")
        ))
    }

    func depart(id: UUID, secret: ClaimerSecret, source: HandoffDepartSource) async throws -> Bool {
        calls.append("depart")
        departSources.append(source)
        return try (departResults.isEmpty ? .success(true) : departResults.removeFirst()).get()
    }

    func extend(id: UUID, secret: ClaimerSecret) async throws -> HandoffExtendResult {
        calls.append("extend")
        return HandoffExtendResult(ok: true, leaveAt: nil, expiresAt: t0.addingTimeInterval(1800))
    }

    func cancel(id: UUID, secret: ClaimerSecret) async throws -> Bool {
        calls.append("cancel")
        return true
    }

    func report(target: HandoffReportTarget, reason: HandoffReportReason) async throws -> Bool { true }
}

@MainActor
private final class AutoFlowReminders: HandoffReminderScheduling {
    func availability() async -> HandoffReminderAvailability { .on }
    func schedule(_ reminders: [PlannedReminder], passID: UUID) async {}
    func cancelAll(passID: UUID) {}
}

@MainActor
private final class AutoFlowActivity: DriverActivityControlling {
    var areActivitiesEnabled = true
    var onRemotePhase: ((SpotPassActivityAttributes.Phase) -> Void)?
    private(set) var autoDetectCaption: [Bool] = []
    func adoptExisting() -> Bool { false }
    func start(name: String, glyph: String, leaveAt: Date, startedAt: Date) async -> (didStart: Bool, token: String?) { (true, "aa") }
    func update(phase: SpotPassActivityAttributes.Phase, leaveAt: Date?, startedAt: Date?, passID: UUID?) async {}
    func end(phase: SpotPassActivityAttributes.Phase, now: Date) async {}
    func setAutoDetect(_ on: Bool) async { autoDetectCaption.append(on) }
}

@MainActor
private final class AutoFlowSession: DriverSessionProviding {
    func accessToken() async -> String? { "jwt" }
}

@MainActor
private final class AutoFlowPush: HandoffPushTokenProviding {
    func deviceToken() async -> String? { "0011223344556677889900112233445566778899" }
}

@MainActor
private final class AutoFlowFeedback: HandoffFeedback {
    func selection() {}
    func armImpact() {}
    func success() {}
    func lightImpact() {}
    func announce(_ message: String) {}
}

private let autoToken = "AbCdEfGhIjKlMnOpQrSt_-"

@MainActor
private final class AutoFlowHarness {
    let api = AutoFlowAPI()
    let secrets = InMemoryHandoffSecretStore()
    let passes = InMemoryHandoffPassStore()
    let activity = AutoFlowActivity()
    let auto: AutoHarness
    private(set) var controller: DriverFlowController!

    init(auto: AutoHarness? = nil) {
        let auto = auto ?? AutoHarness()
        self.auto = auto
        controller = makeController(with: auto.controller)
    }

    func makeController(with autoDetect: (any AutoDetectControlling)?) -> DriverFlowController {
        DriverFlowController(dependencies: DriverDependencies(
            api: api, secrets: secrets, passStore: passes, session: AutoFlowSession(), reminders: AutoFlowReminders(),
            activity: activity, pushToken: AutoFlowPush(), feedback: AutoFlowFeedback(),
            now: { [weak self] in self?.auto.clock ?? t0 }, sentDwell: 0, autoDetect: autoDetect
        ))
    }

    func arm() async {
        if let link = SpotPassLink(url: URL(string: "https://getwepark.com/p#t=\(autoToken)") ?? URL(fileURLWithPath: "/")) {
            controller.handle(link: link)
        }
        for _ in 0..<40 { await Task.yield() }
        controller.select(.minutes(10))
        await controller.arm()
    }

    func settle() async { for _ in 0..<40 { await Task.yield() } }
}

@MainActor
final class AutoDetectFlowIntegrationTests: XCTestCase {

    func testArming_withAutoDetectEligible_opensTheWindow_andShowsTheCaption() async {
        let h = AutoFlowHarness()
        await h.arm()
        await h.settle()
        XCTAssertEqual(h.controller.phase, .armed)
        XCTAssertTrue(h.auto.controller.isRunning)
        XCTAssertEqual(h.activity.autoDetectCaption, [true])
    }

    func testDetection_departsExactlyOnce_withSourceAuto_andStopsLocation() async {
        let h = AutoFlowHarness()
        await h.arm()
        for fix in driveFixes(speed: 10, seconds: 40) { h.auto.feed(fix) }
        await h.settle()
        XCTAssertEqual(h.api.departSources, [.auto])
        XCTAssertEqual(h.controller.pass?.status, .departed)
        XCTAssertFalse(h.auto.controller.isRunning)
        XCTAssertEqual(h.auto.location.stopCount, 1)
    }

    func testWalking_neverDeparts() async {
        let h = AutoFlowHarness()
        await h.arm()
        for fix in driveFixes(speed: 1.4, seconds: 170) { h.auto.feed(fix) }
        await h.settle()
        XCTAssertTrue(h.api.departSources.isEmpty)
        XCTAssertEqual(h.controller.pass?.status, .armed)
        XCTAssertTrue(h.auto.controller.isRunning)
    }

    func testManualDepart_closesTheWindow() async {
        let h = AutoFlowHarness()
        await h.arm()
        await h.controller.pullOut(source: .manual)
        XCTAssertFalse(h.auto.controller.isRunning)
        XCTAssertEqual(h.auto.location.stopCount, 1)
    }

    func testStartDrivingDepart_closesTheWindow() async {
        let h = AutoFlowHarness()
        await h.arm()
        let told = await h.controller.departForStartDriving()
        XCTAssertTrue(told)
        XCTAssertEqual(h.api.departSources, [.startDriving])
        XCTAssertFalse(h.auto.controller.isRunning)
    }

    func testDriverCancel_closesTheWindow() async {
        let h = AutoFlowHarness()
        await h.arm()
        await h.controller.confirmCancel()
        XCTAssertFalse(h.auto.controller.isRunning)
        XCTAssertEqual(h.auto.location.stopCount, 1)
        XCTAssertEqual(h.auto.sessions.first?.invalidations, 1)
    }

    func testSeekerEnded_closesTheWindow() async {
        let h = AutoFlowHarness()
        await h.arm()
        await h.controller.receiveHandoffEnded()
        XCTAssertFalse(h.auto.controller.isRunning)
    }

    func testPassExpiry_closesTheWindow() async {
        let h = AutoFlowHarness()
        await h.arm()
        h.auto.clock = t0.addingTimeInterval(1501)
        await h.controller.tick()
        XCTAssertEqual(h.controller.phase, .ended)
        XCTAssertFalse(h.auto.controller.isRunning)
    }

    func testExtend_carriesTheNewExpiryToTheWindow() async {
        let h = AutoFlowHarness()
        await h.arm()
        await h.controller.extendFiveMinutes()
        // Old expiry was t0+1500; the extension moved it to t0+1800.
        h.auto.clock = t0.addingTimeInterval(1600)
        XCTAssertFalse(h.auto.controller.enforceDeadline())
        h.auto.clock = t0.addingTimeInterval(1800)
        XCTAssertTrue(h.auto.controller.enforceDeadline())
    }

    func testNotOptedIn_armsFineWithoutAWindow() async {
        let h = AutoFlowHarness(auto: AutoHarness(optedIn: false))
        await h.arm()
        XCTAssertEqual(h.controller.phase, .armed)
        XCTAssertFalse(h.auto.controller.isRunning)
        XCTAssertEqual(h.auto.location.startCount, 0)
    }

    func testNoAutoDetectDependency_flagOff_isInert() async {
        let h = AutoFlowHarness()
        let plain = h.makeController(with: nil)
        XCTAssertNil(plain.autoDetect)
        let enable = await plain.enableAutoDetect()
        XCTAssertEqual(enable, .unavailable)
        plain.turnOffAutoDetect()
    }

    func testRelaunchWithAnArmedPass_opensTheWindowFromTheForeground() async {
        let h = AutoFlowHarness()
        await h.arm()
        h.auto.controller.close(.terminated)               // the process died
        let relaunchAuto = AutoHarness()
        relaunchAuto.clock = h.auto.clock
        let relaunched = h.makeController(with: relaunchAuto.controller)
        XCTAssertEqual(relaunched.phase, .armed)
        XCTAssertTrue(relaunchAuto.controller.isRunning)
    }

    func testRelaunchInTheBackground_doesNotOpenTheWindow_thenForegroundDoes() async {
        let h = AutoFlowHarness()
        await h.arm()
        h.auto.controller.close(.terminated)
        let relaunchAuto = AutoHarness()
        relaunchAuto.foreground = false                    // e.g. a lock-screen intent launch
        relaunchAuto.clock = h.auto.clock
        let relaunched = h.makeController(with: relaunchAuto.controller)
        XCTAssertFalse(relaunchAuto.controller.isRunning)
        relaunchAuto.foreground = true
        await relaunched.refreshFromStorage()
        XCTAssertTrue(relaunchAuto.controller.isRunning)
    }

    func testToastOnTurnOff_andCap() async {
        let h = AutoFlowHarness()
        await h.arm()
        h.controller.turnOffAutoDetect()
        XCTAssertEqual(h.controller.toast, DriverCopy.autoDetectOffToast)
    }

    func testDepartFailing_afterDetection_isNotRetriedByLocation() async {
        let h = AutoFlowHarness()
        h.api.departResults = [.failure(.offline)]
        await h.arm()
        for fix in driveFixes(speed: 10, seconds: 40) { h.auto.feed(fix) }
        await h.settle()
        XCTAssertEqual(h.api.departSources, [.auto], "one shot: a single attempt")
        XCTAssertFalse(h.auto.controller.isRunning)
        XCTAssertEqual(h.controller.pass?.status, .armed, "manual retry remains available")
    }
}

// MARK: - 5. No coordinates in any request

@MainActor
final class AutoDetectNoCoordinatesTests: XCTestCase {

    func testAutoDepartRequest_carriesOnlyIdSecretAndSource() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID()
        let body = HandoffWire.securedBody(id: id, secret: ClaimerSecret("SECRET-SECRET-SECRET-1"), extra: ["source": HandoffDepartSource.auto.rawValue])
        let base = try XCTUnwrap(URL(string: "https://example.supabase.co"))
        let request = try URLSessionHandoffDriverAPI.request(
            baseURL: base, anonKey: "anon", function: "handoff-depart", body: body, userJWT: nil
        )
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["id", "claimer_secret", "source"])
        XCTAssertEqual(json["source"] as? String, "auto")

        let text = String(decoding: data, as: UTF8.self)
        for coordinate in [anchorLat, anchorLon, anchorLat + 0.001, anchorLon + 0.001] {
            XCTAssertFalse(text.contains(String(format: "%.3f", abs(coordinate))), "coordinate leaked into the body")
        }
        let headers = (request.allHTTPHeaderFields ?? [:]).map { "\($0.key)=\($0.value)" }.joined()
        XCTAssertFalse(headers.contains("40.7"))
        XCTAssertFalse((request.url?.absoluteString ?? "").contains("40.7"))
        XCTAssertNil(request.url?.query)
    }

    func testDepartSourceAuto_isAKnownWireValue() {
        XCTAssertEqual(HandoffDepartSource.auto.rawValue, "auto")
    }

    func testFixAndAnchorTypes_arePlainValueTypesWithNoEncodingPath() {
        // Neither type is Encodable: there is no way to serialize a fix into a request by accident.
        XCTAssertFalse((AutoDetectFix.self as Any) is Encodable.Type)
        XCTAssertFalse((AutoDetectAnchor.self as Any) is Encodable.Type)
    }
}
