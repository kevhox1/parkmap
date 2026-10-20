//
//  DM3PrimingAuthTests.swift
//  WeParkTests
//
//  DM-3 (`docs/drive-mode-default-spec.md` §0.2, AC-9/AC-10/AC-11) — first-launch
//  location-priming card + `enterCruiseMode()`'s authorization-request fix.
//
//  Test groups:
//    1. `LocationPrimingCardGate` one-shot persistence (mirrors `BackgroundNoteGateTests`
//       exactly — ephemeral `UserDefaults` suite, injected).
//    2. `locationPrimingCardShouldShow(...)` — the pure gating function behind
//       `showLocationPrimingCard`'s launch-time computation: flag state, gate state, and
//       `.notDetermined` all gate independently.
//    3. `cruiseEntryAuthAction(for:)` — the pure decision function behind
//       `enterCruiseMode()`'s auth-request fix: `.notDetermined` → request-first,
//       `.denied`/`.restricted` → denied-alert, authorized → proceed unchanged
//       (regression guard).
//
//  `ContentView`'s own `enterCruiseMode()`/`performLaunchSetup()` are `private` instance
//  methods on a SwiftUI View struct — not directly callable from a different test file even
//  under `@testable import` (Swift's `private` is lexically scoped, not module-scoped).
//  Per this project's established precedent (`DriveModeDefaultFlagTests` testing
//  `driveModeDefaultRestStateSheet(driveModeDefaultEnabled:)` rather than reaching into
//  `ContentView.activeSheet`'s `@State` initializer), both decisions are extracted as
//  top-level pure functions in `ContentView.swift` and tested directly here. The instance
//  methods that consume them are single-line call sites verified by code inspection + the
//  mandatory live-UI smoke, not by a unit test that would need a live `ContentView`.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode/simulator on this machine — Kevin verifies
//  compile + test pass on his Mac per HANDOFF.md's environment split.
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - 1. LocationPrimingCardGate persistence

/// Unit tests for the one-time location-priming card gate. Uses an ephemeral UserDefaults
/// suite so standard UserDefaults is never polluted — same shape as `BackgroundNoteGateTests`
/// (`WeParkTests/W85cTests.swift`).
final class LocationPrimingCardGateTests: XCTestCase {

    private let suiteName = "com.wepark.test.locationprimingcardgate"
    private var ephemeralDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        ephemeralDefaults = UserDefaults(suiteName: suiteName)!
        ephemeralDefaults.removeObject(forKey: AppConstants.locationPrimingCardShownKey)
    }

    override func tearDown() {
        ephemeralDefaults.removePersistentDomain(forName: suiteName)
        ephemeralDefaults = nil
        super.tearDown()
    }

    /// AC-9: fresh install — the card has never shown, so `shouldShow()` is true; after
    /// `markShown()`, it never fires again (verifies the "forced-reinstall or UserDefaults
    /// reset" check the AC calls for, at the gate level).
    func testFirstLaunch_showsCard_thenPersistsForever() {
        let gate = LocationPrimingCardGate(defaults: ephemeralDefaults,
                                            key: AppConstants.locationPrimingCardShownKey)

        XCTAssertTrue(gate.shouldShow(),
                      "shouldShow() should return true before the card has ever been shown")

        gate.markShown()

        let stored = ephemeralDefaults.bool(forKey: AppConstants.locationPrimingCardShownKey)
        XCTAssertTrue(stored, "UserDefaults key should be true after markShown()")
        XCTAssertFalse(gate.shouldShow(),
                       "shouldShow() should return false on every subsequent launch")
    }

    /// AC-9 "shown once ever regardless of choice": "Not now" and "Allow" both call
    /// `markShown()` (verified at the `ContentView.dismissLocationPrimingCard(allowed:)`
    /// call site by code inspection — both branches call it unconditionally before
    /// branching on `allowed`); this test asserts the gate itself is idempotent across
    /// repeated `markShown()` calls, which is what makes that unconditional-call shape safe.
    func testMarkShown_isIdempotent_acrossRepeatedCalls() {
        let gate = LocationPrimingCardGate(defaults: ephemeralDefaults,
                                            key: AppConstants.locationPrimingCardShownKey)
        gate.markShown()
        for i in 0..<5 {
            XCTAssertFalse(gate.shouldShow(),
                           "shouldShow() should return false on check #\(i + 1) after markShown")
            gate.markShown()  // repeated calls must not resurface the card
        }
    }

    /// Two gate instances pointed at the same key observe each other's state — confirms the
    /// gate itself holds no in-memory state that would mask a real cross-launch persistence
    /// bug (same discipline `BackgroundNoteGateTests` applies).
    func testTwoGateInstances_shareState_viaUserDefaults() {
        let writer = LocationPrimingCardGate(defaults: ephemeralDefaults,
                                              key: AppConstants.locationPrimingCardShownKey)
        let reader = LocationPrimingCardGate(defaults: ephemeralDefaults,
                                              key: AppConstants.locationPrimingCardShownKey)
        XCTAssertTrue(reader.shouldShow())
        writer.markShown()
        XCTAssertFalse(reader.shouldShow(),
                       "a second gate instance reading the same UserDefaults key must see " +
                       "the first instance's markShown()")
    }
}

// MARK: - 2. locationPrimingCardShouldShow(...) — pure gating

final class LocationPrimingCardShouldShowTests: XCTestCase {

