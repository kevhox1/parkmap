//
//  NotificationCategoryRegistry.swift
//  Services/SpotPass
//
//  `UNUserNotificationCenter.setNotificationCategories(_:)` REPLACES the whole set. PR #158's
//  `registerAddressCategory()` called it with one category, which was safe only while WePark had
//  no other categories. Spot Pass adds one, so every registration now goes through here: read what
//  is registered, add/replace by identifier, write the union back. Order-independent, so address
//  anchoring and Spot Pass can each be on or off without clobbering the other (or any category a
//  later stream adds, e.g. C2's `SPOT_PASS_LEAVING`).
//
//  Race note: two independent read-modify-write registrations could interleave and lose one. The
//  launch path therefore builds the full desired list from the flags and registers it in ONE call
//  (`registerLaunchCategories`).
//

import Foundation
import UserNotifications

/// The slice of `UNUserNotificationCenter` the registry needs, so the merge is testable.
@MainActor
protocol NotificationCategoryCenter: AnyObject {
    func registeredCategories() async -> Set<UNNotificationCategory>
    func replaceCategories(_ categories: Set<UNNotificationCategory>)
}

@MainActor
final class SystemNotificationCategoryCenter: NotificationCategoryCenter {
    func registeredCategories() async -> Set<UNNotificationCategory> {
        await UNUserNotificationCenter.current().notificationCategories()
    }

    func replaceCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
}

enum NotificationCategoryRegistry {

    /// Category for the seeker's Spot Pass alerts. No actions (the app opens to the pass); the
    /// hidden-previews placeholder keeps the alert text off the lock screen when previews are off.
    nonisolated static let spotPassSeekerCategoryID = "wepark_spot_pass_seeker"

    /// Pure merge: `adding` wins over `existing` for the same identifier; every other existing
    /// category survives.
    nonisolated static func merged(
        existing: Set<UNNotificationCategory>,
        adding: [UNNotificationCategory]
    ) -> Set<UNNotificationCategory> {
        let addedIDs = Set(adding.map(\.identifier))
        var result = existing.filter { !addedIDs.contains($0.identifier) }
        for category in adding { result.insert(category) }
        return result
    }

    /// Reads, merges, writes. No-op for an empty `adding` (never touches the center).
    @MainActor
    static func register(
        _ adding: [UNNotificationCategory],
        center: (any NotificationCategoryCenter)? = nil
    ) async {
        guard !adding.isEmpty else { return }
        let target: any NotificationCategoryCenter = center ?? SystemNotificationCategoryCenter()
        let existing = await target.registeredCategories()
        target.replaceCategories(merged(existing: existing, adding: adding))
    }

    nonisolated static func spotPassSeekerCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: spotPassSeekerCategoryID,
            actions: [],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Spot Pass",
            options: []
        )
    }

    /// The categories the launch path wants, from the feature flags. Empty when both are off.
    @MainActor
    static func launchCategories(
        addressEnabled: Bool,
        spotPassEnabled: Bool,
        includeDriverReminders: Bool = false
    ) -> [UNNotificationCategory] {
        var categories: [UNNotificationCategory] = []
        if addressEnabled { categories.append(NotificationScheduler.addressCategory()) }
        if spotPassEnabled { categories.append(spotPassSeekerCategory()) }
        // C2: the driver's `SPOT_PASS_LEAVING` reminder category (background actions). Registered at
        // launch too (not only when a pass arms) so an action tapped after a relaunch still resolves.
        if includeDriverReminders { categories.append(DriverReminderCategory.category()) }
        return categories
    }

    /// One merge-safe registration for everything the flags turn on.
    @MainActor
    static func registerLaunchCategories(
        addressEnabled: Bool = AppConstants.addressAnchoredParkingEnabled,
        spotPassEnabled: Bool = AppConstants.spotHandoffEnabled,
        includeDriverReminders: Bool = false,
        center: (any NotificationCategoryCenter)? = nil
    ) async {
        await register(
            launchCategories(
                addressEnabled: addressEnabled, spotPassEnabled: spotPassEnabled,
                includeDriverReminders: includeDriverReminders
            ),
            center: center
        )
    }
}
