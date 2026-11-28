//
//  WPWindowClock.swift
//  WePark
//
//  R35 PR1 (docs/specs/r35-map-polish-and-trip-destination.md): ONE clock for the Stoop map.
//
//  The goal window the map is coloured for starts on a 5 minute grid (`instant`), never later
//  than the real "now". Every end (A few hours, Overnight, For days) is computed from that
//  instant, so the green, the headline end, the tile sub-line, the search card count and the
//  Free until picker all describe the same window. The green is computed for
//  [instant, end], which CONTAINS [now, end], so it can only be stricter than the exact window,
//  never looser. The countdown alone uses the live clock.
//
//  Pure Foundation, `nonisolated` (the project defaults to MainActor isolation) so sync tests
//  can call it directly.
//

import CoreLocation
import Foundation

nonisolated enum WPWindowClock {
    /// Recolor grid. The map is coloured for a window that starts on this grid.
    static let step: TimeInterval = 300

    /// Floors `now` to the grid. Epoch based; Eastern offsets are whole hours (including DST), so
    /// the grid is also wall-clock aligned in New York.
    static func instant(_ now: Date) -> Date {
        let t = now.timeIntervalSince1970
        guard t.isFinite else { return now }
        return Date(timeIntervalSince1970: (t / step).rounded(.down) * step)
    }

    /// R35-6: the instant goal copy ("Now → ...", the pill, the dock label) counts from. Stoop uses
    /// the later of the live clock and the window instant (the instant is never later than real
    /// now, so this is the live clock; `max` keeps it safe if the clock was set back) so day words
    /// and countdowns step with the minute, not every 5 minutes. The END stays on the 5 minute
    /// grid because it is computed from the instant. Flag off: the legacy live clock.
    static func goalCopyClock(stoop: Bool, instant: Date, live: Date) -> Date {
        stoop ? max(live, instant) : live
    }

    /// True when a recolor is due: the grid cell changed (either direction, so a clock that was set
    /// back also heals), or `now` is at or after the end the map is currently showing.
    static func needsRecolor(applied: Date, now: Date, displayedEnd: Date?) -> Bool {
        if instant(now) != applied { return true }
        if let displayedEnd, now >= displayedEnd { return true }
        return false
    }

    /// The `now` slot of the Plan a Trip classification cache key. Trip colour is a function of the
    /// plan alone (`TripPlanning.isFree`), so in Stoop the key uses the plan's arrival and survives
    /// every tick and recolor; flag off keeps the legacy `now` key.
    static func tripCacheStamp(arrival: Date, now: Date, stoop: Bool) -> Date {
        stoop ? arrival : now
    }

    /// Seconds to sleep so the next wake lands just after the next wall-clock minute boundary.
    static func secondsToNextMinute(from now: Date) -> TimeInterval {
        let t = now.timeIntervalSince1970
        guard t.isFinite else { return 60 }
        let into = t - (t / 60).rounded(.down) * 60
        return 60 - into + 0.5
    }
}

/// Order-independent fingerprint of what the overlay layer would draw. When the next payload has
/// the same fingerprint as the one on screen, publishing it would tear down and re-add identical
/// polylines (a flicker and wasted main-thread time), so the caller skips it.
nonisolated struct WPOverlaySignature: Equatable {
    private(set) var counts: [Int] = []
    private(set) var sums: [UInt64] = []
    private(set) var tail: UInt64 = 0

    /// `groups` are the polyline groups in a fixed order; `selected` the highlighted curb;
    /// `context` folds in anything else that changes the drawing (selected state, zoom band, detail
    /// mode, Drive Mode, outside-coverage).
    static func make(
        groups: [[[CLLocationCoordinate2D]]],
        selected: [CLLocationCoordinate2D]?,
        context: UInt64
    ) -> WPOverlaySignature {
        var sig = WPOverlaySignature()
        for group in groups {
            var sum: UInt64 = 0
            for line in group { sum = sum &+ lineHash(line) }   // wrapping sum: order independent
            sig.counts.append(group.count)
            sig.sums.append(sum)
        }
        var tail = context
        if let selected { tail = mix(tail &+ lineHash(selected)) } else { tail = mix(tail) }
        sig.tail = tail
        return sig
    }

    /// One polyline: point count plus first and last coordinate bits, mixed. Two segments with
    /// identical endpoints draw identically, so identity by geometry is exact for "what is drawn".
    static func lineHash(_ coords: [CLLocationCoordinate2D]) -> UInt64 {
        guard let first = coords.first, let last = coords.last else { return 0 }
        var h = mix(UInt64(truncatingIfNeeded: coords.count))
        h = mix(h ^ first.latitude.bitPattern)
        h = mix(h ^ first.longitude.bitPattern)
        h = mix(h ^ last.latitude.bitPattern)
        h = mix(h ^ last.longitude.bitPattern)
        return h
    }

    /// splitmix64 finalizer.
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Holder for the last published signature. A reference type on purpose (like
/// `OverlayClassificationCache`): mutating it must not invalidate the SwiftUI body.
nonisolated final class WPOverlaySignatureBox {
    var last: WPOverlaySignature?
    /// Debug counter: how many payloads were actually published (verifies "zero swaps in a cell").
    var publishCount = 0
    var skipCount = 0
    init() {}

    /// True when the payload with `signature` should be published; records it when so.
    func shouldPublish(_ signature: WPOverlaySignature) -> Bool {
        if last == signature { skipCount += 1; return false }
        last = signature
        publishCount += 1
        return true
    }
}

/// R35-8: which end the map and the drive cards use for the ACTIVE goal. A For days pick only
/// ever applies to the For days goal; a leftover pick must never leak into Overnight or A few hours.
nonisolated enum WPGoalEnd {
    static func end(goal: ParkingGoal, now: Date, morningHour: Int, manualForDaysEffective: Date?) -> Date {
        if goal == .parkAndForget, let manualForDaysEffective { return manualForDaysEffective }
        return ParkingGoals.target(for: goal, from: now, overnightMorningHour: morningHour)
    }
}
