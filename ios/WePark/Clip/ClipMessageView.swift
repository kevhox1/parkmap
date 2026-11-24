//
//  ClipMessageView.swift
//  WePark Clip
//
//  The calm terminal / error screens (design 3.8, 5.1c). Neutral gray plus an SF Symbol, never red.
//  No jargon: "isn't active anymore", never "invalid token".
//

import SwiftUI

struct ClipMessageView: View {
    let content: ClipMessageContent
    var onRetry: () -> Void
    var onWhatsWePark: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack { ClipWordmark(); Spacer() }.frame(minHeight: 44)
                Spacer(minLength: 40)
                Image(systemName: content.symbol)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(Color.gray.opacity(0.45), in: Circle())
                    .accessibilityHidden(true)
                Text(content.title)
                    .font(.title.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if !content.body.isEmpty {
                    Text(content.body).font(.body).foregroundStyle(SpotPassTheme.lavender).multilineTextAlignment(.center)
                }
                if content.retry {
                    Button(ClipCopy.tryAgain, action: onRetry).buttonStyle(ClipHeroButtonStyle(minHeight: SpotPassTheme.buttonHeight))
                }
                if content.showsWhatsWePark {
                    SpotPassTextButton(title: ClipCopy.whatsWePark, minHeight: 56, action: onWhatsWePark)
                }
            }
            .padding(.horizontal, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
