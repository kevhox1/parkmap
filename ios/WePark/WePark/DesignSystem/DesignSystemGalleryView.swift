//
//  DesignSystemGalleryView.swift
//  WePark
//
//  DEBUG-only gallery of every design system v0.1 component in its states, for QA and the owner
//  to compare against `docs/design/wepark-design-system-v0.1/renders/design-system-spec-sheet.pdf`.
//  Reachable from Settings > Developer in DEBUG builds only; the whole file is compiled out of
//  Release. Appearance (system/light/dark) and text size (default/AX5) are switchable in place.
//

#if DEBUG

import SwiftUI
import MapKit

// MARK: - Sections

enum WPGallerySection: String, CaseIterable, Identifiable {
    case colors = "Colors"
    case type = "Type"
    case buttons = "Buttons"
    case tiles = "Goal tiles"
    case chips = "Chips"
    case switches = "Switch"
    case verdicts = "Verdicts"
    case rows = "Rows"
    case sheet = "Sheet"
    case markers = "Markers"
    case sticker = "Sticker"
    case curbLines = "Curb lines"
    case mapBase = "Map base"

    var id: String { rawValue }
}

private enum GalleryAppearance: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Gallery

struct DesignSystemGalleryView: View {
    @State private var section: WPGallerySection = .buttons
    @State private var appearance: GalleryAppearance = .light
    @State private var largeText = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            ScrollView {
                WPGallerySectionView(section: section)
                    .padding(WP.Space.screenMargin)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(WP.paper.ignoresSafeArea())
        .navigationTitle("Design system v0.1")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(appearance.scheme)
        .dynamicTypeSize(largeText ? .accessibility5 : .large)
    }

    private var controls: some View {
        VStack(spacing: WP.Space.s2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: WP.Space.s2) {
                    ForEach(WPGallerySection.allCases) { item in
                        WPOptionChip(title: item.rawValue, isSelected: item == section) {
                            section = item
                        }
                    }
                }
                .padding(.horizontal, WP.Space.screenMargin)
            }
            HStack(spacing: WP.Space.s2) {
                ForEach(GalleryAppearance.allCases) { item in
                    WPOptionChip(title: item.rawValue, isSelected: item == appearance) {
                        appearance = item
                    }
                }
                WPOptionChip(title: largeText ? "AX5 text" : "Default text", isSelected: largeText) {
                    largeText.toggle()
                }
            }
            .padding(.horizontal, WP.Space.screenMargin)
        }
        .padding(.vertical, WP.Space.s2)
        .background(WP.card)
        .overlay(alignment: .bottom) { Rectangle().fill(WP.divider).frame(height: 1) }
    }
}

/// One gallery section; reused by the `#Preview`s.
struct WPGallerySectionView: View {
    let section: WPGallerySection

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s5) {
            Text(section.rawValue).wpText(.title1).foregroundStyle(WP.text)
            switch section {
            case .colors: WPGalleryColors()
            case .type: WPGalleryType()
            case .buttons: WPGalleryButtons()
            case .tiles: WPGalleryTiles()
            case .chips: WPGalleryChips()
            case .switches: WPGallerySwitches()
            case .verdicts: WPGalleryVerdicts()
            case .rows: WPGalleryRows()
            case .sheet: WPGallerySheet()
            case .markers: WPGalleryMarkers()
            case .sticker: WPGallerySticker()
            case .curbLines: WPGalleryCurbLines()
            case .mapBase: WPGalleryMapBase()
            }
        }
    }
}

private struct GalleryLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).wpText(.label).foregroundStyle(WP.muted)
    }
}

// MARK: - Colors

private struct WPGalleryColors: View {
    private struct Swatch: Identifiable {
        let name: String
        let color: Color
        let hex: String
        var id: String { name }
    }

