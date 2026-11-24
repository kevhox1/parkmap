//
//  SpotPassShared.swift
//  Shared/SpotPass — compiled into the full app, the App Clip, and both Live Activity extensions.
//
//  Spot Pass C0 scaffold (docs/specs/qr-spot-handoff.md §5, §6.2, §8). Names only: identifiers
//  and constants every stream agrees on. No behavior lives here.
//
//  Isolation: the app and clip targets build with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so
//  every pure type in this folder is explicitly `nonisolated` — usable from tests, extensions and
//  background contexts regardless of the target it is compiled into.
//

import Foundation

nonisolated enum SpotPassShared {

    // MARK: - Identity

    static let appBundleID = "com.kevinhoxha.wepark"
    static let clipBundleID = "com.kevinhoxha.wepark.Clip"

    // MARK: - Universal link (must stay consistent with web/getwepark/.well-known/apple-app-site-association)

    /// The registered association domain. The entitlements carry `applinks:` (app) and
    /// `appclips:` (clip) for this host.
    static let universalLinkHost = "getwepark.com"

    /// `/p` (no token) and `/p/*` are the AASA components. The token itself travels in the
    /// URL fragment (`#t=`), with `?t=` as the fallback form.
    static let landingPath = "/p"

    // MARK: - Carry-over (clip -> full app, spec §6.2)

    /// App Group shared by the app and the clip (entitlement `com.apple.security.application-groups`).
    static let appGroupID = "group.com.kevinhoxha.wepark.shared"

    /// Key in the App Group `UserDefaults` holding the JSON-encoded `ClipHandoffContext`.
    static let carryOverDefaultsKey = "clipHandoffContext"

    /// Distinct `kSecAttrLabel` for the clip's keychain items (spec §6.2). Clip keychain items are
    /// readable by the full app from iOS 15.4; the label keeps them separable from the app's own.
    static let clipKeychainLabel = "wepark-appclip"

    /// Reserved name for a shared keychain access group (team prefix + this suffix). NOT present
    /// in any entitlements file: the spec's carry-over relies on the clip-to-app keychain
    /// readability above, so C0 adds no keychain-access-groups entitlement. C2/C3 should only
    /// start using it together with the entitlement and a portal check.
    static let keychainAccessGroupSuffix = "com.kevinhoxha.wepark.shared"

    /// The shared `UserDefaults` suite, or nil when it cannot be opened. Callers must tolerate nil.
    static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
}
