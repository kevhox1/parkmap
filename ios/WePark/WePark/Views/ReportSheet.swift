//
//  ReportSheet.swift
//  WePark
//
//  Tier 3 Sub-PR #2 — Universal Community Reporting.
//  Spec: docs/tier3-patrol-report-spec.md §3.4 / §6.
//
//  Entry points:
//   - Resting long-press on map → confirmationDialog "Report enforcement or sweeper"
//     → ActiveSheet.reportPin(coord: <long-press-coord>)
//   - In-drive "Report" button tap → ActiveSheet.reportPin(coord: <current-GPS>)
//
//  Both paths present the same ReportSheet; the coordinate is injected at presentation time.
//
//  Write path: calls CommunityPinService.insertCrowdPin(type:meta:lat:lng:segmentId:zoneId:notes:).
//  meta: [String: Any]? is built from EnforcementActiveMeta / SweeperPassedMeta serialized to
//  a dictionary matching the JSONB column shape.
//
//  Copy compliance (AC-R17): no "avoid", "ticket", "fine", "evasion", or "dodge" language.
//
//  Marker icons (spec §9 — @designer note):
//   - enforcement_active: shield.fill (blue) — placeholder per spec §9.1.
//     No docs/design/tier3-marker-icons.md found at build time; placeholder used.
//   - sweeper_passed: exclamationmark.triangle.fill (orange) — placeholder per spec §9.2.
//     truck.box.fill is not available pre-iOS 18 (iOS 17 min target); using triangle instead.
//

import SwiftUI
import MapKit

// MARK: - ReportSheet

struct ReportSheet: View {

    // MARK: - Inputs

    /// The coordinate at which the pin will be dropped.
    ///
    /// Resting path: the long-press coordinate on the map.
    /// In-drive path: the user's current GPS at the moment the Report button was tapped.
    let coordinate: CLLocationCoordinate2D

    /// The community pin service — provides the authenticated write path.
    let pinService: CommunityPinService

    /// Called when the sheet should dismiss (on success or cancel).
    let onDismiss: () -> Void

    /// Bug #4: Resolved street/block name for the "Reporting on X" context line.
    ///
    /// In-drive path: injected from `drivingContext?.street` (the same street name
    /// shown in the DriveModeBottomCard). This is already resolved by the existing
    /// DrivingContextService segment search — no new resolution needed.
    ///
    /// Resting path: nil (no continuous GPS + segment search in resting mode).
    ///
    /// When non-nil, the sheet shows "Reporting on <streetName>" below the header.
    /// When nil, falls back to "Reporting at current location".
    var streetName: String? = nil

    // MARK: - Primary type selection

    enum ReportType {
        case enforcementActive
        case sweeper
    }

    // MARK: - Sweeper direction (per OQ-R5: both "passed" and "approaching")

    enum SweeperDirection: CaseIterable {
        case passed       // SweeperPassedMeta direction = "passed"
        case approaching  // SweeperPassedMeta direction = "coming_soon"

        var label: String {
            switch self {
            case .passed:     return "Sweeper passed"
            case .approaching: return "Sweeper approaching"
            }
        }

        var directionRawValue: String {
            switch self {
            case .passed:     return "passed"
            case .approaching: return "coming_soon"
            }
        }
    }

    // MARK: - State

    @State private var selectedType: ReportType? = nil
    @State private var selectedSubTag: EnforcementActiveMeta.SubTag? = nil
    @State private var sweeperDirection: SweeperDirection = .passed
    @State private var isSubmitting: Bool = false
    @State private var submitError: String? = nil

    // MARK: - Derived

    private var isReportEnabled: Bool {
        ReportSheet.isEnabled(selectedType: selectedType, isSubmitting: isSubmitting)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("What's happening?")
                        .font(.title2.weight(.semibold))
                    Text("Help your neighbors find safe parking.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // Bug #4: "Reporting on X" context line — surfaces the resolved block
                    // name so the user can confirm they are reporting on the correct street.
                    // In-drive: streetName comes from drivingContext?.street (DrivingContextService).
                    // Resting: streetName is nil → fallback label shown.
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(ReportSheet.locationContextLabel(streetName: streetName))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {

                        // MARK: Primary type rows

                        // Row 1: Enforcement active
                        reportTypeRow(
                            label: "Enforcement active",
                            sublabel: "Officer or cleaning truck on the block",
                            symbolName: "shield.fill",
                            tintColor: .blue,
                            type: .enforcementActive
                        )

                        // Sub-tag picker: visible only when Enforcement active is selected
                        if selectedType == .enforcementActive {
                            subTagPickerRow
                                .padding(.leading, 20)
                                .padding(.bottom, 4)
                        }

                        // Row 2: Sweeper
                        reportTypeRow(
                            label: "Street sweeper",
                            sublabel: "Sweeping truck on or near this block",
                            symbolName: "exclamationmark.triangle.fill",
                            tintColor: .orange,
                            type: .sweeper
                        )

                        // Sweeper direction toggle: visible only when sweeper is selected
                        if selectedType == .sweeper {
                            sweeperDirectionRow
                                .padding(.leading, 20)
                                .padding(.bottom, 4)
                        }

                    }
                    .padding(.vertical, 12)
                }

                Divider()

                // MARK: Error + CTA

                VStack(spacing: 12) {
                    if let error = submitError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await submitReport() }
                    } label: {
                        ZStack {
                            if isSubmitting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Text("Report")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(isReportEnabled ? Color.accentColor : Color.secondary.opacity(0.4))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!isReportEnabled)
                    .accessibilityLabel("Submit report")
                    .accessibilityHint("Reports the selected condition at this location.")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
    }

