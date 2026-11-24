//
//  SpotPassDepartedView.swift
//  Views/SpotPass
//
//  Spot Pass C1: "Spot opening up." and the outcome buttons (`docs/design/spot-pass-design.md`
//  §9.4). Both buttons are big and neutral: "Didn't work out" is never red and never styled as a
//  failure. The safety line is plain: "Stay alert when you head over." No "hurry", no "grab it".
//

import SwiftUI

struct SpotPassDepartedView: View {

    let session: SpotPassSession
    let isSubmitting: Bool
    let submitFailed: Bool
    let onGotIt: () -> Void
    let onDidntWorkOut: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ZStack {
                    if !reduceMotion {
                        RippleRings()
                    }
                    AliasGlyphDisc(
                        symbolName: SpotPassGlyph.symbolName(for: session.glyph),
                        tintIndex: SpotPassGlyph.tintIndex(for: session.id),
                        size: 160,
                        showsCheckSeal: true
                    )
                }
                .frame(width: 240, height: 240)
                .padding(.top, 24)

                VStack(spacing: 8) {
                    Text(SpotPassCopy.departedTitle)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(SpotPassCopy.departedSubtitle)
                        .font(.title3)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }

                Text(SpotPassCopy.departedSafety)
                    .font(.footnote)
                    .foregroundStyle(SpotPassTheme.lavender)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if submitFailed {
                    Text(SpotPassCopy.outcomeSubmitFailed)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Button(action: onGotIt) { Text(SpotPassCopy.gotIt) }
                    .buttonStyle(SpotPassButtonStyle(kind: .primary, minHeight: SpotPassTheme.heroButtonHeight))
                Button(action: onDidntWorkOut) { Text(SpotPassCopy.didntWorkOut) }
                    .buttonStyle(SpotPassButtonStyle(kind: .secondary))
            }
            .disabled(isSubmitting)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .spotPassBackdrop()
    }
}

/// Two ripple rings from the glyph disc (design §9.4). Not drawn under Reduce Motion.
private struct RippleRings: View {
    @State private var expanded = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .strokeBorder(SpotPassTheme.lavender.opacity(expanded ? 0 : 0.5), lineWidth: 2)
                    .scaleEffect(expanded ? 1.5 : 0.7)
                    .animation(
                        .easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(Double(index) * 0.6),
                        value: expanded
                    )
            }
        }
        .onAppear { expanded = true }
        .accessibilityHidden(true)
    }
}
