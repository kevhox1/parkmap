//
//  SpotPassComposition.swift
//  Services/SpotPass
//
//  Spot Pass C1: builds the seeker store from the app's shared auth service. Called only when
//  `AppConstants.spotHandoffEnabled` is true (ContentView builds it lazily), so with the flag off
//  none of this runs.
//
//  DEBUG builds can swap the network for `FakeSpotPassAPI.demo()` with the launch argument
//  `-spotPassUseFakeAPI YES` (compiled out of Release).
//

import Foundation

@MainActor
enum SpotPassComposition {

    #if DEBUG
    nonisolated static let useFakeAPILaunchKey = "spotPassUseFakeAPI"
    #endif

    static func makeStore(authService: SupabaseAuthService) -> SpotPassSeekerStore {
        let api: any SpotPassAPI
        #if DEBUG
        if UserDefaults.standard.bool(forKey: useFakeAPILaunchKey) {
            api = FakeSpotPassAPI.demo()
        } else {
            api = SupabaseSpotPassAPI(authService: authService)
        }
        #else
        api = SupabaseSpotPassAPI(authService: authService)
        #endif
        return SpotPassSeekerStore(
            api: api,
            persistence: UserDefaultsSpotPassPersistence(),
            feedback: SpotPassSystemFeedback()
        )
    }
}
