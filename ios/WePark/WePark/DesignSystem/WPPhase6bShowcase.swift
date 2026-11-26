//
//  WPPhase6bShowcase.swift
//  WePark
//
//  DEBUG-only QA aid (compiled out of Release). With the launch argument `-wp6bShowcase <name>`
//  ContentView mounts the REAL Stoop Phase 6b views over fixture values in their own window, so
//  light/dark and Dynamic Type screenshots are repeatable without a live trip or a failing network:
//
//    planner planner-error planner-picked trip-card trip-card-nocal
//    noloc outside server account nocar nocurbs limits
//    guide (the Parking 101 screen; it reads the Stoop flag, so run it flag-on)
//
//  `-wpDark` forces dark (default is light, the Stoop default).
//
//  `-wp6bTrip <weekend|tomorrow|nocal>` is separate: it starts a REAL trip plan on the live map
//  (`WPPhase6bTripHook`), so the dashed frame, the tag and the live-control gating can be smoked.
//  Nothing here runs in a Release build or without the launch argument.
//

#if DEBUG
import SwiftUI

struct WPPhase6bShowcase: View {
    let name: String

    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-wp6bShowcase"), i + 1 < args.count else { return nil }
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
            window.overrideUserInterfaceStyle = ProcessInfo.processInfo.arguments.contains("-wpDark") ? .dark : .light
            window.rootViewController = UIHostingController(rootView: WPPhase6bShowcaseContent(name: name))
            window.makeKeyAndVisible()
            Self.window = window
        }
    }
}

/// `-wp6bTrip`: sets a real trip plan on the live map after launch.
struct WPPhase6bTripHook: View {
    @Binding var tripPlan: TripPlan?
    let onSet: () -> Void

    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-wp6bTrip"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// The fixture plan for a name (Eastern time). `nocal` falls in January of next year, past the
    /// bundled street-cleaning calendar.
    static func plan(named name: String, now: Date) -> TripPlan? {
        switch name {
        case "tomorrow": return TripPlanning.quickPick(.tomorrow, now: now)
        case "nocal":
            let cal = Calendar.easternTime
            let year = cal.component(.year, from: now) + 1
            guard let sat = cal.date(from: DateComponents(year: year, month: 1, day: 2, hour: 10)),
                  let sun = cal.date(from: DateComponents(year: year, month: 1, day: 3, hour: 18)) else { return nil }
            return TripPlan(arrival: sat, departure: sun)
        default: return TripPlanning.quickPick(.thisWeekend, now: now)
        }
    }

    var body: some View {
        Color.clear.allowsHitTesting(false).onAppear {
            guard let name = Self.requested, tripPlan == nil,
                  let plan = Self.plan(named: name, now: .nowET) else { return }
            tripPlan = plan
            onSet()
        }
    }
}

private struct WPPhase6bShowcaseContent: View {
    let name: String

    private var weekend: TripPlan {
        TripPlanning.quickPick(.thisWeekend, now: .nowET)
            ?? TripPlan(arrival: Date.nowET.addingTimeInterval(86_400), departure: Date.nowET.addingTimeInterval(2 * 86_400))
    }

    var body: some View {
        switch name {
        case "planner":
            WPTripPlannerV2(initialPlan: weekend, onConfirm: { _ in }, onCancel: {})
        case "planner-picked":
            WPTripPlannerV2(initialPlan: nil, onConfirm: { _ in }, onCancel: {})
        case "planner-error":
            // Leave before Arrive: the red row, the dashed box and a greyed "Show trip map".
            WPTripPlannerV2(
                initialPlan: TripPlan(arrival: weekend.arrival, departure: weekend.arrival.addingTimeInterval(-86_400)),
                onConfirm: { _ in }, onCancel: {}
            )
        case "trip-card", "trip-card-nocal":
            tripMap(noCalendar: name == "trip-card-nocal")
        case "noloc":
            state(WPStateCopy.noLocation)
        case "outside":
            state(WPStateCopy.outsideCoverage(place: "Astoria, Queens", canSuggest: true))
        case "server":
            state(WPStateCopy.serverDown)
        case "account":
            state(WPStateCopy.account)
        case "nocar":
            WPBlockingStateScreen(copy: WPStateCopy.noCar, showsCarToken: true, onPrimary: {}, onSecondary: nil, onClose: {})
        case "nocurbs":
            VStack {
                Spacer()
                WPNoCurbsCard(onTryAgain: {}).padding(14)
            }
            .background(WP.mapBlock.ignoresSafeArea())
        case "limits":
            VStack(spacing: WP.Space.s4) {
                limit(WPStateCopy.offline(asOf: "10:02 PM"))
                limit(WPStateCopy.whileUsingOnly)
                limit(WPStateCopy.notificationsOff)
            }
            .padding(WP.Space.screenMargin)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(WP.paper.ignoresSafeArea())
        case "guide":
            NavigationStack { ParkingGuideView() }
        default:
            WPTripPlannerV2(initialPlan: weekend, onConfirm: { _ in }, onCancel: {})
        }
    }

    private func state(_ copy: WPStateCopy.Screen) -> some View {
        WPBlockingStateScreen(copy: copy, onPrimary: copy.primary == nil ? nil : {}, onSecondary: {}, onClose: {})
    }

    private func limit(_ limit: WPStateCopy.Limit) -> some View {
        WPLimitRow(message: limit.message, fixTitle: limit.fix) {}
    }

    private func tripMap(noCalendar: Bool) -> some View {
        let plan = noCalendar ? (WPPhase6bTripHook.plan(named: "nocal", now: .nowET) ?? weekend) : weekend
        return ZStack(alignment: .bottom) {
            WP.mapBlock.ignoresSafeArea()
            VStack {
                WPTripTopTag(plan: plan, now: .nowET)
                Spacer()
            }
            WPTripMapCard(
                plan: plan, now: .nowET,
                arrivalCovered: !noCalendar, departureCovered: !noCalendar,
                onChangeDates: {}, onBackToLive: {}
            )
            .padding(14)
        }
        .wpTripFrame()
    }
}
#endif