    private let swatches: [Swatch] = [
        Swatch(name: "paper / dark bg", color: WP.paper, hex: "L #FBF6E6  D #241F45"),
        Swatch(name: "card / dark surface", color: WP.card, hex: "L #FFFFFF  D #2E2856"),
        Swatch(name: "lifted (pressed flat)", color: WP.lifted, hex: "L #FBF6E6  D #3F3870"),
        Swatch(name: "text", color: WP.text, hex: "L #241F45  D #FBF6E6"),
        Swatch(name: "muted", color: WP.muted, hex: "L #5A5578  D #C3BFDC"),
        Swatch(name: "line", color: WP.line, hex: "L #241F45  D #6B64A0"),
        Swatch(name: "shadow", color: WP.shadow, hex: "L #241F45  D #100D24"),
        Swatch(name: "ink", color: WP.ink, hex: "#241F45"),
        Swatch(name: "taxi", color: WP.taxi, hex: "#FFD23F"),
        Swatch(name: "park", color: WP.park, hex: "#3CCF7A"),
        Swatch(name: "parkText", color: WP.parkText, hex: "L #17803F  D #3CCF7A"),
        Swatch(name: "noParkLine", color: WP.noParkLine, hex: "#E39A90"),
        Swatch(name: "noParkText", color: WP.noParkText, hex: "L #B8322A  D #F5A79D"),
        Swatch(name: "hairline", color: WP.hairline, hex: "#A9A7B8"),
        Swatch(name: "divider", color: WP.divider, hex: "L #E4E3EC  D #3F3870*"),
        Swatch(name: "plan", color: WP.plan, hex: "#6A4CFF"),
        Swatch(name: "planStripe", color: WP.planStripe, hex: "#5A3DF0"),
        Swatch(name: "detailSoon", color: WP.detailSoon, hex: "#F2A23A"),
        Swatch(name: "detailMetered", color: WP.detailMetered, hex: "#5B7CFA"),
        Swatch(name: "mapBlock", color: WP.mapBlock, hex: "#F5F1E6"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            ForEach(swatches) { swatch in
                HStack(spacing: WP.Space.s3) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(swatch.color)
                        .frame(width: 48, height: 48)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(WP.line, lineWidth: 1.5))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(swatch.name).font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                            .foregroundStyle(WP.text)
                        Text(swatch.hex).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(WP.muted)
                    }
                }
            }
            Text("* dark divider is not in the spec; lifted is used.")
                .font(WP.Font.caption).foregroundStyle(WP.muted)
        }
    }
}

// MARK: - Type

private struct WPGalleryType: View {
    private let loaded = WPFontWeight.allCases.allSatisfy { UIFont(name: $0.postScriptName, size: 12) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s4) {
            Text(loaded ? "Fredoka loaded: 400, 500, 600, 700" : "Fredoka NOT loaded (fallback in use)")
                .font(WP.Font.callout)
                .foregroundStyle(loaded ? WP.parkText : WP.noParkText)

            GalleryLabel("Weights")
            VStack(alignment: .leading, spacing: WP.Space.s1) {
                ForEach(WPFontWeight.allCases, id: \.self) { weight in
                    Text("Free until Mon 9:00 AM  \(weight.cssWeight)")
                        .font(WP.Font.fredoka(20, weight, relativeTo: .title3))
                        .foregroundStyle(WP.text)
                }
            }

            GalleryLabel("Styles")
            ForEach(WPTextStyle.allCases, id: \.self) { style in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(String(describing: style)) \(Int(style.size))/\(style.weight.cssWeight)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(WP.muted)
                    Text(style == .label ? "Left side" : "Free until Mon 9:00 AM")
                        .wpText(style)
                        .foregroundStyle(WP.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Buttons

private struct WPGalleryButtons: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s4) {
            GalleryLabel("Primary raised (80, raise 6)")
            Button("Park here") {}.buttonStyle(.wpPrimary)
            GalleryLabel("Medium raised (64, raise 4)")
            Button("Walk there \u{00B7} 4 min") {}.buttonStyle(.wpMedium)
            GalleryLabel("Ink pill (taxi label / white label)")
            Button("Start driving") {}.buttonStyle(.wpInkPill)
            Button("I left") { }.buttonStyle(InkPillButtonStyle(labelColor: .white))
            GalleryLabel("Secondary (56)")
            Button("Not now") {}.buttonStyle(.wpSecondary)
            GalleryLabel("Round (72)")
            HStack(spacing: WP.Space.s4) {
                Button("Report") {}.buttonStyle(.wpRound)
                Button("Voice") {}.buttonStyle(.wpRound)
            }
            GalleryLabel("Text link (48)")
            Button("See the 2 signs on this curb") {}.buttonStyle(.wpTextLink)
            GalleryLabel("Disabled")
            Button("Park here") {}.buttonStyle(.wpPrimary).disabled(true)
            Button("Walk there") {}.buttonStyle(.wpMedium).disabled(true)
            Button("Start driving") {}.buttonStyle(.wpInkPill).disabled(true)
            Button("Not now") {}.buttonStyle(.wpSecondary).disabled(true)
        }
    }
}

// MARK: - Goal tiles

private struct WPGalleryTiles: View {
    @State private var selected = 0
    private let goals = [("Overnight", "until 7 AM"), ("A few hours", "until 3 PM"), ("Park & forget", "until Fri")]

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s4) {
            GalleryLabel("Selected = taxi, raise 4, lifted 4. Tap to swap.")
            HStack(spacing: WP.Space.s2) {
                ForEach(goals.indices, id: \.self) { index in
                    WPGoalTile(title: goals[index].0, subtitle: goals[index].1, isSelected: index == selected) {
                        selected = index
                    }
                }
            }
        }
    }
}

