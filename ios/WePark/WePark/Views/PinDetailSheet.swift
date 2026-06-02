//
//  PinDetailSheet.swift
//  WePark
//
//  Tier 1 Pin Display — read-only detail sheet for community pins.
//  Spec: docs/tier1-pin-display-spec.md §8.
//
//  Surfaces:
//   - filming:      type icon + label, open-data badge, production name,
//                   expiry, NYC Film Office link (if filmOfficeUrl non-nil).
//   - special_event: type icon + label, open-data badge, event name, event type, expiry.
//
//  Read-only TF1 note:
//   - No "Report an issue" button (TF2).
//   - confirm_count fetched but NOT displayed. TODO hook left in comments.
//   - No auth required to view this sheet.
//
//  Invariants:
//   - No Calendar.current (AC-D19). All time formatting via Calendar.easternTime or
//     CommunityPin.formatExpiry helper.
//   - No force-unwraps.
//   - CommunityPin.swift is NOT modified (AC-D20). Display logic lives here or in
//     PinMarkerAnnotation.swift extension.
//

import SwiftUI

// MARK: - PinDetailSheet

struct PinDetailSheet: View {

    let pin: CommunityPin
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    Divider()
                    detailSection
                    // TODO: TF2 — display confirm_count badge
                    // The confirm_count field is already decoded in CommunityPin.confirmCount.
                    // Add a "N people confirmed this" badge here in TF2.
                }
                .padding()
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    // MARK: - Navigation title

    private var navigationTitle: String {
        switch pin.pinType {
        case .filming:       return "Filming"
        case .specialEvent:  return "Special Event"
        default:             return pin.pinType.displayLabel
        }
    }

    // MARK: - Header section (icon + label + badge)

    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 12) {
            // Type icon in colored circle (matches PinMarkerAnnotation style).
            ZStack {
                Circle()
                    .fill(iconColor)
                    .frame(width: 48, height: 48)
                Image(systemName: iconSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(pin.displayTitle ?? pin.pinType.displayLabel)
                    .font(.headline)
                    .foregroundStyle(.primary)

                // Open-data source badge.
                Text(sourceBadgeLabel)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(iconColor, in: Capsule())
            }
        }
    }

    // MARK: - Detail section (per-type fields)

    @ViewBuilder
    private var detailSection: some View {
        switch pin.pinType {
        case .filming:
            filmingDetails
        case .specialEvent:
            specialEventDetails
        default:
            genericDetails
        }
    }

    // MARK: filming details

    @ViewBuilder
    private var filmingDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let meta = pin.meta, case .filming(let m) = meta {
                if let name = m.productionName {
                    detailRow(label: "Production", value: name)
                }
                // Block / address: show segment street name if segmentId is set,
                // else lat/lng fallback. Full reverse-geocode is a TF2 enhancement.
                if let segmentId = pin.segmentId {
                    let streetName = segmentId.components(separatedBy: "|").first ?? segmentId
                    detailRow(label: "Block", value: streetName)
                }

                if let urlString = m.filmOfficeUrl, let url = URL(string: urlString) {
                    Link(destination: url) {
                        Label("NYC Film Office Permit", systemImage: "link")
                            .font(.subheadline)
                    }
                }
            }

            if let expiresAt = pin.expiresAt {
                detailRow(label: "Until", value: expiresAtFormatted(expiresAt))
            }
        }
    }

    // MARK: special_event details

    @ViewBuilder
    private var specialEventDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let meta = pin.meta, case .specialEvent(let m) = meta {
                detailRow(label: "Event", value: m.eventName)
                detailRow(label: "Type", value: m.eventType.humanReadable)
            }
            if let expiresAt = pin.expiresAt {
                detailRow(label: "Until", value: expiresAtFormatted(expiresAt))
            }
        }
    }

    // MARK: generic details (fallback)

    @ViewBuilder
    private var genericDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let expiresAt = pin.expiresAt {
                detailRow(label: "Until", value: expiresAtFormatted(expiresAt))
            }
            if let notes = pin.notes {
                detailRow(label: "Notes", value: notes)
            }
        }
    }

    // MARK: - Detail row helper

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Time formatting

    /// Formats an expiry Date for the detail sheet.
    /// Uses Calendar.easternTime (AC-D19 — no Calendar.current).
    private func expiresAtFormatted(_ date: Date) -> String {
        CommunityPin.formatExpiry(date)
    }

    // MARK: - Style helpers

    private var iconSymbol: String {
        switch pin.pinType {
        case .filming:      return "video.fill"
        case .specialEvent: return "star.fill"
        default:            return "mappin.fill"
        }
    }

    private var iconColor: Color {
        switch pin.pinType {
        case .filming:      return .purple
        case .specialEvent: return .orange
        default:            return .gray
        }
    }

    private var sourceBadgeLabel: String {
        switch pin.pinType {
        case .filming:      return "Open Data — NYC Film Permits"
        case .specialEvent: return "Open Data"
        default:            return pin.source == .openData ? "Open Data" : "Community"
        }
    }
}

// MARK: - SpecialEventMeta.EventType human-readable label

private extension SpecialEventMeta.EventType {
    var humanReadable: String {
        switch self {
        case .parade:        return "Parade"
        case .marathon:      return "Marathon"
        case .snowEmergency: return "Snow Emergency"
        case .fair:          return "Fair"
        case .other:         return "Special Event"
        }
    }
}

// MARK: - Preview

#Preview {
    // Filming pin fixture for preview only.
    let fixtureJSON = """
    {
      "id": "B0000000-0000-0000-0000-000000000001",
      "pin_type": "filming",
      "source": "open_data",
      "lifespan": "session",
      "lat": 40.7505,
      "lng": -73.9965,
      "segment_id": "7th Ave|W 32nd St|W 33rd St",
      "zone_id": null,
      "author_id": null,
      "author_username": null,
      "created_at": "2026-06-01T10:00:00+00:00",
      "updated_at": "2026-06-01T10:00:00+00:00",
      "expires_at": "2026-06-02T20:00:00+00:00",
      "resolved_at": null,
      "confirm_count": 3,
      "dispute_count": 0,
      "meta": { "permit_id": "NYC-2026-001", "production_name": "The Lincoln Tunnel", "film_office_url": "https://www.nyc.gov/filmnyc" },
      "notes": null
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string) ?? Date()
    }

    let pin = try! decoder.decode(CommunityPin.self, from: fixtureJSON)
    return PinDetailSheet(pin: pin, onDismiss: {})
        .presentationDetents([.medium, .large])
}
