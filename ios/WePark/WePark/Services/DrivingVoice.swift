//
//  DrivingVoice.swift
//  WePark
//
//  W8.5c: AVSpeechSynthesizer wrapper for Drive Mode parking commentary voice cues.
//
//  Port of `speakDrivingContext` (index.html:5957–5979) + `toggleDrivingModeVoice`
//  (index.html:5810–5816) behavior.
//
//  Design:
//    - @Observable final class (R-7 safety: not re-created on re-renders).
//    - Owns AVSpeechSynthesizer lifetime (one instance per DrivingVoice instance).
//    - Mute state persisted in UserDefaults key `wepark_dm_voice_muted`.
//    - Calls AudioSessionManager to activate/deactivate the audio session around each utterance.
//
//  OQ-7: Voice rate = AVSpeechUtteranceDefaultSpeechRate (0.5). Calibration deferred to
//  W8.5c-follow after first drive-test.
//
//  No import SwiftUI (QA invariant — pure service).
//  No Calendar.current.
//

import Foundation
import AVFoundation
import Observation

// MARK: - UserDefaults key

private let kMuteKey = "wepark_dm_voice_muted"

// MARK: - DrivingVoice

@Observable
class DrivingVoice: NSObject {

    // MARK: - Mute state (OQ-3: persists in UserDefaults)

    /// True when voice is muted. Persisted across sessions (index.html:5812).
    /// Setting to `true` immediately stops any in-flight speech (index.html:5815).
    var isMuted: Bool {
        get { _isMuted }
        set {
            _isMuted = newValue
            UserDefaults.standard.set(newValue, forKey: kMuteKey)
            if newValue {
                stopImmediate()
            }
        }
    }

    // Backing storage — separate from the computed property so @Observable tracks it.
    private var _isMuted: Bool

    // MARK: - Private

    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "en-US")

    // MARK: - Init

    override init() {
        _isMuted = UserDefaults.standard.bool(forKey: kMuteKey)
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Speak a parking cue. If muted, is a no-op.
    /// Cancels any in-flight utterance before enqueueing the new one to prevent stacking.
    ///
    /// Port of speakDrivingContext's speech block (index.html:5971–5975).
    func speak(_ text: String) {
        guard !isMuted else { return }
        guard !text.isEmpty else { return }

        // Activate audio session before speaking (R-2: catch errors, don't crash).
        AudioSessionManager.shared.activateDriveSession()

        // Cancel any pending utterance so cues don't stack when blocks change quickly.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate  // 0.5 (OQ-7)
        synthesizer.speak(utterance)
    }

    /// Immediately stops any in-flight speech.
    /// Called on mute toggle (index.html:5815: `window.speechSynthesis?.cancel()`).
    func stopImmediate() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension DrivingVoice: AVSpeechSynthesizerDelegate {

    /// Called when each utterance finishes. Deactivates the audio session so
    /// background audio (music, podcasts) can resume between cues (AC-W85c.18).
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        AudioSessionManager.shared.deactivateAfterUtterance()
    }
}
