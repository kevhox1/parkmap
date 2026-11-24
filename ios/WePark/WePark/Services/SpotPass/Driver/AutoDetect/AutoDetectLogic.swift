//
//  AutoDetectLogic.swift
//  Services/SpotPass/Driver/AutoDetect
//
//  Spot Pass C4 (spec 7.4): the PURE half of armed-window auto-detect. No CoreLocation, no UIKit,
//  no clock: fixes, anchor and policy numbers in, a yes/no out, so every rule is unit-tested with
//  synthetic fixes (walk, drive, drift, bad accuracy, one shot).
//
//  Departure rule (spec 7.4, verbatim numbers): two or more consecutive USABLE fixes (horizontal
//  accuracy <= 65 m), each MORE than 60 m from the anchor and moving at >= 3 m/s (about 7 mph),
//  spanning at least 5 s. Walking away (> 60 m at < 3 m/s) resets the streak and never fires.
//
//  CoreMotion "automotive" confirmation was weighed and left out (documented in the PR): it adds a
//  second permission prompt (Motion & Fitness) and its own battery cost for marginal gain over a
//  speed gate; the spec defers it (section 13, Phase 2).
//
//  Privacy: nothing in this file stores, logs or transmits a coordinate. The detector keeps the
//  anchor and the last usable fix in memory for the length of one window and is then dropped.
//
//  Every type is `nonisolated` (the module defaults to MainActor isolation) so these run from the
//  CoreLocation async sequence, a plain XCTestCase and the controller alike.
//

import Foundation

// MARK: - Value types

/// One location fix, reduced to what the rule needs. Built from a `CLLocation` by the live provider.
nonisolated struct AutoDetectFix: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    /// Meters; negative = invalid (CoreLocation convention).
    let horizontalAccuracy: Double
    /// m/s; negative = unknown (CoreLocation convention).
    let speed: Double
    let timestamp: Date

    init(latitude: Double, longitude: Double, horizontalAccuracy: Double, speed: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.timestamp = timestamp
    }
}

/// The parked car's coordinate. Held in memory for one window only.
nonisolated struct AutoDetectAnchor: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

// MARK: - Geometry