    /// AC-9/AC-2 family: flag off → never shows, regardless of gate/auth state. This is the
    /// guard DM-2/DM-3's shared flag contract requires — "no priming card render anywhere"
    /// while `driveModeDefaultEnabled == false` (spec §0.6 ruling 3, AC-2).
    func testFlagOff_neverShows_evenWithFreshGateAndNotDetermined() {
        XCTAssertFalse(
            locationPrimingCardShouldShow(
                driveModeDefaultEnabled: false,
                gateShouldShow: true,
                authorizationStatus: .notDetermined
            ),
            "AC-2: the priming card must never render while driveModeDefaultEnabled is false, " +
            "even when the gate has never fired and authorization is undetermined."
        )
    }

    /// Flag on, gate fresh, `.notDetermined` — the one case that should show.
    func testFlagOn_freshGate_notDetermined_shows() {
        XCTAssertTrue(
            locationPrimingCardShouldShow(
                driveModeDefaultEnabled: true,
                gateShouldShow: true,
                authorizationStatus: .notDetermined
            ),
            "the card should show when the flag is on, the gate has never fired, and " +
            "authorization is still undetermined (spec §0.2)."
        )
    }

    /// Flag on, gate already fired — never shows again, regardless of authorization status.
    func testFlagOn_gateAlreadyShown_neverShowsAgain() {
        XCTAssertFalse(
            locationPrimingCardShouldShow(
                driveModeDefaultEnabled: true,
                gateShouldShow: false,
                authorizationStatus: .notDetermined
            ),
            "AC-9: once the one-shot gate has fired, the card must never reappear, even if " +
            "authorization is still .notDetermined."
        )
    }

    /// Flag on, fresh gate, but authorization already resolved (authorized) — the card has
    /// nothing left to prime; it must not show.
    func testFlagOn_freshGate_alreadyAuthorized_doesNotShow() {
        for status: CLAuthorizationStatus in [.authorizedWhenInUse, .authorizedAlways] {
            XCTAssertFalse(
                locationPrimingCardShouldShow(
                    driveModeDefaultEnabled: true,
                    gateShouldShow: true,
                    authorizationStatus: status
                ),
                "the card must not show once authorization has already resolved to \(status) " +
                "— it only ever targets the undetermined case."
            )
        }
    }

    /// Flag on, fresh gate, but authorization already denied/restricted — same "nothing left
    /// to prime" reasoning as the authorized case above.
    func testFlagOn_freshGate_alreadyDenied_doesNotShow() {
        for status: CLAuthorizationStatus in [.denied, .restricted] {
            XCTAssertFalse(
                locationPrimingCardShouldShow(
                    driveModeDefaultEnabled: true,
                    gateShouldShow: true,
                    authorizationStatus: status
                ),
                "the card must not show once authorization has already resolved to \(status)."
            )
        }
    }
}

// MARK: - 3. cruiseEntryAuthAction(for:) — enterCruiseMode()'s auth routing

final class CruiseEntryAuthActionTests: XCTestCase {

    /// AC-11a: `.notDetermined` must route to `.requestFirst` — `enterCruiseMode()`'s own
    /// switch (`ContentView.swift`) then calls `locationService.requestAndFetchLocation()`
    /// and returns WITHOUT setting `driveModeActive = true` this tap. This is the exact fix
    /// for the gap §0.2 names: before this fix, `enterCruiseMode()` had no authorization
    /// check at all, so `.notDetermined` fell straight through into a silent escalation.
    func testNotDetermined_routesToRequestFirst() {
        XCTAssertEqual(
            cruiseEntryAuthAction(for: .notDetermined),
            .requestFirst,
            "AC-11a: .notDetermined must route through requestAndFetchLocation() first, " +
            "before any driveModeActive escalation."
        )
    }

    /// AC-11b: `.denied`/`.restricted` must route to `.showDeniedAlert` — `enterCruiseMode()`
    /// sets `showLocationDeniedAlert = true` and returns, never escalating.
    func testDeniedOrRestricted_routesToShowDeniedAlert() {
        for status: CLAuthorizationStatus in [.denied, .restricted] {
            XCTAssertEqual(
                cruiseEntryAuthAction(for: status),
                .showDeniedAlert,
                "AC-11b: \(status) must surface the denied-state alert, never silently do " +
                "nothing and never escalate into driveModeActive."
            )
        }
    }

    /// Regression guard: already-authorized users see ZERO behavior change from this fix —
    /// `.proceed` is the only outcome that lets `enterCruiseMode()` continue into the real
    /// escalation (`driveModeStyle = .cruise`, `driveModeActive = true`), exactly as it did
    /// before this fix existed.
    func testAuthorized_routesToProceed_regressionGuard() {
        for status: CLAuthorizationStatus in [.authorizedWhenInUse, .authorizedAlways] {
            XCTAssertEqual(
                cruiseEntryAuthAction(for: status),
                .proceed,
                "today's shipped escalation path must be untouched for already-authorized " +
                "users: \(status) must resolve to .proceed, not .requestFirst or " +
                ".showDeniedAlert."
            )
        }
    }

    /// `@unknown default` mirrors `BrowseSearchAreaView.handleGoTap()`'s own precedent
    /// (treat an unrecognized future CoreLocation case as authorized rather than blocking
    /// entry) — this test exists so a future CoreLocation SDK addition doesn't silently
    /// change this function's behavior without a visible test failure to prompt review.
    /// `CLAuthorizationStatus` has no public way to synthesize an out-of-range raw value in
    /// a test target, so this documents the intended behavior via the switch's own
    /// `@unknown default` branch rather than asserting it directly.
    func testDocumentsUnknownDefaultBehavior() {
        // See doc comment above — no executable assertion; CLAuthorizationStatus's four
        // known cases are exhaustively covered by the three tests above.
    }
}
