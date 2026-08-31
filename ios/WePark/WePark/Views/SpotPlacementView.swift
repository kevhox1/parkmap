//
//  SpotPlacementView.swift
//  WePark
//
//  Community 2.0 Phase 2b (build 20 S7) — "Spot open" map-tap placement flow.
//  Spec: docs/community-2.0-reconciliation-spec.md §3 Phase 2 ("Spot placement").
//  Visual truth: design/screenshots/10-spot-placement.png, 11-spot-confirm.png.
//  Copy + values: design/prototype.html:85-102 (hint banner + confirm card markup),
//  806-830 (placeFromEvent / nearLabel logic).
//
//  Entry point: `ReportSheet`'s "Spot open" grid tile calls `onRequestSpotPlacement`,
//  which `ContentView` wires to `enterSpotPlacementMode()` — dismisses the report sheet and
//  starts intercepting map taps (mirroring the existing FT-15 block-select mode's
//  `blockSelectModeActive` shape). A tap snaps to the nearest segment + position fraction
//  via `CandidateSegmentSearch.nearestSegmentSnap(lat:lng:in:radius:)` (W5 haversine search,
//  extended). Within radius → `SpotPlacementDraft` is set, driving the confirm card below.
//  Outside radius → `ContentView` shows the "Tap closer to a curb" toast
//  (`design/prototype.html:821`) via the existing `ToastService`.
//
//  MapKit-POI storefront naming ("in front of The Elk", `fronts()` in the prototype) is
//  DEFERRED per spec §3 Phase 2's own scope cut — `SpotPlacementCopy.nearLabel` only ports
//  the simpler "near {cross street}" / "mid-block" fallback (`prototype.html:824-830`,
//  the `frac < 0.4` / `frac > 0.6` branches; the `fronts().length` branch is the deferred one).
//
//  Two views live in this one file (mirrors `ReportSheet.swift`'s own house style of
//  co-locating several small view builders + pure static helpers in one feature file):
//    - `SpotPlacementHintBanner` — the blue "Tap the curb where the spot is / Cancel" pill.
//    - `SpotPlacementConfirmCard` — "P Spot open — {street} ({side})" + near-label +
//      "Post it" / "Cancel" + the expiry/first-come-first-served footer.
//
//  Copy compliance (mirrors ReportSheet's AC-R17): no "avoid", "ticket", "fine", "evasion",
//  or "dodge" language anywhere in this file.
//

import SwiftUI
import CoreLocation

// MARK: - SpotPlacementDraft

/// The in-progress placement: a snapped segment + position, awaiting "Post it" / "Cancel".
/// Plain value type — `ContentView` holds this as `@State`, replacing it on every
/// subsequent tap while still in placement mode ("tap elsewhere to move the pin",
/// `design/prototype.html:102`).
struct SpotPlacementDraft {
    let segment: Segment
    let positionFraction: Double

    /// The exact point ON the segment's polyline at `positionFraction` (NOT the raw tap
    /// coordinate) — this is what gets written as the pin's `lat`/`lng`, so the eventual
    /// map marker renders snapped to the curb (AC-P2.4).
    let coordinate: CLLocationCoordinate2D
}

// MARK: - SpotPlacementCopy

/// Pure, `nonisolated` static copy-generation functions — directly unit-testable without a
/// SwiftUI view instance, matching `ReportSheet`'s own `buildMeta`/`locationContextLabel`
/// convention. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for this target — `nonisolated`
/// keeps these callable from a plain (non-MainActor) XCTest method.
enum SpotPlacementCopy {

    /// Port of the prototype's `nearLabel(segKey, frac)` (`design/prototype.html:824-830`),
    /// MINUS the deferred MapKit-POI-storefront branch (`f.length && frac > 0.3 && frac <
    /// 0.7` → "in front of {POI}"). Ships the simpler fallback only, per spec §3 Phase 2's
    /// explicit scope cut:
    ///   - `fraction < 0.4`  → "near {fromStreet}"
    ///   - `fraction > 0.6`  → "near {toStreet}"
    ///   - otherwise (0.4...0.6 inclusive) → "mid-block"
    /// Boundary values (exactly 0.4 or 0.6) fall through to "mid-block" — same strict
    /// `<`/`>` comparisons as the JS source, not `<=`/`>=`.
    nonisolated static func nearLabel(fraction: Double, fromStreet: String, toStreet: String) -> String {
        if fraction < 0.4 { return "near \(StreetNameNormalizer.canonical(fromStreet))" }
        if fraction > 0.6 { return "near \(StreetNameNormalizer.canonical(toStreet))" }
        return "mid-block"
    }

