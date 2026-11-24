//
//  SpotPassActivityAttributes.swift
//  Shared/SpotPass
//
//  PLACEHOLDER ActivityAttributes shared by the app, the clip and both Live Activity extensions
//  (the type must be identical in every process that starts, updates or renders the activity).
//  C2 (app) and C3 (clip) own the real shape; keep payloads under ActivityKit's 4 KB limit and
//  never put a location, address, plate or username in it (spec §9).
//

import ActivityKit
import Foundation

nonisolated struct SpotPassActivityAttributes: ActivityAttributes {

    nonisolated struct ContentState: Codable, Hashable {
        /// Planned departure time; nil until a pass is armed.
        var leaveAt: Date?
    }

    /// The friendly alias the pass carries ("Bodega Cat").
    var alias: String
}
