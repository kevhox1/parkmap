//
//  MapKeyLegendView.swift
//  WePark
//
//  Community 2.0 S13a (WP1, build 20): the "?" map-key button's legend content
//  (`design/screenshots/02-map-key.png`, `design/prototype.html:55-74` — the `showLegend`
//  popover, `legend`/`pinLegend` arrays at lines 1020-1035).
//  Spec: docs/design/community-2.0-hero-gap-inventory.md WP1 + locked decision #6.
//
//  Presentation: `ActiveSheet.mapKeyLegend` at the `.medium` detent — this codebase's
//  established single-sheet-rule idiom (see `ActiveSheet.identityPrompt`'s own doc comment
//  for why a second, independent `.sheet` modifier is never added on top of the one this
//  file already funnels through). Chosen over a floating popover (the prototype's own
//  mechanism, an absolutely-positioned `<div>`) because SwiftUI has no first-class
//  "popover anchored to a specific button, sized to content, dismissible by tap-outside"
//  primitive that doesn't itself become a second, competing presentation layer — `.popover`
//  on a compact-width iPhone auto-converts to a full sheet anyway, so presenting this AS a
//  sheet directly, through the existing single-sheet funnel, is the more honest native
//  mapping rather than fighting SwiftUI for a desktop-style anchored popover this device
//  class doesn't really have.
//
//  CURB COLORS copy (`curbColorEntries` below) is VERBATIM from the prototype's `legend`
//  array (`design/prototype.html:1020-1026`) — do not paraphrase. This is intentionally a
//  DIFFERENT (and more casual/tutorial) legend from
//  `Views/ParkingGuide/ColorLegendSectionView.swift`'s own five-row curb-color legend, which
//  is out of scope for this PR and is left untouched.
//
//  LIVE PINS rows (`livePinEntries` below) deliberately do NOT match the prototype's own
//  `pinLegend` array (`design/prototype.html:1028-1035`: orange rings + 🎫/🧹 emoji glyphs)
//  — per locked decision #6's standing exception
//  (`docs/design/community-2.0-hero-gap-inventory.md` Judgment Call #1), this legend must
//  describe what the map ACTUALLY renders: `person.badge.clock.fill`/systemTeal for
//  enforcement, `truck.box.fill`/systemCyan for sweeper
//  (`docs/design/tier3-marker-icons.md`, `PinMarkerAnnotation.markerStyle(for:)`), and the
//  blue-ring "P"/🚙 glyph treatment for open_spot/leaving_soon
//  (`PinMarkerAnnotation.ringMarkerImage(for:)`). The prototype's other two `pinLegend` rows
//  (🚧 closure/construction, 📌 block note) are DROPPED — neither `.construction` nor
//  `.blockNote` is currently rendered as a map marker at all
//  (`ContentView.mapMarkerTypes(communityEnabled:)` omits both; FT-15/TF2-15 closures
//  surface via `BlockDetailView`'s banner instead, gap-inventory row 07) — this legend never
//  promises a marker the map doesn't draw.
//
//  Footer copy is adapted from `design/prototype.html:72` for the same "match reality" rule:
//  this app has no pulse/fade expiry ANIMATION (an ephemeral pin is simply removed from
//  `visiblePins` once its TTL passes — no visual fade-out), so the footer does not claim
//  one. The car pin is `mappin.circle.fill` in white+blue (W5 §5.1), not the prototype's
//  literal solid black pin. "dashed square = your zone" describes the NEW overlay this same
//  PR adds (`MapViewRepresentable`'s `ZoneBoundaryPolygon`, WP2).
//

import SwiftUI

// MARK: - MapKeyCurbColorEntry

/// One CURB COLORS row. Copy VERBATIM from `design/prototype.html`'s `legend` array — see
/// this file's header for why. `Identifiable` via `name` (all five names are distinct and
/// static — no need for a synthesized UUID).
struct MapKeyCurbColorEntry: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let color: Color
}

// MARK: - MapKeyPinEntry

