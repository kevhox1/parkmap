//
//  WPPhase3Showcase.swift
//  WePark
//
//  DEBUG-only QA aid (compiled out of Release). With the launch argument `-wp3Showcase <name>`
//  ContentView overlays one Drive mode surface (B5) on an ink ground, built from fixture
//  `DrivingContext`s run through the REAL `WPDriveVerdict` mapping and the REAL drive views:
//
//    both neither nodata unsure dest near arrive muted meter unclear
//
//  The fixtures use the exact label text and goal-aware color the drive service produces, so a
//  screenshot shows what a driver would see for that verdict. Nothing here runs in a Release
//  build or without the launch argument.
//

#if DEBUG
import CoreLocation
import SwiftUI

/// Mounted by `ContentView`. Presents the demo surface in its own window above everything (the
/// live search sheet and Report pill would otherwise sit on top of the demo bottom card).
struct WPPhase3Showcase: View {
    let name: String
    static var requested: String? { WPPhase3ShowcaseContent.requested }
    static var isActive: Bool { requested != nil }

    private static var window: UIWindow?

    var body: some View {
        Color.clear.allowsHitTesting(false).onAppear {
            guard Self.window == nil,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
            else { return }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: WPPhase3ShowcaseContent(name: name))
            window.makeKeyAndVisible()
            Self.window = window
        }
    }
}

struct WPPhase3ShowcaseContent: View {
    let name: String

    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-wp3Showcase"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private func ctx(
        street: String = "E 1ST ST",
        left: (String, SafetyLabel.Severity, SafetyLabel.Severity?),
        right: (String, SafetyLabel.Severity, SafetyLabel.Severity?)
    ) -> DrivingContext {
        DrivingContext(
            street: street, from: "1 AVE", to: "2 AVE",
            leftLabel: SafetyLabel(text: left.0, severity: left.1),
            rightLabel: SafetyLabel(text: right.0, severity: right.1),
            leftChipColorOverride: left.2, rightChipColorOverride: right.2
        )
    }

    private var parkLeft: (String, SafetyLabel.Severity, SafetyLabel.Severity?) { ("Free until Mon 9:00 AM", .free, .free) }
    private var parkRight: (String, SafetyLabel.Severity, SafetyLabel.Severity?) { ("Free until Thu 9:00 AM", .free, .free) }
    private var noParking: (String, SafetyLabel.Severity, SafetyLabel.Severity?) { ("No parking", .restricted, .restricted) }

    private var context: DrivingContext? {
        switch name {
        case "both": return ctx(left: parkLeft, right: parkRight)
        case "neither": return ctx(street: "2ND AVE", left: noParking, right: noParking)
        case "nodata": return ctx(street: "2ND AVE", left: parkLeft, right: (NoSignData.headline, .restricted, .restricted))
        case "unsure": return nil
        case "dest": return ctx(street: "HOUSTON ST", left: noParking, right: parkRight)
        case "near", "arrive": return ctx(street: "LUDLOW ST", left: parkLeft, right: noParking)
        case "meter": return ctx(left: ("Metered", .metered, .free), right: noParking)
        case "unclear": return ctx(left: (UnclearSign.headline, .restricted, .restricted), right: parkRight)
        default: return ctx(street: "2ND AVE", left: parkLeft, right: noParking)
        }
    }

    private var destinationLine: String? {
        switch name {
        case "dest": return WPDriveVerdict.destinationLine(meters: 1930, approaching: false, metric: false)
        case "near": return WPDriveVerdict.destinationLine(meters: 120, approaching: true, metric: false)
        default: return nil
        }
    }

    private var sides: (left: WPDriveSide, right: WPDriveSide) { WPDriveVerdict.sides(for: context) }

    private func lineColor(_ side: WPDriveSide) -> Color {
        switch side.kind {
        case .park: return WP.park
        case .dont: return WP.noParkLine
        case .soon: return WP.detailSoon
        case .meter: return WP.detailMetered
        case .nodata, .checking: return WP.hairline
        }
    }

    private func lineStyle(_ side: WPDriveSide) -> StrokeStyle {
        switch side.kind {
        case .park: return StrokeStyle(lineWidth: 6)
        case .dont, .soon: return StrokeStyle(lineWidth: 6, dash: [10, 8])
        case .meter: return StrokeStyle(lineWidth: 6, lineCap: .round, dash: [0, 11])
        case .nodata: return StrokeStyle(lineWidth: 2)
        case .checking: return StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0, 5])
        }
    }

    var body: some View {
        ZStack {
            ground
            if name == "arrive" {
                VStack(spacing: 0) {
                    topChrome
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .bottom) {
                    WPArrivalPromptV2(
                        context: context,
                        arrivalCoordinate: CLLocationCoordinate2D(latitude: 40.72, longitude: -73.99),
                        onParkHere: { _ in }, onNotYet: {}
                    )
                    // Stand-in for the sheet's detent: half height normally, full height at AX
                    // (`WPArrivalPromptV2.detents`).
                    .frame(height: UIScreen.main.bounds.height
                        * (WPArrivalPromptV2.detents(accessibilitySize: UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory) == [.large] ? 0.9 : 0.56))
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: WP.Radius.sheet, bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0, topTrailingRadius: WP.Radius.sheet, style: .continuous))
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                VStack(spacing: 0) {
                    topChrome
                    Spacer()
                    WPDriveBottomV2(
                        context: context, muted: name == "muted",
                        onReport: {}, onPark: {}, onToggleVoice: {}
                    )
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var topChrome: some View {
        WPDriveTopChromeV2(
            street: context.map { WPDriveVerdict.streetTitle($0.street) } ?? "E 1st St",
            destinationLine: destinationLine, approaching: name == "near",
            endAccessibilityLabel: "End Drive Mode", onEnd: {}
        )
        // Same clearance as the live app (`paddingForBannerState`): below the status bar / island.
        .padding(.top, paddingForBannerState(.aspInEffect))
    }

    /// The tinted-map stand-in: ink ground, road, and the two curb lines drawn in the verdict style.
    private var ground: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Color(wpHex: WP.Hex.darkBackground)
                Rectangle().fill(Color(wpHex: WP.Hex.darkSurface)).frame(width: w * 0.26).position(x: w / 2, y: h / 2)
                Path { p in p.move(to: CGPoint(x: w * 0.37, y: 0)); p.addLine(to: CGPoint(x: w * 0.37, y: h)) }
                    .stroke(lineColor(sides.left), style: lineStyle(sides.left))
                Path { p in p.move(to: CGPoint(x: w * 0.63, y: 0)); p.addLine(to: CGPoint(x: w * 0.63, y: h)) }
                    .stroke(lineColor(sides.right), style: lineStyle(sides.right))
                Image(systemName: "location.north.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(WP.ink)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(WP.taxi))
                    .overlay(Circle().strokeBorder(WP.ink, lineWidth: 2.5))
                    .position(x: w / 2, y: h * 0.42)
            }
        }
        .ignoresSafeArea()
    }
}
#endif
