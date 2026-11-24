//
//  WeParkClipApp.swift
//  WePark Clip (com.kevinhoxha.wepark.Clip)
//
//  Spot Pass C3: the real App Clip. Receives the QR / link invocation (NSUserActivityTypeBrowsingWeb),
//  hands it to `ClipFlowController`, and renders `ClipRootView`. No background modes, no App Intents
//  dependency, no Always location (spec 5.1).
//
//  QA (DEBUG only): `-spotPassClipURL <url>` or the `_XCAppClipURL` env var inject an invocation URL
//  at launch, because `simctl launch` sets `_XCAppClipURL` but never delivers the browsing activity.
//  See ClipDebugSupport.swift.
//

import SwiftUI

@main
struct WeParkClipApp: App {

    @UIApplicationDelegateAdaptor(ClipAppDelegate.self) private var appDelegate
    @State private var composition = ClipComposition.make()

    var body: some Scene {
        WindowGroup {
            ClipRootView(controller: composition.controller, block: composition.block)
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    composition.controller.handle(url: url)
                }
                .task {
                    let controller = composition.controller
                    ClipEventBridge.shared.handler = { identifier, userInfo in
                        controller.handleNotification(actionIdentifier: identifier, userInfo: userInfo)
                    }
                    #if DEBUG
                    if let url = composition.options.injectedURL { controller.handle(url: url) }
                    #endif
                }
                #if DEBUG
                .onChange(of: composition.controller.phase) { _, phase in
                    // QA: simulate the seeker's "Got it, thanks!" arriving some seconds after the pass.
                    guard phase == .celebration, let delay = composition.options.fakeThanksAfter else { return }
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        composition.controller.receiveThanks()
                    }
                }
                #endif
        }
    }
}