nonisolated enum AutoDetectGeometry {
    /// Great-circle distance in meters (haversine). Plenty accurate at street scale.
    static func distance(
        fromLatitude lat1: Double, longitude lon1: Double, toLatitude lat2: Double, longitude lon2: Double
    ) -> Double {
        let earthRadius = 6_371_000.0
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let dPhi = (lat2 - lat1) * .pi / 180
        let dLambda = (lon2 - lon1) * .pi / 180
        let a = sin(dPhi / 2) * sin(dPhi / 2) + cos(phi1) * cos(phi2) * sin(dLambda / 2) * sin(dLambda / 2)
        return 2 * earthRadius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

// MARK: - Rule

nonisolated struct DepartureRule: Equatable, Sendable {
    /// A fix worse than this is ignored (neither counts nor resets): GPS drift near buildings.
    var maxAccuracy: Double = 65
    /// Strictly more than this from the anchor.
    var minDistance: Double = 60
    /// At least this fast (m/s). Walking is ~1.4 m/s, a brisk jog ~3: 3 m/s is the line.
    var minSpeed: Double = 3
    /// The qualifying streak must span at least this long (seconds).
    var sustain: TimeInterval = 5
    /// ...and contain at least this many fixes.
    var minFixes = 2

    static let spec = DepartureRule()

    init() {}
}

// MARK: - Detector

/// Feed it fixes in order; it answers `true` exactly ONCE (one shot) when the rule is met.
nonisolated struct DepartureDetector: Sendable {
    let anchor: AutoDetectAnchor
    let rule: DepartureRule

    private(set) var hasFired = false
    private var streakStart: Date?
    private var streakCount = 0
    private var lastUsable: AutoDetectFix?

    init(anchor: AutoDetectAnchor, rule: DepartureRule = .spec) {
        self.anchor = anchor
        self.rule = rule
    }

    /// Returns true on the fix that completes a departure. After that it never returns true again.
    mutating func ingest(_ fix: AutoDetectFix) -> Bool {
        guard !hasFired else { return false }
        // Unusable fix (invalid or too imprecise): ignored entirely, so a single noisy fix can neither
        // fake a departure nor break a real one.
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= rule.maxAccuracy else { return false }
        // Out-of-order or duplicate timestamp: ignore.
        if let last = lastUsable, fix.timestamp <= last.timestamp { return false }
        let previous = lastUsable
        lastUsable = fix

        // Speed: the reported one, else derived from the previous usable fix. Unknown = ignore the fix.
        guard let speed = effectiveSpeed(of: fix, previous: previous) else { return false }

        let distance = AutoDetectGeometry.distance(
            fromLatitude: anchor.latitude, longitude: anchor.longitude,
            toLatitude: fix.latitude, longitude: fix.longitude
        )
        guard distance > rule.minDistance, speed >= rule.minSpeed else {
            // Near the car, or too slow (walking away): the streak starts over.
            streakStart = nil
            streakCount = 0
            return false
        }

        if streakStart == nil { streakStart = fix.timestamp }
        streakCount += 1
        guard let start = streakStart,
              streakCount >= rule.minFixes,
              fix.timestamp.timeIntervalSince(start) >= rule.sustain
        else { return false }
        hasFired = true
        return true
    }

    private func effectiveSpeed(of fix: AutoDetectFix, previous: AutoDetectFix?) -> Double? {
        if fix.speed >= 0 { return fix.speed }
        guard let previous else { return nil }
        let dt = fix.timestamp.timeIntervalSince(previous.timestamp)
        guard dt >= 0.5, dt <= 10 else { return nil }
        let moved = AutoDetectGeometry.distance(
            fromLatitude: previous.latitude, longitude: previous.longitude,
            toLatitude: fix.latitude, longitude: fix.longitude
        )
        return moved / dt
    }
}

// MARK: - Window policy

nonisolated enum AutoDetectEndReason: Equatable, Sendable {
    /// The detector fired: the departure is being sent.
    case detected
    /// A departure left by another source (button, Live Activity, Start Driving, Shortcut).
    case departed
    /// Cancelled, ended by the seeker, thanked, or otherwise gone.
    case passEnded
    /// The hard 60 minute cap.
    case capReached
    /// The pass reached its own expiry.
    case expired
    /// The driver tapped Turn off.
    case turnedOff
    /// The app is being terminated.
    case terminated
    /// A different pass replaced this one.
    case replaced

    /// Only these three deserve the quiet "Auto heads-up is off." toast: the driver did not just
    /// take an action whose own screen already says so.
    var showsToast: Bool {
        switch self {
        case .capReached, .expired, .turnedOff: return true
        default: return false
        }
    }
}

nonisolated enum AutoDetectWindowPolicy {
    /// Hard cap on one window (spec 9 item 6, 7.4).
    static let maxDuration: TimeInterval = 60 * 60
    /// The window opens only when the leave time is this close (spec 7.4: "within 30 min"), or already past.
    static let openLead: TimeInterval = 30 * 60

    static func shouldOpen(now: Date, leaveAt: Date, expiresAt: Date) -> Bool {
        now < expiresAt && leaveAt.timeIntervalSince(now) <= openLead
    }

    /// The first of the 60 minute cap and the pass's own expiry.
    static func deadline(openedAt: Date, expiresAt: Date) -> Date {
        min(openedAt.addingTimeInterval(maxDuration), expiresAt)
    }

    /// Why a window whose deadline has passed ends: the pass expiring beats the cap.
    static func endReason(now: Date, expiresAt: Date) -> AutoDetectEndReason {
        now >= expiresAt ? .expired : .capReached
    }
}

// MARK: - Availability

nonisolated enum AutoDetectAuthorization: Equatable, Sendable {
    case notDetermined
    /// When In Use or Always (we only ever REQUEST When In Use).
    case authorized
    case denied
}

/// What the armed screen shows about auto-detect.
nonisolated enum AutoDetectOffer: Equatable, Sendable {
    /// Flag off, or the build lacks the `location` background mode: nothing is shown, manual only.
    case hidden
    /// Opt-in needs a saved car as the anchor (design 5.4 "No saved car").
    case needsSavedCar
    case canEnable
    case locationDenied
    /// Opted in and ready, but the window is not open yet (leave time more than 30 min away, or the
    /// app has not been foregrounded since). It opens by itself, from the foreground.
    case waiting
    case on
}

nonisolated enum AutoDetectAvailability {

    /// Whether the feature exists at all in this build + flag state.
    static func isSupported(flagEnabled: Bool, backgroundModeDeclared: Bool) -> Bool {
        flagEnabled && backgroundModeDeclared
    }

    /// May a window OPEN right now.
    static func canRun(
        flagEnabled: Bool, backgroundModeDeclared: Bool, optedIn: Bool, hasAnchor: Bool,
        authorization: AutoDetectAuthorization
    ) -> Bool {
        isSupported(flagEnabled: flagEnabled, backgroundModeDeclared: backgroundModeDeclared)
            && optedIn && hasAnchor && authorization == .authorized
    }

    static func offer(
        flagEnabled: Bool, backgroundModeDeclared: Bool, optedIn: Bool, hasAnchor: Bool,
        authorization: AutoDetectAuthorization, isRunning: Bool
    ) -> AutoDetectOffer {
        guard isSupported(flagEnabled: flagEnabled, backgroundModeDeclared: backgroundModeDeclared) else { return .hidden }
        if isRunning { return .on }
        guard hasAnchor else { return .needsSavedCar }
        if authorization == .denied { return .locationDenied }
        return optedIn ? .waiting : .canEnable
    }
}

// MARK: - Capability

nonisolated enum AutoDetectCapability {
    /// True only when THIS build declares the `location` background mode (the `SPOT_PASS_AUTODETECT`
    /// build setting). Without it, `CLBackgroundActivitySession` cannot keep updates alive in the
    /// background, so the feature degrades to manual only.
    static func backgroundModeDeclared(infoDictionary: [String: Any]?) -> Bool {
        guard let modes = infoDictionary?["UIBackgroundModes"] as? [String] else { return false }
        return modes.contains("location")
    }

    static func backgroundModeDeclared(bundle: Bundle = .main) -> Bool {
        backgroundModeDeclared(infoDictionary: bundle.infoDictionary)
    }
}