    /// Port of the prototype's `placeTitle` (`design/prototype.html:1012`):
    /// `tc(street) + ' (' + sideName(side).toLowerCase() + ')'`. Reuses
    /// `ReportSheet.sideDisplayName(_:)` (already shipped, already tested) rather than
    /// duplicating the N/S/E/W → "North side"/etc. switch a second time — only the
    /// `.lowercased()` step is new here.
    nonisolated static func confirmTitle(segment: Segment) -> String {
        "\(StreetNameNormalizer.canonical(segment.street)) (\(ReportSheet.sideDisplayName(segment.side).lowercased()))"
    }

    /// Port of the prototype's `placeSub` (`design/prototype.html:1013`):
    /// `nearLabel(...) + ' · btwn ' + tc(between[0]) + ' & ' + tc(between[1])`.
    nonisolated static func confirmSubtitle(segment: Segment, positionFraction: Double) -> String {
        let near = nearLabel(fraction: positionFraction, fromStreet: segment.fromStreet, toStreet: segment.to)
        return "\(near) · btwn \(StreetNameNormalizer.canonical(segment.fromStreet)) & \(StreetNameNormalizer.canonical(segment.to))"
    }

    /// Verbatim, `design/prototype.html:821` — shown when a tap lands farther than the
    /// candidate-search radius from any loaded segment.
    static let tapCloserToastMessage = "Tap closer to a curb"

    /// Verbatim, `design/prototype.html:87`.
    static let hintBannerTitle = "Tap the curb where the spot is"

    /// Verbatim footer, `design/prototype.html:102`.
    static let confirmFooter = "Expires in ~3 min · tap elsewhere to move the pin · first come, first served"
}

// MARK: - Shared color (community blue #0A84FF — palette-sacred per spec §6)

/// Small per-file hex→Color helper. Duplicated rather than shared, matching this codebase's
/// established house style for small, single-file needs (`CrewFeedSection`'s own
/// `fileprivate static func color(hex:)`; `CandidateSegmentSearch`'s own duplicated
/// geometry helpers, see that file's header comment for the same reasoning).
private func spotPlacementColor(hex: UInt32) -> Color {
    Color(
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255
    )
}

private let communityBlue = spotPlacementColor(hex: 0x0A84FF)

// MARK: - SpotPlacementHintBanner

/// The blue "Tap the curb where the spot is / Cancel" pill shown while placement mode is
/// active and no draft has been placed yet. Copy verbatim, `design/prototype.html:87-88`.
struct SpotPlacementHintBanner: View {

    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(SpotPlacementCopy.hintBannerTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(communityBlue, in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Placement mode: tap the curb where the spot is")
        .accessibilityHint("Double tap Cancel to exit placement mode")
    }
}

// MARK: - SpotPlacementConfirmCard

/// "P Spot open — {street} ({side})" confirm card, shown once a draft position exists.
/// Layout/copy per `design/screenshots/11-spot-confirm.png` + `design/prototype.html:92-103`.
struct SpotPlacementConfirmCard: View {

    /// `SpotPlacementCopy.confirmTitle(segment:)` result.
    let title: String
    /// `SpotPlacementCopy.confirmSubtitle(segment:positionFraction:)` result.
    let subtitle: String
    let onPost: () -> Void
    let onCancel: () -> Void
    var isSubmitting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 4) {
                Text("P")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(communityBlue)
                Text("Spot open — \(title)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(action: onPost) {
                    ZStack {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Post it")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(communityBlue, in: Capsule())
                .disabled(isSubmitting)
                .accessibilityLabel("Post it")
                .accessibilityHint("Posts the open-spot report at this position")

                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(Color(white: 0.46).opacity(0.16), in: Capsule())
                .disabled(isSubmitting)
            }

            Text(SpotPlacementCopy.confirmFooter)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(communityBlue.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}
