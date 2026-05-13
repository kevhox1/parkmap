//
//  ParkConfirmView.swift
//  WePark
//
//  W5: Pin-drop confirmation sheet.
//
//  Presented as .sheet(item: $pinDropIntent).
//  Detents: .medium (default). Non-dismissible by swipe (.interactiveDismissDisabled(true)).
//  Dismiss paths: "Park here" confirm button OR "Cancel" button only.
//
//  Content (top to bottom):
//    1. Sheet title — "Park my car"
//    2. Detected block (or "No parking data" fallback)
//    3. "Wrong street?" alternatives (up to 3, from findCandidateSegments result)
//    4. Safety label for the detected segment
//    5. Action row — "Cancel" + "Park here" buttons
//
//  AC-W5.5: Tapping an alternative candidate re-assigns detectedSegment and
//  re-renders the block display and safety label. Pin lat/lng does not change.
//

import SwiftUI

struct ParkConfirmView: View {

    // MARK: - Inputs

    /// The in-flight intent. ParkConfirmView owns a mutable copy so the user can
    /// switch the detected segment via "Wrong street?" without mutating ContentView state.
    @State private var intent: PinDropIntent

    let engine: ParkingRulesEngine
    let onConfirm: (PinDropIntent) -> Void
    let onCancel: () -> Void

    // MARK: - Init

    init(
        intent: PinDropIntent,
        engine: ParkingRulesEngine,
        onConfirm: @escaping (PinDropIntent) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _intent = State(initialValue: intent)
        self.engine = engine
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    // MARK: - Time reference (stable for the sheet's lifetime)

    private let now: Date = .nowET

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Non-interactive drag indicator area handled by .presentationDragIndicator
            // Sheet title
            Text("Park my car")
                .font(.title2.bold())
                .padding(.top, 24)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Detected block section
                    detectedBlockSection

                    // "Wrong street?" alternatives
                    if !intent.alternativeCandidates.isEmpty {
                        alternativesSection
                    }

                    // Safety label (if segment available)
                    if let seg = intent.detectedSegment {
                        let label = engine.safetyLabel(for: seg, at: now)
                        Text(label.text)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }

                    // Action row
                    actionRow
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .interactiveDismissDisabled(true)
    }

    // MARK: - Detected block

    private var detectedBlockSection: some View {
        Group {
            if let seg = intent.detectedSegment {
                VStack(alignment: .leading, spacing: 4) {
                    Text(blockHeaderTitle(seg))
                        .font(.title3.bold())
                        .foregroundStyle(.primary)

                    Text(blockHeaderSubtitle(seg))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No parking data at this location")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Wrong street alternatives

    private var alternativesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wrong street? Nearby blocks:")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(intent.alternativeCandidates.prefix(3).enumerated()), id: \.offset) { _, candidate in
                Button {
                    // Swap the selected alternative into the detected position and
                    // rebuild the alternatives list so the new detected block is
                    // removed and the old detected block takes its place.
                    // This prevents showing the currently-detected block as an
                    // alternative simultaneously (QA Finding #2 / W5.1 Item 3).
                    let previousDetected = intent.detectedSegment
                    let previousDetectedDistance = intent.detectedSegmentDistance
                    // Update detected segment and its distance.
                    intent.detectedSegment = candidate.segment
                    intent.detectedSegmentDistance = candidate.distanceMeters
                    // Rebuild alternatives: remove the just-selected candidate,
                    // insert the previously-detected segment (with its real distance).
                    var newAlts = intent.alternativeCandidates.filter { $0.segment.id != candidate.segment.id }
                    if let prev = previousDetected {
                        let dist = previousDetectedDistance ?? candidate.distanceMeters
                        let prevCandidate = CandidateSegment(segment: prev, distanceMeters: dist)
                        newAlts.insert(prevCandidate, at: 0)
                    }
                    intent.alternativeCandidates = newAlts
                } label: {
                    HStack {
                        Text("\(StreetNameNormalizer.canonical(candidate.segment.street)) (\(Int(candidate.distanceMeters.rounded()))m)")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                onCancel()
            } label: {
                Text("Cancel")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Cancel parking here")

            Button {
                onConfirm(intent)
            } label: {
                Text("Park here")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Confirm parking at \(confirmAccessibilityStreet)")
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func blockHeaderTitle(_ seg: Segment) -> String {
        "\(StreetNameNormalizer.canonical(seg.street)) \u{2014} \(sideLabel(seg.side))"
    }

    private func blockHeaderSubtitle(_ seg: Segment) -> String {
        "between \(StreetNameNormalizer.canonical(seg.fromStreet)) and \(StreetNameNormalizer.canonical(seg.to))"
    }

    private func sideLabel(_ code: String) -> String {
        switch code.uppercased() {
        case "N": return "North side"
        case "S": return "South side"
        case "E": return "East side"
        case "W": return "West side"
        default:  return "\(code) side"
        }
    }

    private var confirmAccessibilityStreet: String {
        guard let seg = intent.detectedSegment else { return "this location" }
        return StreetNameNormalizer.canonical(seg.street)
    }
}

// MARK: - Preview

#Preview {
    // Minimal segment for the preview — no real tile data needed.
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

    let intent = PinDropIntent(
        pinLat: 40.7186,
        pinLng: -73.9941,
        detectedSegment: segment,
        alternativeCandidates: []
    )
    return ParkConfirmView(
        intent: intent,
        engine: ParkingRulesEngine(),
        onConfirm: { _ in },
        onCancel: {}
    )
    .presentationDetents([.medium])
}