// MARK: - Chips

private struct WPGalleryChips: View {
    @State private var option = 1
    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s4) {
            GalleryLabel("Info chip (flat)")
            WPInfoChip(text: "E 1st St", systemImage: "mappin")
            GalleryLabel("Option chips")
            HStack(spacing: WP.Space.s2) {
                ForEach(0..<3, id: \.self) { index in
                    WPOptionChip(title: ["6 AM", "7 AM", "8 AM"][index], isSelected: index == option) {
                        option = index
                    }
                }
            }
            GalleryLabel("Karma chip (raised 3, earned)")
            WPKarmaChip(text: "12 karma") {}
        }
    }
}

// MARK: - Switch

private struct WPGallerySwitches: View {
    @State private var on = true
    @State private var off = false
    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            GalleryLabel("56 x 34, knob 22 slides 23")
            Toggle("Remind me at 8 AM", isOn: $on).toggleStyle(.wp)
                .font(WP.Font.body).foregroundStyle(WP.text)
            Toggle("Move-car reminders", isOn: $off).toggleStyle(.wp)
                .font(WP.Font.body).foregroundStyle(WP.text)
        }
    }
}

// MARK: - Verdicts

private struct WPGalleryVerdicts: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s4) {
            GalleryLabel("Park")
            WPParkVerdict(time: "Mon 9:00 AM", fractionLeft: 0.62, support: "8 h 49 min from now")
            GalleryLabel("Park, almost out")
            WPParkVerdict(time: "7:00 AM tomorrow", fractionLeft: 0.12, support: "Move before street cleaning")
            GalleryLabel("Don't")
            WPDontVerdict(reason: "Street cleaning at 7 AM.", freesUp: "Free again Mon 9:00 AM")
            GalleryLabel("No data")
            WPNoDataVerdict()
            GalleryLabel("Trip plan (not live)")
            WPTripPlanVerdict(
                headline: "Free from now until Mon 9:00 AM",
                detail: "Based on the visit dates only.",
                dates: "Fri Dec 5 to Sun Dec 7"
            )
        }
    }
}

// MARK: - Rows

private struct WPGalleryRows: View {
    @State private var reminder = true
    var body: some View {
        WPRowGroup {
            WPRow(title: "In front of 50 E 1st St", subtitle: "Left side")
            WPRowDivider()
            WPRow(title: "Remind me at 8 AM", subtitle: "Before street cleaning") {
                Toggle("", isOn: $reminder).toggleStyle(.wp).labelsHidden()
            }
            WPRowDivider()
            WPRow(title: "See the 2 signs on this curb") {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WP.muted)
            }
        }
    }
}

// MARK: - Sheet

private struct WPGallerySheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            GalleryLabel("Top radius 30, 1.5 top line, no shadow")
            ZStack(alignment: .bottom) {
                WP.mapBlock
                VStack(spacing: WP.Space.s3) {
                    Capsule().fill(WP.hairline).frame(width: 40, height: 5).padding(.top, WP.Space.s2)
                    Text("Green curbs are free from now until").wpText(.callout).foregroundStyle(WP.muted)
                    Text("Mon 9:00 AM").wpText(.title1).foregroundStyle(WP.text)
                }
                .padding(WP.Space.screenMargin)
                .frame(maxWidth: .infinity)
                .wpSheetSurface()
                .padding(.top, 120)
            }
            .clipShape(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous))
        }
    }
}

