//
//  ParkedCarDetailView.swift
//  WePark
//
//  W5: Sheet shown when the user taps the car-pin annotation on the map.
//
//  Content (top to bottom):
//    1. Severity color band (6pt, decorative, accessibilityHidden) — gray when no segment.
//    2. Header row — "My Car" + block label (or "Location saved (no parking data)") + ✕ button.
//    3. Safety label — first focusable a11y element. Omitted if no segment.
//    3b. FT-15/TF2-15 (§9.2): "Temporary restriction reported" banner — this is the
//        highest-value consumption point in the whole spec: telling someone whose car is
//        already parked on an affected block. Requires a resolved segment (no segment ==
//        no blockfaceKey to match against). Tap opens PinDetailSheet.
//    4. Parked-at relative timestamp — "Parked 3h ago".
//    5. [W7] Reminder toggle — "Remind me before parking changes".
//    6. Rules list — same RuleRow component as BlockDetailView.
//    7. "I left — clear pin" button (red tint).
//
//  Segment re-lookup: detectedSegmentID is resolved at sheet-open time by searching
//  the TileLoader segments array. If the tile has been evicted from the LRU cache,
//  lookup may return nil — the view shows "No parking data at this location" (AC-W5.9).
//
//  W7: Added per-pin reminder toggle (§3.C / §4.A). Flipping the toggle calls
//  ParkPinService.updateNotifyOnRestriction and re-evaluates notification scheduling.
//
//  No Calendar.current use. No import SwiftUI in Models/ or Services/.
//

import SwiftUI

// MARK: - ParkedCarDetailView

struct ParkedCarDetailView: View {

    // MARK: - Inputs

    let parkedCar: ParkedCar
    let engine: ParkingRulesEngine
    /// All currently-loaded segments — used to re-resolve the detectedSegmentID.
    let loadedSegments: [Segment]
    let onDismiss: () -> Void
    let onClearPin: () -> Void

    // MARK: - W7: Services for toggle actions

    /// W7: Reference to ParkPinService for updating notifyOnRestriction.
    /// Passed in from ContentView (same instance that owns parkedCar).
    let parkPinService: ParkPinService

    /// W7: Scheduler reference — needed to cancel/reschedule when toggle is flipped.
    let scheduler: NotificationScheduler

    // MARK: - FT-15 / TF2-15 (§9.2): Temporary restriction banner

    /// Pin service used to look up an active/upcoming block-scoped restriction covering
    /// the resolved segment. `nil` in previews/standalone use — the banner simply doesn't
    /// render (same optional-service pattern as `BlockDetailView.pinService`).
    let pinService: CommunityPinService?

    /// Called when the user taps the restriction banner. Passes the matched `CommunityPin`
    /// so the caller can present `PinDetailSheet` (reuses `activeSheet = .pinDetail(pin)`
    /// in ContentView). `nil` in previews/standalone use.
    let onOpenRestriction: ((CommunityPin) -> Void)?

    // MARK: - W7: Toggle state — initialized from the current car's persisted value.

    @State private var remindMe: Bool

    // MARK: - Init

    init(
        parkedCar: ParkedCar,
        engine: ParkingRulesEngine,
        loadedSegments: [Segment],
        parkPinService: ParkPinService,
        scheduler: NotificationScheduler = .shared,
        pinService: CommunityPinService? = nil,
        onDismiss: @escaping () -> Void,
        onClearPin: @escaping () -> Void,
        onOpenRestriction: ((CommunityPin) -> Void)? = nil
    ) {
        self.parkedCar = parkedCar
        self.engine = engine
        self.loadedSegments = loadedSegments
        self.parkPinService = parkPinService
        self.scheduler = scheduler
        self.pinService = pinService
        self.onDismiss = onDismiss
        self.onClearPin = onClearPin
        self.onOpenRestriction = onOpenRestriction
        _remindMe = State(initialValue: parkedCar.notifyOnRestriction)
    }

    // MARK: - Private

