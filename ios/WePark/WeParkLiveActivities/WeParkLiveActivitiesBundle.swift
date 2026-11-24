//
//  WeParkLiveActivitiesBundle.swift
//  Full-app Live Activities widget extension.
//
//  Spot Pass C0 scaffold: an empty placeholder Live Activity on the shared attributes. It is
//  never started in C0. C2 replaces the views (App Intent "Leaving now" button).
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct WeParkLiveActivitiesBundle: WidgetBundle {
    var body: some Widget {
        SpotPassLiveActivity()
    }
}

struct SpotPassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpotPassActivityAttributes.self) { context in
            Text(context.attributes.alias)
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.alias)
                }
            } compactLeading: {
                Image(systemName: "parkingsign")
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: "parkingsign")
            }
        }
    }
}
