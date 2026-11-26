//
//  WPPhase4Showcase.swift
//  WePark
//
//  DEBUG-only QA aid (compiled out of Release). With the launch argument `-wp4Showcase <name>`
//  ContentView mounts the REAL `WPMyCarV2View` (real engine, real verdict logic) over fixture
//  curbs in its own window above everything, at a fixed clock so the screenshots are repeatable:
//
//    legal soon dont meter nodata unclear suspended remind leaving signs
//
//  Nothing here runs in a Release build or without the launch argument.
//

#if DEBUG
import CoreLocation
import SwiftUI

/// Mounted by `ContentView`; presents the demo in its own window (the live map sheets would
/// otherwise sit on top of it).
struct WPPhase4Showcase: View {
    let name: String

    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-wp4Showcase"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var window: UIWindow?

    var body: some View {
        Color.clear.allowsHitTesting(false).onAppear {
            guard Self.window == nil,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
            else { return }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            // The flag-off app is forced dark at its own windows, so this window picks its style.
            window.overrideUserInterfaceStyle = ProcessInfo.processInfo.arguments.contains("-wpLight") ? .light : .dark
            window.rootViewController = UIHostingController(rootView: WPPhase4ShowcaseContent(name: name))
            window.makeKeyAndVisible()
            Self.window = window
        }
    }
}

private struct WPPhase4ShowcaseContent: View {
    let name: String

    @State private var parkPinService = ParkPinService()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        c.timeZone = .easternTime
        return Calendar.easternTime.date(from: c) ?? Date()
    }

    private func rule(
        _ category: WePark.Category, days: [Int], ranges: [(Int, Int)], anytime: Bool = false,
        description: String = "", arrow: String = "both"
    ) -> [String: Any] {
        [
            "category": category.rawValue, "description": description, "days": days,
            "timeRanges": ranges.map { ["start": $0.0, "end": $0.1] },
            "anytime": anytime, "arrow": arrow,
        ]
    }

    private func segment(_ rules: [[String: Any]]) -> Segment? {
        let dict: [String: Any] = [
            "id": "P4", "street": "EAST 1ST STREET", "from": "1 AVENUE", "to": "2 AVENUE",
            "side": "N", "line": [[40.7236, -73.9889], [40.7240, -73.9880]], "rules": rules,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Segment.self, from: data)
    }

    /// (curb rules, fixed now, opens a sub-sheet)
    private var scenario: ([[String: Any]], Date, WPMyCarV2View.StartSheet?) {
        let sweep = rule(.aspMonThu, days: [1, 4], ranges: [(540, 630)],
                         description: "NO PARKING (SANITATION BROOM SYMBOL) MONDAY THURSDAY 9AM-10:30AM")
        let corner = rule(.noStanding, days: [], ranges: [], anytime: true,
                          description: "NO STANDING ANYTIME (ARROW)", arrow: "towards")
        switch name {
        case "soon":
            return ([rule(.aspTueFri, days: [2], ranges: [(540, 630)])], date(2026, 12, 1, 8, 11), nil)
        case "dont":
            return ([rule(.aspTueFri, days: [2], ranges: [(420, 630)])], date(2026, 12, 1, 9, 48), nil)
        case "meter":
            return ([rule(.metered, days: [0, 1, 2, 3, 4, 5, 6], ranges: [(480, 1140)])], date(2026, 12, 1, 16, 40), nil)
        case "nodata":
            return ([], date(2026, 12, 1, 10, 11), nil)
        case "unclear":
            return ([rule(.unknown, days: [], ranges: [], anytime: true, description: "UNREADABLE SIGN")], date(2026, 12, 1, 10, 11), nil)
        case "suspended":
            return ([sweep], date(2026, 11, 25, 10, 11), nil)
        case "remind":
            return ([sweep], date(2026, 11, 28, 10, 11), .reminders)
        case "leaving":
            return ([sweep], date(2026, 11, 28, 10, 11), .leaving)
        case "signs":
            return ([sweep, corner], date(2026, 11, 28, 10, 11), .signs)
        default: // legal
            return ([sweep], date(2026, 11, 28, 10, 11), nil)
        }
    }

    var body: some View {
        let (rules, now, start) = scenario
        let seg = segment(rules)
        let car = ParkedCar(
            id: UUID(), latitude: 40.7238, longitude: -73.9885,
            detectedSegmentID: name == "nodata" ? nil : seg?.id, detectedSide: "N",
            street: "EAST 1ST STREET", fromStreet: "1 AVENUE", toStreet: "2 AVENUE",
            parkedAt: now.addingTimeInterval(-3 * 3600 - 600), notifyOnRestriction: true,
            address: ParkingAddress(
                houseNumber: "50", streetDisplay: "East 1st Street", confidence: .verified,
                source: .mapkit, resolvedAt: now
            )
        )
        WPMyCarV2View(
            parkedCar: car,
            engine: ParkingRulesEngine(aspService: ASPSuspensionService()),
            loadedSegments: name == "nodata" ? [] : [seg].compactMap { $0 },
            parkPinService: parkPinService,
            aspService: ASPSuspensionService(),
            onDismiss: {},
            onClearPin: {},
            onOpenSpotPass: {},
            nowProvider: { now },
            addressesEnabled: true,
            startsWith: start
        )
    }
}
#endif
