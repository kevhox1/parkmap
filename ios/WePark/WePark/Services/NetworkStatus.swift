//
//  NetworkStatus.swift
//  WePark
//
//  Phase 2a: the offline banner ("Showing posted signs as of <time>. No live reports.") needs to
//  know when the phone has no network. Curb rules ship in the app bundle, so offline only means
//  live reports are unavailable. `lastOnlineAt` is the last moment a path was satisfied; the
//  banner calls that the time the posted signs were last refreshed alongside live data.
//
//  Started only while `AppConstants.designSystemV2Enabled` is true.
//

import Foundation
import Network
import Observation

@Observable
@MainActor
final class NetworkStatus {

    private(set) var isOffline = false
    private(set) var lastOnlineAt: Date = Date()

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The moment we lose the path is the last moment we were online.
                if satisfied || !self.isOffline { self.lastOnlineAt = Date() }
                if self.isOffline != !satisfied { self.isOffline = !satisfied }
            }
        }
        monitor.start(queue: DispatchQueue(label: "wepark.network-status"))
    }

    deinit { monitor.cancel() }

    /// "10:02 PM" in Eastern Time (the app's clock everywhere else).
    var lastOnlineLabel: String { WPGoalCopy.clock(lastOnlineAt) }
}
