//
//  CurbPlacementCard.swift
//  WePark
//
//  Stream A3 of the fixed-center-pin amendment (docs/longpress-universal-plant-spec.md
//  "Amendment", section A.4) as amended by the Stream B design review
//  (docs/design/curb-pin-placement-design.md - AUTHORITATIVE where the two differ).
//
//  Two halves, kept apart so the decisions are unit-testable with no view:
//    1. `CurbPlacementCardModel` - a PURE value built from the latest snap outcome: every
//       string, label, route and enabled-state the card shows. Status wording is the rules
//       engine's `safetyLabel(for:at:)` VERBATIM (never a second formatter - AC-A9); street and
//       side use the same helpers `ReportSheet`'s confirm rows use.
//    2. `CurbPlacementOverlay` - the SwiftUI layer: the bottom-docked card, the labelled Cancel
//       capsule, the locate button and the first-use hint pill. NOT a sheet and NOT an
//       `ActiveSheet` case (a sheet over a live panning map is the #118 failure class).
//
//  Design numbers honoured here (design review section 3): opaque `secondarySystemBackground`
//  card with `Color(.label)` text (never `.secondary`, never a material, never `.opacity()` on an
//  element); a 60 pt white-capsule primary (`Color(.label)` fill, `Color(.systemBackground)`
//  label - system-blue prominent fails 4.5:1); a status chip with a leading SF Symbol so state is
//  never carried by hue alone; a 48 pt "Report something here" list row 12 pt below the primary;
//  a labelled Cancel capsule; reserved rows so the card never changes height while panning; a
//  card height cap with the text rows scrolling and the buttons pinned; VoiceOver: an adjustable
//  summary element that cycles nearby curbs. Chrome is monochrome - colour appears only as the
//  status chip (data).
//
//  Layout is only provable live: the mandatory Mac smoke (PR body) covers sizes, Dynamic Type
//  and VoiceOver.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode on this machine - Kevin verifies on his Mac.
//

import SwiftUI
import UIKit
import CoreLocation

// MARK: - Copy

/// Every user-visible string of the mode in one place (A27: none of the banned words).
nonisolated enum CurbPlacementCardCopy {
    static let parkHere = "Park here"
    static let next = "Next"
    /// Spec A.3 "No curb in range": Park intent stays enabled with this label (design section
    /// 3.3 proposes moving "(no parking info)" into the body instead; the spec string is kept,
    /// and the body ALSO says it - flip is a one-line change here).
    static let saveCarHere = "Save car here (no parking info)"
    static let reportSomethingHere = "Report something here"
    static let noCurbTitle = "No curb here"
    static let noCurbSubtitle = "Move the map until the pin is near a street"
    static let loadingTitle = "Loading curbs\u{2026}"
    /// Outside coverage / no tiles after the loading timeout (PR #143 QA #2): an honest state,
    /// never an indefinite spinner. Park and the report path both still work.
    static let noDataTitle = "No parking data here"
    static let noDataParkSubtitle = "You can still save your car at this spot"
    static let noDataReportSubtitle = "You can still send a report for this spot"
    static let farCurbFootnote = "Nearest curb with data"
    static let hint = "Drag the map to place the pin"
    static let cancel = "Cancel"
    static let locateLabel = "Center on my location"

    /// Spec A.3: the footnote appears when the snap distance exceeds this AND no opposite-side
    /// segment is loaded.
    static let farCurbThresholdMeters: Double = 15
}

// MARK: - Status tone

/// The chip's colour tier, decoupled from `SafetyLabel.Severity` so the model stays
/// `Equatable` without a MainActor-isolated conformance.
nonisolated enum CurbPlacementStatusTone: Equatable {
    case free
    case comingSoon
    case metered
    case restricted
    case unknown

    static func tone(for severity: SafetyLabel.Severity) -> CurbPlacementStatusTone {
        switch severity {
        case .free:       return .free
        case .comingSoon: return .comingSoon
        case .metered:    return .metered
        case .restricted: return .restricted
        case .unknown:    return .unknown
        }
    }

    /// Design 3.2 row 3: a leading SF Symbol, same colour as the text, so the state never
    /// depends on hue alone.
    var symbolName: String {
        switch self {
        case .free:       return "checkmark.circle.fill"
        case .comingSoon: return "clock.fill"
        case .metered:    return "parkingsign.circle.fill"
        case .restricted: return "nosign"
        case .unknown:    return "questionmark.circle.fill"
        }
    }
}

