//
//  AudioSessionManager.swift
//  WePark
//
//  W8.5c: AVAudioSession configuration for Drive Mode voice (AC-W85c.17, AC-W85c.18, AC-W85c.19).
//
//  Configures the shared AVAudioSession with .playback category and
//  [.duckOthers, .interruptSpokenAudioAndMixWithOthers] options when Drive Mode activates.
//  Deactivates with .notifyOthersOnDeactivation after each utterance (via DrivingVoice delegate)
//  so music / podcasts resume promptly between parking cues.
//
//  R-2 (spec §7): AVAudioSession activation is called from the main thread (via DrivingVoice.speak,
//  which is called from ContentView's .onChange on the main thread). Errors are caught and logged
//  rather than surfaced — if the session fails to activate, voice simply won't play (acceptable).
//
//  No import SwiftUI (QA invariant — pure service).
//  No Calendar.current.
//

import Foundation
import AVFoundation

// MARK: - AudioSessionManager

final class AudioSessionManager {

    // MARK: - Singleton

    static let shared = AudioSessionManager()
    private init() {}

    // MARK: - Drive session management

    /// Activates the AVAudioSession for Drive Mode voice cues.
    /// Category: .playback — allows speech over silenced ringer.
    /// Options: .duckOthers (lower background audio) + .interruptSpokenAudioAndMixWithOthers
    ///          (mix with other audio instead of fully interrupting it).
    ///
    /// Call once at Drive Mode start, before `DrivingVoice.speak(_:)` is first invoked.
    func activateDriveSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try session.setActive(true)
        } catch {
            // R-2: Don't crash if session activation fails (e.g. other app holds exclusive session).
            // Voice simply won't play — acceptable degradation.
            print("[AudioSessionManager] activateDriveSession failed: \(error)")
        }
    }

    /// Deactivates the AVAudioSession after a single utterance completes.
    /// Passing .notifyOthersOnDeactivation allows background audio (music, podcasts)
    /// to resume after the voice cue finishes.
    ///
    /// Called from `DrivingVoice`'s `speechSynthesizer(_:didFinish:)` delegate.
    func deactivateAfterUtterance() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[AudioSessionManager] deactivateAfterUtterance failed: \(error)")
        }
    }

    /// Deactivates the AVAudioSession at Drive Mode exit.
    /// Same call as deactivateAfterUtterance — named separately for call-site clarity.
    func deactivateDriveSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[AudioSessionManager] deactivateDriveSession failed: \(error)")
        }
    }
}
