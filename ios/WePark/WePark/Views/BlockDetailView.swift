//
//  BlockDetailView.swift
//  WePark
//
//  W4: Block detail sheet shown when the user taps a colored polyline on the map.
//
//  Sheet content (top to bottom):
//    1. Severity color band (6pt, decorative, accessibilityHidden)
//    2. Block header — "<StreetName> — <SideLabel>" + "between X and Y"
//    3. Primary safety label (first focusable a11y element)
//    4. Rules list, ordered by Category.priority (most restrictive first)
//    5. "Park here →" stub button (disabled, W5 entry point)
//
//  No Calendar.current use anywhere. No import SwiftUI in Models/ or Services/.
//  All view-level helpers (side label, days compact string) live in this file.
//
//  AC-W4.4 parity: safetyLabel(for:at:).text is byte-identical to the PWA's
//  actionableSafetyLabel() for the same segment and wall-clock time.
//

import SwiftUI

// MARK: - BlockDetailView

struct BlockDetailView: View {

    let segment: Segment
    let engine: ParkingRulesEngine
    let onDismiss: () -> Void

    /// W5: Called when the user taps "Park here →". When nil, the button stays
    /// disabled with the "Coming next" caption (preview / standalone use).
    let onParkHere: (() -> Void)?

    // Evaluate once at sheet-open time (stable reference time for the whole sheet).
    private let now: Date = .nowET

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Severity color band — decorative, not a focusable a11y element.
            severityBand

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header row: close button + block title
                    headerRow

                    // 3. Primary safety label (first focusable element per §3.5 / palette §5.1).
                    safetyLabelView

                    // 4. Rules list
                    if !segment.rules.isEmpty {
                        rulesSection
                    }

                    // 5. Park here stub button
                    parkHereStub
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Severity band

    private var severityBand: some View {
        let color = engine.currentStateColor(for: segment, at: now)
        return Rectangle()
            .fill(color)
            .frame(height: 6)
            .accessibilityHidden(true)
    }