// MARK: - Markers

private struct WPGalleryMarkers: View {
    @State private var lifted = false
    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s4) {
            GalleryLabel("On the map block color")
            VStack(alignment: .leading, spacing: WP.Space.s5) {
                markerRow("You (22 ink, 4 white ring)") { WPYouDot() }
                markerRow("Car token (56, raise 4). Tap to lift.") {
                    WPCarToken(isLifted: lifted).onTapGesture { lifted.toggle() }
                }
                markerRow("Parked car (40, flat)") { WPParkedCarMarker() }
                markerRow("Neighbor report (44, r14)") { WPNeighborReportMarker() }
                markerRow("Leaving soon (taxi, raise 3)") { WPLeavingSoonMarker() }
            }
            .padding(WP.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WP.mapBlock)
            .clipShape(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous))
        }
    }

    private func markerRow<M: View>(_ label: String, @ViewBuilder marker: () -> M) -> some View {
        HStack(spacing: WP.Space.s4) {
            marker().frame(width: 72, height: 72)
            Text(label).wpText(.callout).foregroundStyle(Color(wpHex: WP.Hex.ink))
        }
    }
}

// MARK: - Sticker

private struct WPGallerySticker: View {
    @State private var replay = 0
    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s5) {
            HStack(spacing: WP.Space.s6) {
                WPSticker(text: "+5 karma", kind: .karma).id(replay)
                WPSticker(text: "Spot passed", kind: .stamp).id(replay)
            }
            .padding(.vertical, WP.Space.s4)
            Button("Replay pop-in") { replay += 1 }.buttonStyle(.wpSecondary)
        }
    }
}

// MARK: - Curb lines

private struct WPGalleryCurbLines: View {
    private struct Row: Identifiable {
        let name: String
        let kind: CurbLineKind
        var id: String { name }
    }

    private let defaults: [Row] = [Row(name: "Park (solid green)", kind: .park), Row(name: "Don't (dashed coral)", kind: .dont)]
    private let detail: [Row] = [
        Row(name: "Free (solid green)", kind: .park),
        Row(name: "Free now, changes soon (long dash)", kind: .soon),
        Row(name: "Metered (dotted blue)", kind: .metered),
        Row(name: "No parking / standing (dashed coral)", kind: .dont),
        Row(name: "No sign data (2pt grey)", kind: .noData),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s4) {
            GalleryLabel("Default, two states (unknown draws as don't)")
            group(defaults)
            GalleryLabel("Show all sign details, five states")
            group(detail)
        }
    }

    private func group(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: WP.Space.s3) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: WP.Space.s1) {
                    CurbSample(kind: row.kind).frame(height: 14)
                    Text(row.name).wpText(.callout).foregroundStyle(Color(wpHex: WP.Hex.ink))
                }
            }
        }
        .padding(WP.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WP.mapBlock)
        .clipShape(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous))
    }
}

/// Draws a curb-line style with the exact stroke the MapKit renderers use.
private struct CurbSample: View {
    let kind: CurbLineKind

    var body: some View {
        let style = CurbLineStyleV2.style(for: kind)
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 4, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width - 4, y: size.height / 2))
            context.stroke(
                path,
                with: .color(Color(wpHex: style.colorHex)),
                style: StrokeStyle(
                    lineWidth: style.width,
                    lineCap: style.roundCaps ? .round : .butt,
                    dash: style.dashPattern ?? []
                )
            )
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Map base

private struct WPGalleryMapBase: View {
    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.s3) {
            GalleryLabel("MapKit muted emphasis, POIs excluded")
            Map(initialPosition: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 40.7265, longitude: -73.9815),
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            ))) {}
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
                .strokeBorder(WP.line, lineWidth: WP.Border.fact))
            Text("Spec map block target #F5F1E6; MapKit can mute but not recolor, so the real base only approximates it.")
                .wpText(.caption).foregroundStyle(WP.muted)
        }
    }
}

// MARK: - Previews (light, dark, AX5 for every section)

private struct GalleryPreviewHost: View {
    let section: WPGallerySection
    var body: some View {
        ScrollView {
            WPGallerySectionView(section: section)
                .padding(WP.Space.screenMargin)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WP.paper.ignoresSafeArea())
    }
}