    /// Resolved segment at sheet-open time. Nil if detectedSegmentID is nil or tile evicted.
    private var resolvedSegment: Segment? {
        guard let sid = parkedCar.detectedSegmentID else { return nil }
        return loadedSegments.first { $0.id == sid }
    }

    /// FT-15/TF2-15 (§9.2): the block-scoped restriction pin covering the resolved segment,
    /// if any. Nil when there's no resolved segment (no blockfaceKey to match against) or
    /// no pinService injected (preview/standalone use).
    private var blockScopedRestriction: CommunityPin? {
        guard let seg = resolvedSegment else { return nil }
        return pinService?.blockScopedRestriction(forBlockfaceKey: seg.blockfaceKey)
    }

    /// Evaluate once at sheet-open time.
    private let now: Date = .nowET

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Severity color band.
            severityBand

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 2. Header row.
                    headerRow

                    // 3. Safety label (first focusable a11y element).
                    if let seg = resolvedSegment {
                        safetyLabelView(for: seg)
                    }

                    // 3b. FT-15/TF2-15 (§9.2): temporary restriction banner — the highest-
                    // value consumption point per the spec: telling someone whose car is
                    // already parked on an affected block.
                    if let restriction = blockScopedRestriction {
                        TemporaryRestrictionBanner(pin: restriction, now: pinService?.nowProvider() ?? now) {
                            onOpenRestriction?(restriction)
                        }
                    }

                    // 4. Parked-at relative timestamp.
                    parkedAtRow

                    // 5. W7: Reminder toggle.
                    reminderToggle

                    // 6. Rules list (only if we have a segment with rules).
                    if let seg = resolvedSegment, !seg.rules.isEmpty {
                        rulesSection(for: seg)
                    }

                    // 7. "I left" button.
                    iLeftButton
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Severity band

    private var severityBand: some View {
        let color: Color = {
            if let seg = resolvedSegment {
                return engine.currentStateColor(for: seg, at: now)
            }
            return Color(.systemGray4)
        }()
        return Rectangle()
            .fill(color)
            .frame(height: 6)
            .accessibilityHidden(true)
    }

