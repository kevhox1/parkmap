//
//  ToastService.swift
//  WePark
//
//  W7 (§3.E): Reusable singleton Toast primitive.
//
//  Provides a single-toast-at-a-time surface for transient action confirmations.
//  A new `show(message:)` call replaces any toast currently visible and resets
//  the auto-dismiss timer. No queueing in v1.
//
//  Architecture:
//    - @MainActor @Observable singleton (consistent with W6 @Observable adoption).
//    - `currentMessage`: observed by ToastHostView to drive rendering.
//    - `show(message:duration:)`: cancels any existing dismiss task, animates in,
//      then schedules a new auto-dismiss Task after `duration` seconds.
//    - `dismissTask?.cancel()` on each show ensures the previous timer never fires
//      after the new toast has replaced the old one.
//
//  Callers on the main thread call `show(message:)` directly.
//  Background callers use: `await MainActor.run { ToastService.shared.show(...) }`.
//
//  W7 trigger:
//    ContentView.onUnmute closure calls `ToastService.shared.show(message: "Reminders re-enabled")`
//    when the global mute toggle flips from OFF → ON.
//
//  Future callers (W7.5+): call `ToastService.shared.show(message:)` from any action site
//  without changes to this file or ToastHostView.
//
//  No Calendar.current use. No import SwiftUI.
//

import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class ToastService {

    // MARK: - Singleton

    static let shared = ToastService()
    init() {}

    // MARK: - State

    /// The message currently being displayed. Nil when no toast is visible.
    /// Observed by ToastHostView to drive conditional rendering.
    private(set) var currentMessage: String? = nil

    // MARK: - Private

    private var dismissTask: Task<Void, Never>?

    // MARK: - Public API

    /// Shows a toast with the given message.
    ///
    /// If a toast is already visible, it is replaced immediately and the
    /// auto-dismiss timer resets to a full `duration` seconds from this call.
    ///
    /// - Parameters:
    ///   - message: The text to display.
    ///   - duration: Seconds until the toast auto-dismisses. Default: 3.0.
    func show(message: String, duration: TimeInterval = 3.0) {
        // Cancel any in-flight dismiss timer so the old timer does not fire
        // and clear the new toast prematurely.
        dismissTask?.cancel()

        withAnimation(.easeInOut(duration: 0.25)) {
            currentMessage = message
        }

        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                currentMessage = nil
            }
        }
    }
}
