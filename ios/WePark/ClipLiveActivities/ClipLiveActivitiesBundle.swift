//
//  ClipLiveActivitiesBundle.swift
//  Clip Live Activities widget extension (Live-Activities-only, as Apple requires for App Clips).
//
//  Spot Pass C0 scaffold: an empty placeholder Live Activity on the shared attributes. It is
//  never started in C0. C3 replaces the views (deep-link variant of the "Leaving now" button).
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ClipLiveActivitiesBundle: WidgetBundle {
    var body: some Widget {
        SpotPassClipLiveActivity()
    }
}

struct SpotPassClipLiveActivity: Widget {
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