    // MARK: - Header row

    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("My Car")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)

                Text(blockSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer()
            // ✕ close button (44pt tap target).
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close parked car details")
        }
    }

    /// Block subtitle line: "Bowery — North side · between Hester and Grand"
    /// Falls back to "Location saved (no parking data)" if no segment cached.
    private var blockSubtitle: String {
        guard let seg = resolvedSegment else {
            // Try to use cached street metadata from the ParkedCar itself.
            if let street = parkedCar.street, let side = parkedCar.detectedSide {
                let canonical = StreetNameNormalizer.canonical(street)
                let sideStr = sideLabel(side)
                if let from = parkedCar.fromStreet, let to = parkedCar.toStreet {
                    let fromStr = StreetNameNormalizer.canonical(from)
                    let toStr = StreetNameNormalizer.canonical(to)
                    return "\(canonical) \u{2014} \(sideStr) · between \(fromStr) and \(toStr)"
                }
                return "\(canonical) \u{2014} \(sideStr)"
            }
            return "Location saved (no parking data)"
        }
        let street = StreetNameNormalizer.canonical(seg.street)
        let side = sideLabel(seg.side)
        let from = StreetNameNormalizer.canonical(seg.fromStreet)
        let to = StreetNameNormalizer.canonical(seg.to)
        return "\(street) \u{2014} \(side) · between \(from) and \(to)"
    }

    // MARK: - Safety label

    private func safetyLabelView(for seg: Segment) -> some View {
        let label = engine.safetyLabel(for: seg, at: now)
        return Text(label.text)
            .font(.title.bold())
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            // First focusable a11y element (same discipline as BlockDetailView).
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Parked-at timestamp

    private var parkedAtRow: some View {
        Text("Parked \(relativeTime(from: parkedCar.parkedAt))")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// Formats the parked-at date as a human-readable relative string.
    /// Examples: "just now", "5m ago", "3h ago", "2d ago".
    /// Uses the ET calendar implicitly — parkedAt is a UTC wall-clock Date so
    /// the difference is calendar-agnostic.
    private func relativeTime(from date: Date) -> String {
        let diff = now.timeIntervalSince(date)
        if diff < 60 {
            return "just now"
        } else if diff < 3600 {
            let minutes = Int(diff / 60)
            return "\(minutes)m ago"
        } else if diff < 86400 {
            let hours = Int(diff / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(diff / 86400)
            return "\(days)d ago"
        }
    }

    // MARK: - W7: Reminder toggle

    private var reminderToggle: some View {
        Toggle(isOn: $remindMe) {
            Text("Remind me before parking changes")
                .font(.body)
        }
        .accessibilityLabel("Remind me before parking changes")
        .accessibilityHint("When on, you'll get a notification before your parking window ends.")
        .onChange(of: remindMe) { _, newValue in
            // Persist the updated preference.
            parkPinService.updateNotifyOnRestriction(newValue)
            if newValue {
                // Re-schedule notification (subject to global mute check inside scheduler).
                scheduler.schedule(
                    for: parkPinService.parkedCar ?? parkedCar,
                    loadedSegments: loadedSegments,
                    engine: engine
                )
            } else {
                // Cancel any pending notification for this pin.
                scheduler.cancelAll(for: parkedCar)
            }
        }
    }

    // MARK: - Rules list

    private func rulesSection(for seg: Segment) -> some View {
        let sortedRules = seg.rules.sorted { $0.category.priority < $1.category.priority }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sortedRules.enumerated()), id: \.offset) { _, rule in
                RuleRow(rule: rule)
            }
        }
    }

    // MARK: - "I left" button

    private var iLeftButton: some View {
        Button {
            onClearPin()
        } label: {
            Text("I left \u{2014} clear pin")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .accessibilityLabel("I left. Clear my parked car pin.")
        .padding(.top, 8)
    }

    // MARK: - Side label helper

    private func sideLabel(_ code: String) -> String {
        switch code.uppercased() {
        case "N": return "North side"
        case "S": return "South side"
        case "E": return "East side"
        case "W": return "West side"
        default:  return "\(code) side"
        }
    }
}

// MARK: - Preview

#Preview {
    let rule = ParkingRule(
        category: .aspMonThu,
        description: "NO PARKING 8-9:30AM MON & THUR",
        days: [1, 4],
        timeRanges: [TimeRange(start: 480, end: 570)],
        anytime: false,
        arrow: "both"
    )
    let ruleData = try! JSONEncoder().encode([rule])
    let rulesJSON = try! JSONSerialization.jsonObject(with: ruleData) as! [[String: Any]]
    let segDict: [String: Any] = [
        "id": "PREVIEW_SEG",
        "street": "BOWERY",
        "from": "HESTER STREET",
        "to": "GRAND STREET",
        "side": "N",
        "line": [[40.7183, -73.9942], [40.7190, -73.9940]],
        "rules": rulesJSON,
        "dominantCategory": "ASP_MON_THU"
    ]
    let segData = try! JSONSerialization.data(withJSONObject: segDict)
    let segment = try! JSONDecoder().decode(Segment.self, from: segData)

    let car = ParkedCar(
        id: UUID(),
        latitude: 40.7186,
        longitude: -73.9941,
        detectedSegmentID: "PREVIEW_SEG",
        detectedSide: "N",
        street: "BOWERY",
        fromStreet: "HESTER STREET",
        toStreet: "GRAND STREET",
        parkedAt: Date().addingTimeInterval(-3 * 3600),
        notifyOnRestriction: true
    )

    return ParkedCarDetailView(
        parkedCar: car,
        engine: ParkingRulesEngine(),
        loadedSegments: [segment],
        parkPinService: ParkPinService(),
        onDismiss: {},
        onClearPin: {}
    )
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
}