    // MARK: - Report type row builder

    @ViewBuilder
    private func reportTypeRow(
        label: String,
        sublabel: String,
        symbolName: String,
        tintColor: Color,
        type: ReportType
    ) -> some View {
        let isSelected = selectedType == type
        Button {
            selectedType = type
            // Reset sub-state when type changes
            if type != .enforcementActive { selectedSubTag = nil }
            if type != .sweeper { sweeperDirection = .passed }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? tintColor : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isSelected ? .primary : .primary)
                    Text(sublabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(tintColor)
                        .font(.system(size: 20))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(isSelected ? tintColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Sub-tag picker row (Enforcement sub-types, per AC-R14)

    /// Horizontal pill row. Order: Cleaning truck first (per OQ-R2 / community-1.0-direction §6).
    /// "Not sure" maps to nil (no sub_tag). Default is no selection (nil).
    @ViewBuilder
    private var subTagPickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What kind?")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    subTagPill(label: "Cleaning truck",   tag: .cleaningTruck)
                    subTagPill(label: "Parking agent",    tag: .parkingAgent)
                    subTagPill(label: "Tow truck",        tag: .towTruck)
                    // "Not sure" maps to nil — explicitly tapping deselects
                    Button {
                        selectedSubTag = nil
                    } label: {
                        Text("Not sure")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selectedSubTag == nil ? Color.blue.opacity(0.15) : Color(.systemGray6))
                            .foregroundStyle(selectedSubTag == nil ? .blue : .secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Not sure — no sub-type selected")
                    .accessibilityAddTraits(selectedSubTag == nil ? [.isSelected] : [])
                }
                .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func subTagPill(label: String, tag: EnforcementActiveMeta.SubTag) -> some View {
        let isSelected = selectedSubTag == tag
        Button {
            selectedSubTag = isSelected ? nil : tag
        } label: {
            Text(label)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue.opacity(0.15) : Color(.systemGray6))
                .foregroundStyle(isSelected ? .blue : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Sweeper direction row (per OQ-R5: "passed" + "approaching")

    @ViewBuilder
    private var sweeperDirectionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Direction?")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            HStack(spacing: 8) {
                ForEach(SweeperDirection.allCases, id: \.directionRawValue) { direction in
                    let isSelected = sweeperDirection == direction
                    Button {
                        sweeperDirection = direction
                    } label: {
                        Text(direction.label)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.orange.opacity(0.15) : Color(.systemGray6))
                            .foregroundStyle(isSelected ? .orange : .secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(direction.label)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Submit

    private func submitReport() async {
        guard let type = selectedType else { return }
        isSubmitting = true
        submitError = nil

        do {
            let (pinType, meta) = ReportSheet.buildMeta(
                type: type,
                subTag: selectedSubTag,
                sweeperDirection: sweeperDirection
            )
            try await pinService.insertCrowdPin(
                type: pinType,
                meta: meta,
                lat: coordinate.latitude,
                lng: coordinate.longitude,
                segmentId: nil,
                zoneId: nil,
                notes: nil
            )
            onDismiss()
        } catch {
            submitError = "Couldn't submit. Check your connection and try again."
        }

        isSubmitting = false
    }

    // MARK: - Meta builder (type → insertCrowdPin args)

    /// Pure static function: converts a report type + selection state into the
    /// `(PinType, [String: Any]?)` pair that `insertCrowdPin(type:meta:...)` expects.
    ///
    /// Static + explicit parameters = directly testable without a SwiftUI view instance.
    ///
    /// Mapping per spec §6 table:
    ///   enforcement_active + subTag? → PinType.enforcementActive + {sub_tag: <rawValue>} or nil
    ///   sweeper passed               → PinType.sweeperPassed + {direction: "passed"}
    ///   sweeper approaching          → PinType.sweeperPassed + {direction: "coming_soon"}
    static func buildMeta(
        type: ReportType,
        subTag: EnforcementActiveMeta.SubTag?,
        sweeperDirection: SweeperDirection
    ) -> (PinType, [String: Any]?) {
        switch type {
        case .enforcementActive:
            if let tag = subTag {
                return (.enforcementActive, ["sub_tag": tag.rawValue])
            }
            // No sub_tag selected → meta nil (matches the DB null-meta case for generic enforcement).
            return (.enforcementActive, nil)

        case .sweeper:
            let direction = sweeperDirection.directionRawValue
            return (.sweeperPassed, ["direction": direction])
        }
    }

    // MARK: - isReportEnabled (static, for test access)

    /// Returns whether the Report CTA should be enabled for the given selection state.
    ///
    /// Pure static function — testable without a SwiftUI view instance.
    static func isEnabled(selectedType: ReportType?, isSubmitting: Bool) -> Bool {
        selectedType != nil && !isSubmitting
    }

    // MARK: - locationContextLabel (static, for test access)

    /// Returns the "Reporting on X" context label for the given street name.
    ///
    /// Pure static function — testable without a SwiftUI view instance.
    ///
    /// - Parameter streetName: The resolved block/street name, or nil when unavailable.
    /// - Returns: "Reporting on <streetName>" when non-nil; "Reporting at current location" otherwise.
    static func locationContextLabel(streetName: String?) -> String {
        if let name = streetName, !name.isEmpty {
            return "Reporting on \(name)"
        }
        return "Reporting at current location"
    }
}