#Preview("Colors light") { GalleryPreviewHost(section: .colors).preferredColorScheme(.light) }
#Preview("Colors dark") { GalleryPreviewHost(section: .colors).preferredColorScheme(.dark) }
#Preview("Colors AX5") { GalleryPreviewHost(section: .colors).dynamicTypeSize(.accessibility5) }
#Preview("Type light") { GalleryPreviewHost(section: .type).preferredColorScheme(.light) }
#Preview("Type dark") { GalleryPreviewHost(section: .type).preferredColorScheme(.dark) }
#Preview("Type AX5") { GalleryPreviewHost(section: .type).dynamicTypeSize(.accessibility5) }
#Preview("Buttons light") { GalleryPreviewHost(section: .buttons).preferredColorScheme(.light) }
#Preview("Buttons dark") { GalleryPreviewHost(section: .buttons).preferredColorScheme(.dark) }
#Preview("Buttons AX5") { GalleryPreviewHost(section: .buttons).dynamicTypeSize(.accessibility5) }
#Preview("Goal tiles light") { GalleryPreviewHost(section: .tiles).preferredColorScheme(.light) }
#Preview("Goal tiles dark") { GalleryPreviewHost(section: .tiles).preferredColorScheme(.dark) }
#Preview("Goal tiles AX5") { GalleryPreviewHost(section: .tiles).dynamicTypeSize(.accessibility5) }
#Preview("Chips light") { GalleryPreviewHost(section: .chips).preferredColorScheme(.light) }
#Preview("Chips dark") { GalleryPreviewHost(section: .chips).preferredColorScheme(.dark) }
#Preview("Chips AX5") { GalleryPreviewHost(section: .chips).dynamicTypeSize(.accessibility5) }
#Preview("Switch light") { GalleryPreviewHost(section: .switches).preferredColorScheme(.light) }
#Preview("Switch dark") { GalleryPreviewHost(section: .switches).preferredColorScheme(.dark) }
#Preview("Switch AX5") { GalleryPreviewHost(section: .switches).dynamicTypeSize(.accessibility5) }
#Preview("Verdicts light") { GalleryPreviewHost(section: .verdicts).preferredColorScheme(.light) }
#Preview("Verdicts dark") { GalleryPreviewHost(section: .verdicts).preferredColorScheme(.dark) }
#Preview("Verdicts AX5") { GalleryPreviewHost(section: .verdicts).dynamicTypeSize(.accessibility5) }
#Preview("Rows light") { GalleryPreviewHost(section: .rows).preferredColorScheme(.light) }
#Preview("Rows dark") { GalleryPreviewHost(section: .rows).preferredColorScheme(.dark) }
#Preview("Rows AX5") { GalleryPreviewHost(section: .rows).dynamicTypeSize(.accessibility5) }
#Preview("Sheet light") { GalleryPreviewHost(section: .sheet).preferredColorScheme(.light) }
#Preview("Sheet dark") { GalleryPreviewHost(section: .sheet).preferredColorScheme(.dark) }
#Preview("Sheet AX5") { GalleryPreviewHost(section: .sheet).dynamicTypeSize(.accessibility5) }
#Preview("Markers light") { GalleryPreviewHost(section: .markers).preferredColorScheme(.light) }
#Preview("Markers dark") { GalleryPreviewHost(section: .markers).preferredColorScheme(.dark) }
#Preview("Markers AX5") { GalleryPreviewHost(section: .markers).dynamicTypeSize(.accessibility5) }
#Preview("Sticker light") { GalleryPreviewHost(section: .sticker).preferredColorScheme(.light) }
#Preview("Sticker dark") { GalleryPreviewHost(section: .sticker).preferredColorScheme(.dark) }
#Preview("Sticker AX5") { GalleryPreviewHost(section: .sticker).dynamicTypeSize(.accessibility5) }
#Preview("Curb lines light") { GalleryPreviewHost(section: .curbLines).preferredColorScheme(.light) }
#Preview("Curb lines dark") { GalleryPreviewHost(section: .curbLines).preferredColorScheme(.dark) }
#Preview("Curb lines AX5") { GalleryPreviewHost(section: .curbLines).dynamicTypeSize(.accessibility5) }

#endif
