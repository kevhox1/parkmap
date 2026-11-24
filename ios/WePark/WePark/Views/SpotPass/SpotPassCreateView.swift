//
//  SpotPassCreateView.swift
//  Views/SpotPass
//
//  Spot Pass C1: the first-time explainer, the "making your pass" spinner and the create-failed
//  state (`docs/design/spot-pass-design.md` §9.2, §9.5). Pure presentation: the flow view owns
//  the actions.
//
//  First run: the explainer teaches the "hold it up to your window" posture and carries the
//  opt-in "Show my first name" toggle (OFF by default; disabled with a helper line when no first
//  name is on file, F12). After the first time the explainer is skipped and the badge opens
//  directly.
//

import SwiftUI

// MARK: - Explainer

struct SpotPassExplainerView: View {

    /// The seeker's first name if one is on file (enables the toggle), else nil.
    let firstName: String?
    @Binding var showFirstName: Bool
    let onCreate: () -> Void
    let onClose: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var toggleEnabled: Bool { firstName != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                SpotPassTextButton(title: "Close", minHeight: SpotPassTheme.buttonHeight, action: onClose)
            }
            .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(SpotPassCopy.explainerTitle)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)

                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(SpotPassCopy.explainerSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 14) {
                                Text("\(index + 1)")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(SpotPassTheme.indigo, in: Circle())
                                    .accessibilityHidden(true)
                                Text(step)
                                    .font(.body)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 10)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Step \(index + 1). \(step)")
                        }
                    }

                    Text(SpotPassCopy.explainerPosture)
                        .font(.footnote)
                        .foregroundStyle(SpotPassTheme.lavender)

                    nameToggle
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)

            Button(action: onCreate) {
                Text(SpotPassCopy.createButton)
            }
            .buttonStyle(SpotPassButtonStyle(kind: .primary, minHeight: SpotPassTheme.heroButtonHeight))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .spotPassBackdrop()
    }

    /// Toggle row, 64 pt, with the helper line for the current state (design §9.2 table).
    private var nameToggle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $showFirstName) {
                Text(SpotPassCopy.showFirstName)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .disabled(!toggleEnabled)
            .frame(minHeight: 64)
            .accessibilityHint(helper)

            Text(helper)
                .font(.footnote)
                .foregroundStyle(SpotPassTheme.lavender)
        }
    }

    private var helper: String {
        if !toggleEnabled { return SpotPassCopy.showFirstNameDisabled }
        return showFirstName ? SpotPassCopy.showFirstNameOn : SpotPassCopy.showFirstNameOff
    }
}

// MARK: - Creating / failed

struct SpotPassCreatingView: View {

    enum Mode: Equatable {
        case working
        case failed(SpotPassCreateFailure)
    }

    let mode: Mode
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            switch mode {
            case .working:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(SpotPassCopy.creating)
                    .font(.title3)
                    .foregroundStyle(.white)
            case .failed(let failure):
                Image(systemName: "wifi.slash")
                    .font(.largeTitle)
                    .foregroundStyle(SpotPassTheme.lavender)
                    .accessibilityHidden(true)
                Text(failure == .offline ? SpotPassCopy.offline : SpotPassCopy.createFailed)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                VStack(spacing: 12) {
                    Button(action: onRetry) { Text(SpotPassCopy.tryAgain) }
                        .buttonStyle(SpotPassButtonStyle(kind: .primary))
                    Button(action: onClose) { Text(SpotPassCopy.done) }
                        .buttonStyle(SpotPassButtonStyle(kind: .secondary))
                }
                .padding(.horizontal, 24)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .spotPassBackdrop()
        .accessibilityElement(children: .contain)
    }
}
