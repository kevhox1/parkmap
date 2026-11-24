//
//  SpotPassResultViews.swift
//  Views/SpotPass
//
//  Spot Pass C1: the two terminal screens.
//    - `SpotPassSettledView`: the receipt after "Got it, thanks!" / "Didn't work out"
//      (`docs/design/spot-pass-design.md` §7.3, §7.4). Karma is shown ONLY when the server
//      confirmed a positive change (caps and pair cooldowns can award nothing), never as a
//      nominal promise.
//    - `SpotPassEndedView`: "Pass ended." (expired, or a silent driver cancel: no reason) and
//      "This Spot Pass has been paused." (suspended). Neutral gray plus a symbol, never red.
//

import SwiftUI

// MARK: - Settled

struct SpotPassSettledView: View {

    let outcome: SpotPassOutcome
    let karmaDelta: Int?
    let onKeepLooking: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: outcome == .gotSpot ? "checkmark.circle.fill" : "hand.thumbsup.fill")
                .font(.system(size: 64))
                .foregroundStyle(SpotPassTheme.lavender)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(outcome == .gotSpot ? SpotPassCopy.thanksTitle : SpotPassCopy.noLuckTitle)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if outcome == .gotSpot {
                    Text(SpotPassCopy.thanksSubtitle)
                        .font(.title3)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
            }

            if let karmaDelta, karmaDelta > 0 {
                KarmaChip(
                    label: outcome == .gotSpot
                        ? SpotPassCopy.karmaReceipt(karmaDelta)
                        : SpotPassCopy.noLuckKarmaReceipt(karmaDelta),
                    style: .settled
                )
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if outcome == .noLuck {
                    Button(action: onKeepLooking) { Text(SpotPassCopy.keepLooking) }
                        .buttonStyle(SpotPassButtonStyle(kind: .primary))
                    Button(action: onDone) { Text(SpotPassCopy.done) }
                        .buttonStyle(SpotPassButtonStyle(kind: .secondary))
                } else {
                    Button(action: onDone) { Text(SpotPassCopy.done) }
                        .buttonStyle(SpotPassButtonStyle(kind: .primary))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .spotPassBackdrop()
    }
}

// MARK: - Ended

struct SpotPassEndedView: View {

    let reason: SpotPassEndReason
    let onMakeNew: () -> Void
    let onDone: () -> Void

    private var isPaused: Bool { reason == .suspended }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: isPaused ? "pause.circle.fill" : "clock.badge.xmark")
                .font(.system(size: 64))
                .foregroundStyle(Color.gray)
                .accessibilityHidden(true)
            Text(isPaused ? SpotPassCopy.passPaused : SpotPassCopy.passEnded)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if !isPaused {
                    Button(action: onMakeNew) { Text(SpotPassCopy.makeNewPass) }
                        .buttonStyle(SpotPassButtonStyle(kind: .primary))
                }
                Button(action: onDone) { Text(SpotPassCopy.done) }
                    .buttonStyle(SpotPassButtonStyle(kind: isPaused ? .primary : .secondary))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .spotPassBackdrop()
    }
}
