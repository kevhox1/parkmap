//
//  WPPhase2bShowcase.swift
//  WePark
//
//  DEBUG-only QA aid (compiled out of Release). With the launch argument
//  `-wp2bShowcase <name>` ContentView overlays one Phase 2b surface on the REAL map, using a REAL
//  loaded Manhattan curb that the engine classifies into the wanted state (no hand-made verdicts):
//
//    curb-free curb-soon curb-dont curb-meter curb-nodata curb-unclear curb-planfree curb-plandont
//    curb-temp curb-swept curb-chatter curb-signs curb-ax5
//    snap-park snap-dont confirm-park confirm-dont
//
//  Neighbor-report pins (temp / swept / chatter) are synthetic JSON pins, because no real
//  community data exists in the simulator; the verdict logic they exercise is the production path.
//  Nothing here runs in a Release build or without the launch argument.
//

#if DEBUG
import CoreLocation
import SwiftUI

struct WPPhase2bShowcase: View {
    let name: String
    let segments: [Segment]
    let engine: ParkingRulesEngine

    static var isActive: Bool { requested != nil }

    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-wp2bShowcase"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private var now: Date { .nowET }
    private var windowEnd: Date { ParkingGoals.target(for: .freeOvernight, from: now) }

    private var trip: TripPlan {
        // Next Saturday 10 AM to Sunday 6 PM ET.
        let cal = Calendar.easternTime
        let date = (1...8).map { now.startOfDayET(offsetDays: $0) }
            .first { cal.component(.weekday, from: $0) == 7 } ?? now.startOfDayET(offsetDays: 3)
        let arrival = date.addingTimeInterval(10 * 3600)
        return TripPlan(arrival: arrival, departure: arrival.addingTimeInterval(32 * 3600))
    }

    private func variantWanted() -> WPCurbVariant? {
        switch name {
        case "curb-free", "curb-signs", "curb-chatter", "confirm-park", "snap-park", "curb-ax5", "curb-temp": return .park
        case "curb-soon": return .soon
        case "curb-dont", "curb-swept", "snap-dont", "confirm-dont": return .dont
        case "curb-meter": return .meter
        case "curb-nodata": return .nodata
        case "curb-unclear": return .unclear
        case "curb-planfree": return .planpark
        case "curb-plandont": return .plandont
        default: return nil
        }
    }

    private var usesTrip: Bool { name == "curb-planfree" || name == "curb-plandont" }

    private func pick() -> (Segment, WPCurbSheetModel)? {
        guard let want = variantWanted() else { return nil }
        // Prefer curbs near the map center (the first loaded ones are near the user).
        for segment in segments {
            let m = WPCurbSheetBuilder.make(
                segment: segment, engine: engine, now: now, windowEnd: windowEnd, trip: usesTrip ? trip : nil
            )
            guard m.variant == want else { continue }
            // Signs list demo wants a curb with 2+ signs; the sheet always shows them when present.
            if name == "curb-signs", m.signCount < 2 { continue }
            return (segment, m)
        }
        return nil
    }

    private func pin(type: String, segmentId: String, expires: String?, confirms: Int = 3, minutesAgo: Int = 20) -> CommunityPin? {
        let created = Date().addingTimeInterval(-Double(minutesAgo) * 60)
        let iso = ISO8601DateFormatter().string(from: created)
        let exp = expires.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id": "\(UUID().uuidString)", "pin_type": "\(type)", "source": "crowd", "lifespan": "ephemeral",
         "lat": 40.73, "lng": -73.98, "segment_id": "\(segmentId)", "author_id": null,
         "author_username": "Stoop Pigeon", "created_at": "\(iso)", "updated_at": "\(iso)",
         "expires_at": \(exp), "resolved_at": null, "confirm_count": \(confirms), "dispute_count": 0,
         "meta": null, "notes": null}
        """.data(using: .utf8) ?? Data()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CommunityPin.self, from: json)
    }

    var body: some View {
        if let (segment, base) = pick() {
            content(segment: segment, base: base)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(segment: Segment, base: WPCurbSheetModel) -> some View {
        let sweeper = name == "curb-swept" ? pin(type: "sweeper_passed", segmentId: segment.id, expires: nil) : nil
        let live: [CommunityPin] = name == "curb-chatter"
            ? [pin(type: "leaving_soon", segmentId: segment.id, expires: nil, minutesAgo: 2),
               pin(type: "enforcement_active", segmentId: segment.id, expires: nil, minutesAgo: 35)].compactMap { $0 }
            : []
        let reports = WPNeighborReports(
            restrictionLabel: name == "curb-temp" ? "Blocked for filming" : nil,
            restrictionIsActive: name == "curb-temp"
        )
        let model = WPNeighborVerdict.apply(reports, to: base)
        let restrictionPin: CommunityPin? = name == "curb-temp"
            ? pin(type: "filming", segmentId: segment.id, expires: ISO8601DateFormatter().string(from: Date().addingTimeInterval(6 * 3600)), minutesAgo: 20)
            : nil
        switch name {
        case "snap-park", "snap-dont":
            snapDemo(model: model)
        case "confirm-park", "confirm-dont":
            VStack { Spacer(); WPParkConfirmCard(model: model, address: "In front of 61 E 12th St", onPark: {}, onCancel: {}) }
        default:
            VStack(spacing: 0) {
                Spacer()
                WPCurbSheetV2(
                    model: model,
                    signs: WPSignList.lines(for: segment, engine: engine, now: now),
                    reportedRestriction: restrictionPin,
                    sweeperPin: sweeper,
                    livePins: live,
                    now: now,
                    segmentID: segment.id,
                    segmentMidpoint: segment.midpoint,
                    planTag: usesTrip ? WPCurbCopy.tripRange(trip) : nil,
                    onClose: {}, onPark: {}, onReport: {},
                    startsWithSignsOpen: name == "curb-signs"
                )
                .frame(height: UIScreen.main.bounds.height * (UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory ? 0.92 : (name == "curb-chatter" || name == "curb-signs" ? 0.78 : 0.52)))
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: WP.Radius.sheet, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: WP.Radius.sheet, style: .continuous))
                .overlay(alignment: .top) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: WP.Radius.sheet, bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0, topTrailingRadius: WP.Radius.sheet, style: .continuous)
                        .strokeBorder(WP.line, lineWidth: WP.Border.fact)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func snapDemo(model: WPCurbSheetModel) -> some View {
        ZStack {
            WPDragBubbleView(bubble: WPDragBubble.make(from: model, windowName: nil))
                .position(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height * 0.34)
            WPCarToken(isLifted: true)
                .scaleEffect(64.0 / 56.0)
                .position(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height * 0.42)
            VStack {
                Spacer()
                WPSheetShell {
                    Text(WPDragBubble.make(from: model, windowName: nil).hint)
                        .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                        .foregroundStyle(WP.text)
                    Text(model.title)
                        .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                        .foregroundStyle(WP.text)
                }
            }
        }
        .ignoresSafeArea()
    }
}
#endif
