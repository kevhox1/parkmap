//
//  SpotPassScreenController.swift
//  Services/SpotPass
//
//  Spot Pass C1: the "hold it up to your window" posture (`docs/design/spot-pass-design.md` §1.6,
//  §2.6). While the QR is showing: the screen never auto-locks and brightness is forced up (Max
//  100%, or Night 70% so the cabin is not glared). Everything is restored the moment the pass
//  leaves `created`, the view disappears, the app backgrounds, or an outcome sheet takes over.
//
//  Brightness goes through the window scene's screen (`UIScreen.main` is deprecated for scenes).
//  If the seeker drags the system slider more than 2 s after a boost, their choice is respected
//  until the next appear.
//

import UIKit

/// Pure policy so the rules are unit-testable without a screen.
nonisolated enum SpotPassBrightnessPolicy {

    static let maxBrightness: CGFloat = 1.0
    static let nightBrightness: CGFloat = 0.7

    /// Boost and keep awake only while the QR is the thing on screen and the app is frontmost.
    static func shouldBoost(phase: SpotPassPhase, isSceneActive: Bool) -> Bool {
        isSceneActive && phase == .open
    }

    static func target(night: Bool) -> CGFloat {
        night ? nightBrightness : maxBrightness
    }
}

@MainActor
final class SpotPassScreenController {

    private var savedBrightness: CGFloat?
    private var boostedAt: Date?
    private var lastSetBrightness: CGFloat?
    private var userOverrode = false
    private var observer: NSObjectProtocol?
    private var rampTask: Task<Void, Never>?
    private var isRamping = false

    /// Applies or releases the posture. Idempotent: call on every relevant state change.
    /// `night` changes re-assert the target (an explicit tap clears a manual override).
    func apply(boost: Bool, night: Bool, nightChanged: Bool = false) {
        UIApplication.shared.isIdleTimerDisabled = boost
        guard let screen = Self.currentScreen() else { return }

        if boost {
            if savedBrightness == nil {
                savedBrightness = screen.brightness
                boostedAt = Date()
                userOverrode = false
                startObserving(screen: screen)
            }
            if nightChanged { userOverrode = false }
            if !userOverrode { ramp(screen: screen, to: SpotPassBrightnessPolicy.target(night: night)) }
        } else {
            stopObserving()
            if let saved = savedBrightness {
                ramp(screen: screen, to: saved)
            }
            savedBrightness = nil
            boostedAt = nil
            lastSetBrightness = nil
        }
    }

    /// Releases everything immediately (view teardown).
    func end() {
        apply(boost: false, night: false)
    }

    // MARK: - Private

    private static func currentScreen() -> UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.screen
            ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    /// 0.25 s ramp in five steps.
    private func ramp(screen: UIScreen, to target: CGFloat) {
        rampTask?.cancel()
        let start = screen.brightness
        lastSetBrightness = target
        guard abs(start - target) > 0.01 else {
            isRamping = false
            screen.brightness = target
            return
        }
        isRamping = true
        rampTask = Task { @MainActor in
            let steps = 5
            for step in 1...steps {
                if Task.isCancelled { return }
                screen.brightness = start + (target - start) * CGFloat(step) / CGFloat(steps)
                try? await Task.sleep(for: .milliseconds(50))
            }
            screen.brightness = target
            // Let the resulting brightness notification pass before treating changes as the user's.
            try? await Task.sleep(for: .milliseconds(100))
            isRamping = false
        }
    }

    private func startObserving(screen: UIScreen) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIScreen.brightnessDidChangeNotification,
            object: screen,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.brightnessChanged(screen: screen)
            }
        }
    }

    private func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        rampTask?.cancel()
    }

    /// A change more than 2 s after the boost that is not our own ramp means the seeker moved the slider.
    private func brightnessChanged(screen: UIScreen) {
        guard let boostedAt, let target = lastSetBrightness else { return }
        guard Date().timeIntervalSince(boostedAt) > 2 else { return }
        if abs(screen.brightness - target) > 0.05, !isRamping {
            userOverrode = true
        }
    }
}
