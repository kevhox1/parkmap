//
//  SyncedCarEnvelope.swift
//  WePark
//
//  Build 19: iCloud parked-car sync — wire format for `NSUbiquitousKeyValueStore`.
//  Spec: docs/icloud-parked-car-sync-spec.md §3.1.
//
//  One key, one envelope, in NSUbiquitousKeyValueStore.default (key: "wepark_synced_car_state").
//  `ParkedCar` itself is unchanged — this wraps it rather than extending it, so no existing
//  `ParkedCar` call site needs to change its signature.
//
//  No import SwiftUI — this is a pure data model (QA invariant, matches ParkedCar.swift).
//  No Calendar.current — updatedAt is a raw Date (UTC timestamp), same convention as
//  ParkedCar.parkedAt.
//

import Foundation

/// The envelope written to and read from the shared iCloud key-value store.
///
/// `updatedAt` is the merge comparator (last-write-wins), and is DELIBERATELY NOT the same
/// field as `car.parkedAt` — see spec §0.1 / §3.1. It is bumped on EVERY write to the
/// envelope: a fresh park, a per-pin notify-toggle edit (`updateNotifyOnRestriction`), or a
/// clear (`clearPin`, which writes a `.cleared` tombstone rather than removing the key —
/// see spec §3.2). For a fresh `.parked` envelope written by `save()`, `updatedAt ==
/// car.parkedAt`, so "the most recent park wins" (Kevin's original ruling) holds exactly in
/// the normal case; the extra layer only matters for edits that aren't a re-park.
///
/// NOT `Equatable`: the spec's own illustrative snippet (§3.1) declared `Equatable`, but
/// `ParkedCar` — explicitly out of scope for this feature ("Not touched", spec §3 file list)
/// — does not conform, so a synthesized `==` here would require touching that file. Nothing
/// in this feature's implementation or tests compares two full envelopes for equality (every
/// comparison is field-by-field: `.updatedAt`, `.kind`, `.car?.id`), so the conformance is
/// dropped rather than adding it to a file the spec named out of scope. Flagged in the PR
/// description as a deviation from the spec's literal declaration, not a silent substitution.
struct SyncedCarEnvelope: Codable {

    enum Kind: String, Codable {
        case parked
        case cleared
    }

    let kind: Kind

    /// Merge comparator. Strictly-greater-than wins (see `ParkPinService.applyRemoteChange`).
    let updatedAt: Date

    /// Present iff `kind == .parked`. `nil` for `.cleared` (the tombstone) — absence of a
    /// car is never represented by an absent envelope, only by a `.cleared` one. See spec
    /// §3.2 for why a missing key and a tombstone are not interchangeable.
    let car: ParkedCar?
}