    // MARK: - Header row

    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                // "<StreetName> — <SideLabel>"
                // Marked accessibilityHidden so that VoiceOver's sequential focus
                // order skips the title and subtitle, making the safety label below
                // the first announced element per spec §3.5 / palette §5.1 point 2.
                // Sighted users see the text normally. (QA finding #1.)
                Text(blockHeaderTitle)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)

                // "between <from> and <to>"
                Text(blockHeaderSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer()
            // ✕ close button (44pt tap target per HIG)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close block details")
        }
    }

    // MARK: - Safety label

    private var safetyLabelView: some View {
        let label = engine.safetyLabel(for: segment, at: now)
        return Text(label.text)
            .font(.title.bold())
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            // This is the first focusable accessibility element in the sheet
            // per spec §3.5 and palette doc §5.1. The band above is hidden.
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Rules list

    private var rulesSection: some View {
        let sortedRules = segment.rules.sorted { lhs, rhs in
            lhs.category.priority < rhs.category.priority
        }

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(sortedRules.enumerated()), id: \.offset) { _, rule in
                RuleRow(rule: rule)
            }
        }
    }

    // MARK: - Park here button (W5: live when onParkHere is non-nil)

    private var parkHereStub: some View {
        VStack(spacing: 4) {
            Button {
                onParkHere?()
            } label: {
                Text("Park here \u{2192}")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(onParkHere == nil)
            .accessibilityLabel(
                onParkHere == nil
                    ? "Park here. Coming in next update."
                    : "Park here. Confirm your parking spot."
            )
            .accessibilityHint(onParkHere == nil ? "Disabled." : "")

            if onParkHere == nil {
                Text("Coming next")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Block header helpers (view-file only, not engine domain)

    /// "<StreetName> — <SideLabel>"
    private var blockHeaderTitle: String {
        let street = StreetNameNormalizer.canonical(segment.street)
        let side = sideLabel(segment.side)
        return "\(street) \u{2014} \(side)"
    }

    /// "between <from> and <to>"
    private var blockHeaderSubtitle: String {
        let from = StreetNameNormalizer.canonical(segment.fromStreet)
        let to   = StreetNameNormalizer.canonical(segment.to)
        return "between \(from) and \(to)"
    }

    /// Converts a single-letter side code to a sentence-cased label.
    ///   "N" → "North side", "S" → "South side", "E" → "East side", "W" → "West side"
    /// Any other value falls back to "<X> side".
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

// MARK: - RuleRow

/// Shared rule-row component used by BlockDetailView and ParkedCarDetailView.
/// Internal (not private) so both views in the same module can access it.
///
/// W7 (§3.D): Tap-to-expand. `isExpanded` starts false. Tapping the row toggles
/// `.lineLimit(1)` ↔ `.lineLimit(nil)`. Badge moves below the text when expanded.
/// Animation: `.easeInOut(duration: 0.18)`.
struct RuleRow: View {

    let rule: ParkingRule

    /// W7: Expansion state — starts collapsed.
    @State private var isExpanded: Bool = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            ruleRowContent
        }
        .buttonStyle(.plain)
        // Each rule row is one accessibility announcement.
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpanded ? "Tap to collapse." : "Tap to expand full sign text.")
    }

    @ViewBuilder
    private var ruleRowContent: some View {
        if isExpanded {
            // Expanded: text flows freely; badge below the text for long content.
            VStack(alignment: .leading, spacing: 6) {
                Text(rowText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                HStack {
                    Spacer()
                    badgeView
                }
            }
        } else {
            // Collapsed: single truncated line with badge trailing.
            HStack(alignment: .center, spacing: 8) {
                Text(rowText)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)

                Spacer()

                badgeView
            }
        }
    }

    private var badgeView: some View {
        Text(rule.category.label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(categoryBadgeColor.opacity(0.18))
            )
            .foregroundStyle(categoryBadgeColor)
    }

    // MARK: - Row text

    private var rowText: String {
        // If the rule has a non-empty description, use it.
        let desc = rule.description.trimmingCharacters(in: .whitespaces)
        if !desc.isEmpty {
            return desc
        }

        // Fall back to a generated string: "<days> <timeRange> · <category-label>"
        if rule.anytime {
            return "Anytime \u{00B7} \(rule.category.label)"
        }

        let daysStr = compactDaysString(rule.days)
        let timeStr = compactTimeRange(rule.timeRanges)

        if daysStr.isEmpty && timeStr.isEmpty {
            return rule.category.label
        }
        if timeStr.isEmpty {
            return "\(daysStr) \u{00B7} \(rule.category.label)"
        }
        if daysStr.isEmpty {
            return "\(timeStr) \u{00B7} \(rule.category.label)"
        }
        return "\(daysStr) \(timeStr) \u{00B7} \(rule.category.label)"
    }

    // MARK: - Days helper

    /// Converts [Int] day-of-week array (0=Sun…6=Sat) to a compact range string.
    ///   [1,2,3,4]   → "Mon-Thu"
    ///   [2,5]       → "Tue,Fri"
    ///   [1,2,3,4,5] → "Mon-Fri"
    ///   [0,6]       → "Sun,Sat"
    ///   []          → ""
    private func compactDaysString(_ days: [Int]) -> String {
        guard !days.isEmpty else { return "" }

        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        // Sort and deduplicate, keeping valid day indices.
        let sorted = Array(Set(days.filter { $0 >= 0 && $0 <= 6 })).sorted()
        guard !sorted.isEmpty else { return "" }

        // Build consecutive range groups.
        var groups: [[Int]] = []
        var current: [Int] = [sorted[0]]

        for i in 1..<sorted.count {
            if sorted[i] == sorted[i - 1] + 1 {
                current.append(sorted[i])
            } else {
                groups.append(current)
                current = [sorted[i]]
            }
        }
        groups.append(current)

        // Format each group: single day → "Mon"; two or more consecutive → "Mon-Thu".
        let parts = groups.map { group -> String in
            if group.count == 1 {
                return dayNames[group[0]]
            } else {
                return "\(dayNames[group[0]])-\(dayNames[group[group.count - 1]])"
            }
        }

        return parts.joined(separator: ",")
    }

    // MARK: - Time range helper

    /// Formats an array of TimeRanges as "7am-9:30am" or "7am-9:30am, 11pm-1am".
    /// Uses the same lowercase am/pm, no-space, omit-:00 format as the engine's formatMinutes.
    private func compactTimeRange(_ ranges: [TimeRange]) -> String {
        guard !ranges.isEmpty else { return "" }
        return ranges.map { tr in
            "\(formatMinutes(tr.start))-\(formatMinutes(tr.end))"
        }.joined(separator: ", ")
    }

    /// Formats a minute-of-day value as "7am", "9:30am", "7pm".
    /// Same format as ParkingRulesEngine.formatMinutes (view-file copy per spec §3.3).
    /// Do not remove this in favor of calling the private engine method — it's intentionally
    /// duplicated in the view layer so formatting stays consistent without a public engine API change.
    private func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        let ampm = h >= 12 ? "pm" : "am"
        let h12 = ((h + 11) % 12) + 1
        if m > 0 {
            return "\(h12):\(String(format: "%02d", m))\(ampm)"
        } else {
            return "\(h12)\(ampm)"
        }
    }

    // MARK: - Badge color

    /// Returns a SwiftUI color representing the category's severity for the badge.
    /// Uses the same semantic mapping as the state colors but keyed on static category,
    /// since the badge is a category label (not a live-state indicator).
    private var categoryBadgeColor: Color {
        switch rule.category {
        case .noStanding, .noParking, .special:
            return .red
        case .truckLoading:
            return .orange
        case .metered:
            return Color(red: 0.92, green: 0.76, blue: 0.0)
        case .aspMonThu, .aspTueFri, .aspOvernightMWF, .aspOvernightTTHS, .aspDaily:
            return .orange
        case .free:
            return .green
        case .unknown:
            return .gray
        }
    }
}

// MARK: - Preview

#Preview {
    // Sample segment for preview — uses a NO_STANDING anytime rule.
    let rule = ParkingRule(
        category: .noStanding,
        description: "NO STANDING ANYTIME",
        days: [0, 1, 2, 3, 4, 5, 6],
        timeRanges: [],
        anytime: true,
        arrow: "both"
    )
    let engine = ParkingRulesEngine()

    // Build a minimal segment via JSON round-trip (mirrors the test helper pattern).
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
        "dominantCategory": "NO_STANDING"
    ]
    let segData = try! JSONSerialization.data(withJSONObject: segDict)
    let segment = try! JSONDecoder().decode(Segment.self, from: segData)

    return BlockDetailView(segment: segment, engine: engine, onDismiss: {}, onParkHere: nil)
        .presentationDetents([.medium, .large])
}
