//
//  PinDetailSheet.swift
//  WePark
//
//  Tier 1 Pin Display — read-only detail sheet for community pins.
//  Tier 3 Sub-PR #1 additions: reactions row for ephemeral crowd pins.
//  Spec: docs/tier1-pin-display-spec.md §8, docs/tier3-auth-and-reactions-spec.md §3.10.
//
//  Surfaces:
//   - filming:      type icon + label, open-data badge, production name,
//                   expiry, NYC Film Office link (if filmOfficeUrl non-nil).
//   - special_event: type icon + label, open-data badge, event name, event type, expiry.
//   - enforcement_active / sweeper_passed (Tier 3 ephemeral crowd pins):
//       reactions row with "Still there?" (confirm + extend) and "Gone" (dispute) buttons.
//
//  Reactions row (sub-PR #1):
//   - Shown only when pin.lifespan == .ephemeral && pin.source == .crowd.
//   - A1 own-pin guard: buttons disabled when pin.authorId == authService.currentUserId.
//   - "Still there?" disabled when pin is within 5min of the 2h TTL cap.
//   - Confirm count badge reads from pin.confirmCount (updated in real time via Realtime).
//   - Loading state: ProgressView while async calls are in-flight.
//
//  Invariants:
//   - No Calendar.current (AC-D19, AC-I5). All time arithmetic uses Date() + TimeInterval.
//   - No force-unwraps.
//   - CommunityPin.swift is NOT modified BY THIS FILE (AC-D20, AC-I2) — display logic
//     lives here, model shape lives in Models/CommunityPin.swift. That was a
//     diff-minimization discipline scoped to the Tier 3 sub-PR #1 PR this comment
//     originates from, not a standing freeze on the model file itself — FT-15/TF2-15
//     (docs/ft15-tf215-temporary-block-restrictions-spec.md §10, Stream B1) deliberately
//     extends CommunityPin.swift (adds startsAt/reportGroupId/hasEvidencePhoto). This
//     view file's own reactions-row gate below (line ~55) still only covers
//     `lifespan == .ephemeral` — widening it to include block-scoped `session`/`durable`
//     reports is Stream B4's job (AC-C4), not done in this pass.
//   - No setRegion, updateUIView mutation, or headlessWindow guard (AC-I3).
//

import SwiftUI

// MARK: - PinDetailSheet

struct PinDetailSheet: View {

    let pin: CommunityPin
    let onDismiss: () -> Void

    /// Auth service for the A1 own-pin guard and write-path identity.
    /// Passed from ContentView (same shared instance as WeParkApp root).
    var authService: SupabaseAuthService

    /// Pin service for reaction write calls (upsertVote, callExtendPinExpiry).
    var pinService: CommunityPinService

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    Divider()
                    detailSection
                    // Tier 3 sub-PR #1: reactions row for ephemeral crowd pins.
                    // Condition: only shown when the pin is a Tier 3 ephemeral crowd pin.
                    if pin.lifespan == .ephemeral && pin.source == .crowd {
                        Divider()
                        ReactionsRow(
                            pin: pin,
                            authService: authService,
                            pinService: pinService
                        )
                    }
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
        case .filming:           return "video.fill"
        case .specialEvent:      return "star.fill"
        case .enforcementActive: return "exclamationmark.triangle.fill"
        case .sweeperPassed:     return "truck.box.fill"
        case .brokenMeter:       return "parkingsign.circle.fill"
        default:                 return "mappin.fill"
        }
    }

    private var iconColor: Color {
        switch pin.pinType {
        case .filming:           return .purple
        case .specialEvent:      return .orange
        case .enforcementActive: return .red
        case .sweeperPassed:     return Color(red: 0.0, green: 0.55, blue: 0.27)
        case .brokenMeter:       return .gray
        default:                 return .gray
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

// MARK: - ReactionsRow

/// Reactions row for Tier 3 ephemeral crowd pins.
///
/// Shows "Still there?" (confirm + extend TTL) and "Gone" (dispute) buttons.
/// Displays the live confirm count from `pin.confirmCount`.
///
/// Design (community-1.0-direction.md §6.1):
///   - One-tap, binary, no confirmation sheet.
///   - Tap targets are 44pt minimum (HIG).
///   - A1 guard: buttons disabled when pin.authorId == authService.currentUserId.
private struct ReactionsRow: View {

    let pin: CommunityPin
    var authService: SupabaseAuthService
    var pinService: CommunityPinService

    /// True while a reaction call is in-flight. Replaces the confirm count with a spinner.
    @State private var isLoading: Bool = false

    /// Last error from a reaction call. Cleared on next successful call.
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Community Check")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            // Confirm count badge or loading spinner
            HStack {
                if isLoading {
                    ProgressView()
                        .frame(width: 20, height: 20)
                } else {
                    Label(
                        pin.confirmCount == 1
                            ? "1 confirm"
                            : "\(pin.confirmCount) confirms",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Reaction buttons
            HStack(spacing: 12) {
                // "Still there?" button — confirm + extend TTL.
                Button {
                    Task { await handleStillHere() }
                } label: {
                    Label("Still there?", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(isStillHereDisabled)
                .accessibilityLabel("Still there? Confirm this pin and extend its time")

                // "Gone" button — dispute.
                Button {
                    Task { await handleGone() }
                } label: {
                    Label("Gone", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isGoneDisabled)
                .accessibilityLabel("Gone — dispute this pin")
            }

            // Error display (non-blocking — user can retry).
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Button enable logic

    /// True when the user's own pin (A1 own-pin guard, iOS-side, decision A1 per spec OQ-1).
    private var isOwnPin: Bool {
        guard let authorId = pin.authorId,
              let currentId = authService.currentUserId else { return false }
        return authorId == currentId
    }

    /// "Still there?" is disabled when:
    ///   1. It is the user's own pin (A1 guard).
    ///   2. The pin is within 5 minutes of the 2h TTL cap (expires_at > now + 115 min).
    ///      No point extending — the cap is close. Uses Date() + TimeInterval (no Calendar.current).
    ///   3. A reaction call is in-flight.
    private var isStillHereDisabled: Bool {
        if isOwnPin || isLoading { return true }
        if let expiresAt = pin.expiresAt {
            // 115 minutes = 2h cap - 5min buffer.
            return expiresAt > Date().addingTimeInterval(115 * 60)
        }
        return false
    }

    /// "Gone" is disabled when it is the user's own pin (A1 guard) or a call is in-flight.
    private var isGoneDisabled: Bool {
        isOwnPin || isLoading
    }

    // MARK: - Action handlers

    /// "Still there?" tap: confirm vote + extend TTL.
    ///
    /// AC-V2: both `upsertVote(.confirm)` AND `callExtendPinExpiry` are called.
    private func handleStillHere() async {
        isLoading = true
        errorMessage = nil
        do {
            try await pinService.upsertVote(pinId: pin.id, vote: .confirm)
            try await pinService.callExtendPinExpiry(pinId: pin.id)
        } catch {
            errorMessage = "Couldn't confirm — please try again."
        }
        isLoading = false
    }

    /// "Gone" tap: dispute vote only (AC-V3: does NOT call callExtendPinExpiry).
    private func handleGone() async {
        isLoading = true
        errorMessage = nil
        do {
            try await pinService.upsertVote(pinId: pin.id, vote: .dispute)
        } catch {
            errorMessage = "Couldn't report — please try again."
        }
        isLoading = false
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
    return PinDetailSheet(
        pin: pin,
        onDismiss: {},
        authService: SupabaseAuthService(),
        pinService: CommunityPinService()
    )
    .presentationDetents([.medium, .large])
}