// MARK: - Card state / action

nonisolated enum CurbPlacementCardState: Equatable {
    /// No outcome yet, or tiles / the index are still arriving - never "No curb here" (A13).
    case loading
    case snapped
    /// Snapped, but the curb is far and its opposite side has no data (A12).
    case farCurb
    case noCurb
    /// Outside coverage, or no tiles for the viewport once the loading timeout expired.
    case noData
}

/// What fills the card's single reserved status slot (design 3.3 "rows swapped": the nearest-curb
/// chip REPLACES the status text, so the card's height never depends on the state).
nonisolated enum CurbPlacementStatusSlot: Equatable {
    case statusChip
    case nearestCurbChip
    case progress
    case empty
}

/// Which handoff the primary button runs.
nonisolated enum CurbPlacementPrimaryAction: Equatable {
    /// Build the `PinDropIntent` and run the existing `confirmPinDrop(result:)`.
    case parkHere
    /// Same path with no segment (the "No curb here" Park).
    case saveCarHere
    /// Exit the mode and open the report chooser.
    case next
}

// MARK: - Model

nonisolated struct CurbPlacementCardModel: Equatable {
    let state: CurbPlacementCardState
    /// "STANTON ST · South side" (canonical street + `sideDisplayName`), or the empty-state title.
    let title: String
    /// "between BOWERY & CHRYSTIE ST", the empty-state hint, or nil while loading.
    let subtitle: String?
    /// `engine.safetyLabel(for:at:).text`, byte-for-byte; nil unless a curb owns the pin.
    let statusText: String?
    let statusTone: CurbPlacementStatusTone?
    /// "Nearest curb with data" in the far-curb state only.
    let footnote: String?
    let primaryTitle: String
    let primaryEnabled: Bool
    let primaryAction: CurbPlacementPrimaryAction
    /// Non-nil iff intent == .plant && communityEnabled (A-1). Always routes to the report sheet.
    let secondaryTitle: String?
    /// The tappable nearest-curb chip target (no-curb state only).
    let nearestCurb: CurbPlacementNearestCurb?
    /// Shows the spinner in the disabled primary / skeleton chip.
    let showsProgress: Bool
    let voiceOverValue: String
    let primaryHint: String
    let secondaryHint: String

    /// Pure builder. Parameters beyond the spec sketch are the honest-state inputs the sketch
    /// left implicit: `dataStatus` (A13 "Loading curbs..." while data is genuinely arriving,
    /// "No parking data here" when there is none - never an endless spinner, PR #143 QA #2),
    /// `oppositeSideLoaded` (A12 footnote), the chip target, and the locale's unit system.
    nonisolated static func make(
        outcome: CurbSnapOutcome?,
        intent: CurbPlacementIntent,
        communityEnabled: Bool,
        engine: ParkingRulesEngine,
        now: Date,
        dataStatus: CurbPlacementDataStatus,
        oppositeSideLoaded: Bool,
        nearestCurb: CurbPlacementNearestCurb?,
        usesMetricSystem: Bool
    ) -> CurbPlacementCardModel {
        let isReport: Bool
        let isPlant: Bool
        switch intent {
        case .report:
            isReport = true
            isPlant = false
        case .plant:
            isReport = false
            isPlant = true
        case .park, .parkBlock:
            isReport = false
            isPlant = false
        }
        let secondaryTitle: String? = (isPlant && communityEnabled) ? CurbPlacementCardCopy.reportSomethingHere : nil
        let nextHint = "Opens report options for this spot."

        // Resolve the outcome into one of: nothing yet, a snapped curb, or no curb in range.
        var snappedResult: CurbSnapResult?
        if let outcome {
            switch outcome {
            case .snapped(let result):
                snappedResult = result
            case .noCurbInRange:
                break
            }
        }

        // A snapped curb always wins. Without one, the data status decides: genuinely loading
        // (bounded by the caller's timeout), nothing to load, or a real "no curb here".
        var isLoading = false
        var isNoData = false
        if snappedResult == nil {
            switch dataStatus {
            case .loading: isLoading = true
            case .noData:  isNoData = true
            case .ready:   break
            }
        }
        if isLoading {
            let title = isReport ? CurbPlacementCardCopy.next : CurbPlacementCardCopy.parkHere
            return CurbPlacementCardModel(
                state: .loading,
                title: CurbPlacementCardCopy.loadingTitle,
                subtitle: nil,
                statusText: nil,
                statusTone: nil,
                footnote: nil,
                primaryTitle: title,
                primaryEnabled: false,
                primaryAction: isReport ? .next : .parkHere,
                secondaryTitle: secondaryTitle,
                nearestCurb: nil,
                showsProgress: true,
                voiceOverValue: "Loading curbs",
                primaryHint: isReport ? nextHint : "Available when a curb is found.",
                secondaryHint: nextHint
            )
        }

        // NO DATA: honest, and never a dead end - Park saves with no segment, Next continues with
        // segment: nil (the legacy flow worked out here too).
        if isNoData {
            let primaryTitle = isReport ? CurbPlacementCardCopy.next : CurbPlacementCardCopy.saveCarHere
            let action: CurbPlacementPrimaryAction = isReport ? .next : .saveCarHere
            let subtitle = isReport ? CurbPlacementCardCopy.noDataReportSubtitle : CurbPlacementCardCopy.noDataParkSubtitle
            return CurbPlacementCardModel(
                state: .noData,
                title: CurbPlacementCardCopy.noDataTitle,
                subtitle: subtitle,
                statusText: nil,
                statusTone: nil,
                footnote: nil,
                primaryTitle: primaryTitle,
                primaryEnabled: true,
                primaryAction: action,
                secondaryTitle: secondaryTitle,
                nearestCurb: nil,
                showsProgress: false,
                voiceOverValue: CurbPlacementCardCopy.noDataTitle + ". " + subtitle + ".",
                primaryHint: isReport ? nextHint : "Saves your car at this spot. No parking information is available here.",
                secondaryHint: nextHint
            )
        }

        // NO CURB: never a dead end - Park saves with no segment, Next continues with segment: nil.
        guard let snapped = snappedResult else {
            let primaryTitle = isReport ? CurbPlacementCardCopy.next : CurbPlacementCardCopy.saveCarHere
            let action: CurbPlacementPrimaryAction = isReport ? .next : .saveCarHere
            let hint = isReport ? nextHint : "Saves your car at this spot. No parking information is available here."
            return CurbPlacementCardModel(
                state: .noCurb,
                title: CurbPlacementCardCopy.noCurbTitle,
                subtitle: CurbPlacementCardCopy.noCurbSubtitle,
                statusText: nil,
                statusTone: nil,
                footnote: nil,
                primaryTitle: primaryTitle,
                primaryEnabled: true,
                primaryAction: action,
                secondaryTitle: secondaryTitle,
                nearestCurb: nearestCurb,
                showsProgress: false,
                voiceOverValue: "No curb here. " + CurbPlacementCardCopy.noCurbSubtitle + ".",
                primaryHint: hint,
                secondaryHint: nextHint
            )
        }

        // SNAPPED (+ far-curb footnote).
        let segment = snapped.segment
        let streetCanonical = StreetNameNormalizer.canonical(segment.street)
        let fromCanonical = StreetNameNormalizer.canonical(segment.fromStreet)
        let toCanonical = StreetNameNormalizer.canonical(segment.to)
        let sideName = ReportSheet.sideDisplayName(segment.side)
        let label = engine.safetyLabel(for: segment, at: now)
        let isFar = snapped.distanceMeters > CurbPlacementCardCopy.farCurbThresholdMeters && !oppositeSideLoaded

        let spokenStreet = expandedStreetName(streetCanonical)
        let spokenFrom = expandedStreetName(fromCanonical)
        let spokenTo = expandedStreetName(toCanonical)
        var spoken = "\(spokenStreet), \(sideName), between \(spokenFrom) and \(spokenTo). \(label.text)."
        if isFar { spoken += " " + CurbPlacementCardCopy.farCurbFootnote + "." }

        return CurbPlacementCardModel(
            state: isFar ? .farCurb : .snapped,
            title: "\(streetCanonical) \u{00B7} \(sideName)",
            subtitle: "between \(fromCanonical) & \(toCanonical)",
            statusText: label.text,
            statusTone: CurbPlacementStatusTone.tone(for: label.severity),
            footnote: isFar ? CurbPlacementCardCopy.farCurbFootnote : nil,
            primaryTitle: isReport ? CurbPlacementCardCopy.next : CurbPlacementCardCopy.parkHere,
            primaryEnabled: true,
            primaryAction: isReport ? .next : .parkHere,
            secondaryTitle: secondaryTitle,
            nearestCurb: nil,
            showsProgress: false,
            voiceOverValue: spoken,
            primaryHint: isReport ? nextHint : "Saves your car on \(spokenStreet), \(sideName).",
            secondaryHint: nextHint
        )
    }

    // MARK: Reserved status slot (card height is constant, PR #143 QA #3)

    /// The ONE thing that fills the status slot in this state. The slot is always a 44 pt row;
    /// chip, nearest-curb chip, spinner and the empty placeholder are interchangeable inside it,
    /// so a state change never changes the card's height (and never drives a margin write
    /// mid-pan).
    var statusSlot: CurbPlacementStatusSlot {
        if statusText != nil { return .statusChip }
        if nearestCurb != nil { return .nearestCurbChip }
        if showsProgress { return .progress }
        return .empty
    }

    // MARK: Pure helpers

    /// "STANTON ST" -> "Stanton Street", "W 14 ST" -> "West 14 Street", "1 AVE" -> "1 Avenue"
    /// (design polish 17: VoiceOver should not spell out "S T").
    nonisolated static func expandedStreetName(_ canonical: String) -> String {
        let words = canonical.split(separator: " ")
        var spoken: [String] = []
        for word in words {
            let token = String(word).uppercased()
            switch token {
            case "ST":   spoken.append("Street")
            case "AVE":  spoken.append("Avenue")
            case "BLVD": spoken.append("Boulevard")
            case "PL":   spoken.append("Place")
            case "RD":   spoken.append("Road")
            case "DR":   spoken.append("Drive")
            case "PKWY": spoken.append("Parkway")
            case "LN":   spoken.append("Lane")
            case "CT":   spoken.append("Court")
            case "HWY":  spoken.append("Highway")
            case "SQ":   spoken.append("Square")
            case "TER":  spoken.append("Terrace")
            case "E":    spoken.append("East")
            case "W":    spoken.append("West")
            case "N":    spoken.append("North")
            case "S":    spoken.append("South")
            default:
                let first = token.prefix(1)
                let rest = token.dropFirst().lowercased()
                spoken.append(String(first) + rest)
            }
        }
        return spoken.joined(separator: " ")
    }

    /// Design 3.6 / 3.5: the card may not exceed `fullScreenHeight - (tipY + 130)` (381 pt on an
    /// 852 pt screen), so it can never cover the pin, ghost or highlight. `tipFraction` is
    /// `CurbPlacementMapPolicy.tipHeightFraction`, passed in (no constant reads in here).
    nonisolated static func maxCardHeight(fullScreenHeight: Double, tipFraction: Double) -> Double {
        guard fullScreenHeight.isFinite, fullScreenHeight > 0 else { return 0 }
        return max(0, fullScreenHeight - (tipFraction * fullScreenHeight + 130))
    }

    // MARK: Nearest-curb chip

    /// "Nearest curb 150 ft" (US) / "Nearest curb 50 m" (metric); distance rounded to 10, min 10.
    nonisolated static func nearestCurbChipText(_ curb: CurbPlacementNearestCurb, usesMetricSystem: Bool) -> String {
        let value = roundedDistance(curb.distanceMeters, usesMetricSystem: usesMetricSystem)
        return "Nearest curb \(value) " + (usesMetricSystem ? "m" : "ft")
    }

    /// "Nearest curb is 150 feet north-east" (VoiceOver label).
    nonisolated static func nearestCurbAccessibilityLabel(_ curb: CurbPlacementNearestCurb, usesMetricSystem: Bool) -> String {
        let value = roundedDistance(curb.distanceMeters, usesMetricSystem: usesMetricSystem)
        let unit = usesMetricSystem ? "meters" : "feet"
        return "Nearest curb is \(value) \(unit) \(compassName(forBearing: curb.bearingDegrees))"
    }

    nonisolated static func roundedDistance(_ meters: Double, usesMetricSystem: Bool) -> Int {
        guard meters.isFinite, meters >= 0 else { return 10 }
        let raw = usesMetricSystem ? meters : meters * 3.28084
        let rounded = Int((raw / 10).rounded()) * 10
        return max(10, rounded)
    }

    /// 8-point compass name for a true bearing.
    nonisolated static func compassName(forBearing bearing: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        guard bearing.isFinite else { return names[0] }
        let normalized = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let index = Int(((normalized + 22.5) / 45).rounded(.down)) % 8
        return names[index]
    }

    /// Rotation for an arrow that points north at 0 deg: bearing minus the camera heading
    /// (design 3.3). The mode enters north-up; a rotated map is not observable from here.
    nonisolated static func arrowRotationDegrees(bearing: Double, cameraHeading: Double) -> Double {
        guard bearing.isFinite, cameraHeading.isFinite else { return 0 }
        return (bearing - cameraHeading + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - Layout metrics (pure; the height test lives on these)

/// The card's reserved geometry at the default Dynamic Type size. NOTHING here takes a card
/// state: every row is a fixed-size slot (title reserves 2 lines, subtitle 1 line and truncates,
/// the status slot is 44 pt whatever fills it, the footnote row is always reserved), which is
/// precisely why the height is invariant across states. Values are layout ESTIMATES for the cap
/// check; the live smoke confirms them on device.
nonisolated enum CurbPlacementCardLayout {
    static let topPadding: Double = 16
    static let titleBlock: Double = 56          // title2 bold, 2 reserved lines
    static let rowSpacing: Double = 4
    static let subtitleBlock: Double = 20       // subheadline, 1 reserved line
    static let statusTop: Double = 8
    static let statusSlot: Double = 44
    static let footnoteBlock: Double = 20       // always reserved
    static let primaryGap: Double = 16
    static let linkGap: Double = 12
    static let bottomPaddingWithLink: Double = 8
    static let bottomPaddingNoLink: Double = 16
    /// Design 3.5: the card may not cover the pin, ghost or highlight: it stays at least this far
    /// below the pin tip.
    static let minClearanceBelowTip: Double = 130

    /// Natural (uncapped) card height EXCLUDING the home-indicator zone.
    static func naturalHeight(hasLink: Bool, primaryHeight: Double, linkHeight: Double) -> Double {
        let text = titleBlock + rowSpacing + subtitleBlock + statusTop + statusSlot + rowSpacing + footnoteBlock
        let link = hasLink ? (linkGap + linkHeight) : 0
        let bottom = hasLink ? bottomPaddingWithLink : bottomPaddingNoLink
        return topPadding + text + primaryGap + primaryHeight + link + bottom
    }

    /// The height the card actually takes: natural, but never beyond the cap (the text rows
    /// scroll under the cap while the primary and link stay pinned).
    static func cappedHeight(
        hasLink: Bool,
        primaryHeight: Double,
        linkHeight: Double,
        fullScreenHeight: Double,
        bottomInset: Double,
        tipFraction: Double
    ) -> Double {
        let natural = naturalHeight(hasLink: hasLink, primaryHeight: primaryHeight, linkHeight: linkHeight)
        let cap = CurbPlacementCardModel.maxCardHeight(fullScreenHeight: fullScreenHeight, tipFraction: tipFraction)
        return min(natural + bottomInset, cap)
    }
}

// MARK: - Overlay

/// The whole placement UI layer. A plain value-in / closures-out view (no ContentView state).
///
/// Hit testing: the container has NO background, so the transparent areas around the controls
/// pass touches through to the map (the same property the other `VStack { Spacer(); card }`
/// map overlays rely on). Only the controls and the card are hit-testable.
struct CurbPlacementOverlay: View {

    let model: CurbPlacementCardModel
    let showsHint: Bool
    let usesMetricSystem: Bool
    /// Same value `recenterButtonStack` / the spot-placement banner use to clear the status
    /// bar and the ASP banner (`paddingForBannerState`).
    let topPadding: CGFloat
    /// `CurbPlacementMapPolicy.tipHeightFraction` (passed in so this file reads no constant).
    let tipFraction: CGFloat

    let onPrimary: (CurbPlacementPrimaryAction) -> Void
    let onSecondary: () -> Void
    let onCancel: () -> Void
    let onLocate: () -> Void
    let onNearestCurb: (CurbPlacementNearestCurb) -> Void
    let onCycleCurb: () -> Void
    /// Card height INCLUDING the home-indicator zone below it, in points. Fires on change only.
    let onCardHeightChange: (CGFloat) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hintVisible: Bool

    @ScaledMetric(relativeTo: .body) private var primaryHeight: CGFloat = 60
    @ScaledMetric(relativeTo: .body) private var linkHeight: CGFloat = 48

    init(
        model: CurbPlacementCardModel,
        showsHint: Bool,
        usesMetricSystem: Bool,
        topPadding: CGFloat,
        tipFraction: CGFloat,
        onPrimary: @escaping (CurbPlacementPrimaryAction) -> Void,
        onSecondary: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onLocate: @escaping () -> Void,
        onNearestCurb: @escaping (CurbPlacementNearestCurb) -> Void,
        onCycleCurb: @escaping () -> Void,
        onCardHeightChange: @escaping (CGFloat) -> Void
    ) {
        self.model = model
        self.showsHint = showsHint
        self.usesMetricSystem = usesMetricSystem
        self.topPadding = topPadding
        self.tipFraction = tipFraction
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        self.onCancel = onCancel
        self.onLocate = onLocate
        self.onNearestCurb = onNearestCurb
        self.onCycleCurb = onCycleCurb
        self.onCardHeightChange = onCardHeightChange
        _hintVisible = State(initialValue: showsHint)
    }

    // MARK: Body

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let fullHeight = proxy.size.height + insets.top + insets.bottom
            let tipY = tipFraction * fullHeight - insets.top
            let cardCap = CurbPlacementCardModel.maxCardHeight(
                fullScreenHeight: Double(fullHeight),
                tipFraction: Double(tipFraction)
            )
            ZStack(alignment: .top) {
                cancelRow
                hintPill(tipY: tipY, width: proxy.size.width)
                bottomStack(cardCap: CGFloat(cardCap), bottomInset: insets.bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Top row (Cancel)

    private var cancelRow: some View {
        HStack {
            Button(action: onCancel) {
                Label(CurbPlacementCardCopy.cancel, systemImage: "xmark")
                    .font(.headline)
                    .foregroundStyle(Color(.label))
                    .padding(.horizontal, 18)
                    .frame(minWidth: 96, minHeight: 48)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
                    .overlay(Capsule().stroke(Color(.opaqueSeparator), lineWidth: 1))
            }
            .buttonStyle(.plain)
            // Floating chrome must not grow over the pin at accessibility sizes (design 3.4).
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityLabel(CurbPlacementCardCopy.cancel)
            .accessibilityHint("Returns to the map without saving.")
            .accessibilitySortPriority(100)
            Spacer()
        }
        .padding(.leading, 16)
        .padding(.top, topPadding)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Hint pill

    @ViewBuilder
    private func hintPill(tipY: CGFloat, width: CGFloat) -> some View {
        if hintVisible {
            // Bottom edge 12 pt above the needle head's top (head 44 + stem 20 = 64 above the tip),
            // clamped so it never rides up into the Cancel row.
            let desiredCenterY = tipY - 64 - 12 - 18
            let minCenterY = topPadding + 48 + 8 + 18
            Text(CurbPlacementCardCopy.hint)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(.label))
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
                .overlay(Capsule().stroke(Color(.opaqueSeparator), lineWidth: 1))
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .position(x: width / 2, y: max(desiredCenterY, minCenterY))
                // The VoiceOver summary carries the same content.
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .task {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    hintVisible = false
                }
        }
    }

    // MARK: Bottom stack (locate + card)

    private func bottomStack(cardCap: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack {
                Spacer()
                locateButton
            }
            .padding(.trailing, 16)
            .padding(.bottom, 12)
            card(cardCap: cardCap, bottomInset: bottomInset)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var locateButton: some View {
        Button(action: onLocate) {
            Image(systemName: "location.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(.label))
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color(.secondarySystemBackground)))
                .overlay(Circle().stroke(Color(.opaqueSeparator), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CurbPlacementCardCopy.locateLabel)
        .accessibilitySortPriority(10)
    }

    // MARK: Card

    private func card(cardCap: CGFloat, bottomInset: CGFloat) -> some View {
        let hasLink = model.secondaryTitle != nil
        // The VStack ends at the SAFE bottom; the home-indicator zone below it is background
        // only (`cardBackground` ignores the bottom safe area), so `bottomInset` is not padding.
        let bottomPadding: CGFloat = hasLink ? 8 : 16
        // Everything that is pinned (never scrolled away): top padding + primary + its gap +
        // the link row + bottom padding. The text rows get whatever the cap leaves.
        let pinned = 16 + primaryHeight + 16 + (hasLink ? (12 + linkHeight) : 0) + bottomPadding
        let textCap = max(44, cardCap - bottomInset - pinned)
        return VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .vertical) {
                textRows
                ScrollView(.vertical) { textRows }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: textCap)
            primaryButton
                .padding(.top, 16)
            if let link = model.secondaryTitle {
                linkRow(title: link)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
            // Card top to the physical screen bottom: what the Apple logo must clear.
            onCardHeightChange(newHeight + bottomInset)
        }
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(90)
    }

    private var cardBackground: some View {
        UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
            .fill(Color(.secondarySystemBackground))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                    .stroke(Color(.opaqueSeparator), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: -2)
            .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: Text rows (the adjustable VoiceOver summary)

    /// Every row is a FIXED slot so the card's height is constant across states (design Finding
    /// 8; `CurbPlacementCardLayout`): the title reserves 2 lines (4 at accessibility sizes) and the
    /// subtitle 1 line (2), both truncating rather than wrapping further; the status slot is one
    /// 44 pt row that the status chip, the nearest-curb chip or the loading skeleton fill in turn;
    /// the footnote row is always reserved.
    private var textRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The title carries the adjustable VoiceOver summary for the whole text block (the
            // other rows are hidden from VoiceOver so nothing is read twice; the tappable
            // nearest-curb chip is NOT hidden - it is its own control).
            Text(model.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color(.label))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Parking spot")
                .accessibilityValue(model.voiceOverValue)
                .accessibilityHint("Swipe up or down to choose a nearby curb. Three-finger swipe pans the map.")
                .accessibilityAdjustableAction { _ in
                    // Increment and decrement both step to the next nearby curb.
                    onCycleCurb()
                }
                .accessibilitySortPriority(3)
            Text(model.subtitle ?? " ")
                .font(.subheadline)
                .foregroundStyle(Color(.label))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            statusSlotView
                .padding(.top, 8)
            footnoteSlot
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The reserved 44 pt status row (see `CurbPlacementCardModel.statusSlot`).
    @ViewBuilder
    private var statusSlotView: some View {
        switch model.statusSlot {
        case .statusChip:
            if let text = model.statusText, let tone = model.statusTone {
                statusChip(text: text, tone: tone)
                    .accessibilityHidden(true)
            }
        case .nearestCurbChip:
            if let curb = model.nearestCurb {
                nearestCurbChip(curb)
            }
        case .progress:
            HStack(spacing: 10) {
                ProgressView()
                Text(CurbPlacementCardCopy.loadingTitle)
                    .font(.headline)
                    .foregroundStyle(Color(.label))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.systemGray4)))
            .accessibilityHidden(true)
        case .empty:
            Color.clear.frame(height: 44)
        }
    }

    /// Always-reserved footnote row ("Nearest curb with data" or blank).
    private var footnoteSlot: some View {
        Group {
            if let footnote = model.footnote {
                Label(footnote, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Color(.label))
                    .accessibilityHidden(true)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, minHeight: CGFloat(CurbPlacementCardLayout.footnoteBlock), alignment: .leading)
    }

    private func statusChip(text: String, tone: CurbPlacementStatusTone) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tone.symbolName)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.headline)
        .foregroundStyle(CurbPlacementOverlay.chipTextColor(for: tone))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CurbPlacementOverlay.chipFill(for: tone)))
    }

    // MARK: Nearest-curb chip (no-curb state; lives IN the status slot)

    private func nearestCurbChip(_ curb: CurbPlacementNearestCurb) -> some View {
        Button {
            onNearestCurb(curb)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "location.north.fill")
                    .rotationEffect(.degrees(CurbPlacementCardModel.arrowRotationDegrees(
                        bearing: curb.bearingDegrees,
                        cameraHeading: 0
                    )))
                Text(CurbPlacementCardModel.nearestCurbChipText(curb, usesMetricSystem: usesMetricSystem))
                    .lineLimit(1)
            }
            .font(.headline)
            .foregroundStyle(Color(.label))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Capsule().fill(Color(.systemGray4)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CurbPlacementCardModel.nearestCurbAccessibilityLabel(curb, usesMetricSystem: usesMetricSystem))
        .accessibilityHint("Moves the pin there.")
        .accessibilitySortPriority(2)
    }

    // MARK: Primary + link

    private var primaryButton: some View {
        Button {
            if model.primaryEnabled {
                switch model.primaryAction {
                case .parkHere, .saveCarHere:
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .next:
                    break
                }
                onPrimary(model.primaryAction)
            }
        } label: {
            HStack(spacing: 10) {
                Text(model.primaryTitle)
                    .font(.headline.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if model.showsProgress {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: primaryHeight)
        }
        .buttonStyle(CurbPlacementPrimaryButtonStyle(enabled: model.primaryEnabled))
        .disabled(!model.primaryEnabled)
        .accessibilityLabel(model.primaryTitle)
        .accessibilityHint(model.primaryHint)
        .accessibilitySortPriority(1)
    }

    private func linkRow(title: String) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
            Button(action: onSecondary) {
                HStack {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(.label))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(Color(.label))
                }
                .frame(minHeight: linkHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.primaryEnabled)
            .accessibilityLabel(title)
            .accessibilityHint(model.secondaryHint)
        }
    }

    // MARK: Chip palette (TF2-18 anatomy: solid fill + dark text; unknown per design 3.2)

    private static let amberChipText = Color(red: 0.15, green: 0.10, blue: 0.0)

    static func chipFill(for tone: CurbPlacementStatusTone) -> Color {
        switch tone {
        case .free:       return ParkingColors.freeComfortably
        case .comingSoon: return ParkingColors.restrictionComingSoon
        case .metered:    return ParkingColors.meteredActive
        case .restricted: return ParkingColors.restricted
        case .unknown:    return Color(.systemGray4)
        }
    }

    static func chipTextColor(for tone: CurbPlacementStatusTone) -> Color {
        switch tone {
        case .free, .comingSoon, .restricted: return .black
        case .metered:                         return CurbPlacementOverlay.amberChipText
        case .unknown:                         return Color(.label)
        }
    }
}

// MARK: - Primary button style

/// Monochrome capsule: `Color(.label)` fill with a `Color(.systemBackground)` label (white-on-black
/// in the forced-dark app, 21:1). Pressed state is a distinct solid grey; disabled is
/// `systemGray4` with a `Color(.label)` label. No `.opacity()` anywhere (design 3.2 row 5).
struct CurbPlacementPrimaryButtonStyle: ButtonStyle {
    let enabled: Bool

    private static let pressedFill = Color(uiColor: UIColor { (traits: UITraitCollection) -> UIColor in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.82, alpha: 1) : UIColor(white: 0.25, alpha: 1)
    })

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color(.systemBackground) : Color(.label))
            .padding(.horizontal, 16)
            .background(
                Capsule().fill(fill(isPressed: configuration.isPressed))
            )
            .contentShape(Capsule())
    }

    private func fill(isPressed: Bool) -> Color {
        guard enabled else { return Color(.systemGray4) }
        return isPressed ? CurbPlacementPrimaryButtonStyle.pressedFill : Color(.label)
    }
}