/// One LIVE PINS row — the SHIPPED marker treatment (see file header for the deliberate
/// departure from the prototype's own `pinLegend` array).
struct MapKeyPinEntry: Equatable, Identifiable {
    var id: String { label }
    let label: String
    /// SF Symbol name for the filled-circle marker family (enforcement / sweeper). `nil`
    /// for the ring-glyph family (open spot / leaving soon), which uses `glyph` instead.
    let symbolName: String?
    /// Text/emoji glyph for the ring-marker family (`PinMarkerAnnotation.ringMarkerImage`).
    /// `nil` for the SF-Symbol family.
    let glyph: String?
    let color: Color
}

// MARK: - MapKeyLegendView

struct MapKeyLegendView: View {

    /// CURB COLORS legend rows — copy VERBATIM from `design/prototype.html`'s `legend`
    /// array (lines 1020-1026). `color` values reuse `ParkingColors`'s existing constants
    /// (the sacred severity palette) — no new hex/RGB literals introduced here.
    static let curbColorEntries: [MapKeyCurbColorEntry] = [
        MapKeyCurbColorEntry(
            name: "Red",
            description: "a restriction is active right now",
            color: ParkingColors.restricted
        ),
        MapKeyCurbColorEntry(
            name: "Orange",
            description: "free now, but a restriction starts within 6 hours",
            color: ParkingColors.restrictionComingSoon
        ),
        MapKeyCurbColorEntry(
            name: "Amber",
            description: "metered — pay or move",
            color: ParkingColors.meteredActive
        ),
        MapKeyCurbColorEntry(
            name: "Green",
            description: "free right now, nothing posted near-term",
            color: ParkingColors.freeComfortably
        ),
        MapKeyCurbColorEntry(
            name: "Gray",
            description: "no data — the sign on the pole is the only truth",
            color: ParkingColors.unknown
        ),
    ]

    /// LIVE PINS legend rows — the shipped marker treatment (see file header). Colors match
    /// `PinMarkerAnnotation.markerStyle(for:)` / `ringMarkerImage(for:)` exactly
    /// (`Color.teal`/`.cyan`/`.blue` bridge to `UIColor.systemTeal`/`.systemCyan`/`.systemBlue`,
    /// the same constants those UIKit call sites use).
    static let livePinEntries: [MapKeyPinEntry] = [
        MapKeyPinEntry(
            label: "Enforcement active",
            symbolName: "person.badge.clock.fill",
            glyph: nil,
            color: .teal
        ),
        MapKeyPinEntry(
            label: "Sweeper passed",
            symbolName: "truck.box.fill",
            glyph: nil,
            color: .cyan
        ),
        MapKeyPinEntry(
            label: "Leaving soon (handoff)",
            symbolName: nil,
            glyph: "🚙",
            color: .blue
        ),
        MapKeyPinEntry(
            label: "Open spot (passerby)",
            symbolName: nil,
            glyph: "P",
            color: .blue
        ),
    ]

    /// Footer caption — adapted from `design/prototype.html:72`. See file header for why
    /// this deliberately does not match the prototype's literal wording.
    static let footerText =
        "Pins disappear once they expire. Blue circular pin = your car · blue dot = you · dashed square = your zone."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sectionHeader("CURB COLORS")
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.curbColorEntries) { entry in
                        curbColorRow(entry)
                    }
                }

                sectionHeader("LIVE PINS")
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.livePinEntries) { entry in
                        pinRow(entry)
                    }
                }

                Text(Self.footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(20)
        }
        .accessibilityIdentifier("mapKeyLegendView")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .tracking(1.2)
    }

    private func curbColorRow(_ entry: MapKeyCurbColorEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(entry.color)
                .frame(width: 20, height: 6)
                .padding(.top, 6)
            (Text(entry.name).fontWeight(.bold) + Text(" — \(entry.description)"))
                .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name) — \(entry.description)")
    }

    private func pinRow(_ entry: MapKeyPinEntry) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(.systemGray6))
                    .frame(width: 22, height: 22)
                Circle()
                    .strokeBorder(entry.color, lineWidth: 2)
                    .frame(width: 22, height: 22)
                if let symbolName = entry.symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(entry.color)
                } else if let glyph = entry.glyph {
                    Text(glyph)
                        .font(.system(size: glyph == "🚙" ? 11 : 10, weight: .heavy))
                        .foregroundStyle(entry.color)
                }
            }
            Text(entry.label)
                .font(.subheadline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.label)
    }
}

// MARK: - Preview

#Preview {
    MapKeyLegendView()
}
