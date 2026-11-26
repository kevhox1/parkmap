//
//  WPStateScreens.swift
//  Views
//
//  Stoop Phase 6b (round-2 B18): the blocking and empty states, as plain views over
//  `WPStateCopy`. Shown only while `AppConstants.designSystemV2Enabled`.
//
//    - `WPBlockingStateScreen`: B18.1 location, B18.5 server, B18.7 outside coverage, B18.8 account,
//      B18.9 no parked car. The round-2 full-screen scaffold: title, one sentence, one primary
//      action, one quiet way out.
//    - `WPNoCurbsCard`: B18.6, the bottom card over an empty map ("We couldn't load the curbs here").
//
//  The limit rows (offline, "While Using" only, notifications off: B18.2 to B18.4) are the existing
//  `WPLimitRow` over `WPStateCopy.Limit`; the offline banner on the map is `WPOfflineBanner`.
//
//  Rule: an empty or failed map never reads as "free". The no-curbs card says nothing is drawn.
//

import SwiftUI

// MARK: - Blocking state

struct WPBlockingStateScreen: View {
    let copy: WPStateCopy.Screen
    var showsCarToken = false
    let onPrimary: (() -> Void)?
    let onSecondary: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        WPScreenScaffold(
            onClose: onClose,
            over: copy.over,
            title: copy.title,
            sub: copy.sub,
            primary: primary,
            secondary: secondary
        ) {
            if showsCarToken {
                HStack(spacing: WP.Space.s3) {
                    WPHollowToken()
                    Text(WPStateCopy.noCarToken)
                        .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                        .foregroundStyle(WP.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .padding(.top, WP.Space.s2)
            }
        }
    }

    private var primary: (title: String, kind: WPPrimaryKind, action: () -> Void)? {
        guard let title = copy.primary, let onPrimary else { return nil }
        return (title: title, kind: .navigation, action: onPrimary)
    }

    private var secondary: (title: String, action: () -> Void)? {
        guard let title = copy.secondary, let onSecondary else { return nil }
        return (title: title, action: onSecondary)
    }
}

// MARK: - No curbs card

struct WPNoCurbsCard: View {
    let onTryAgain: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.sheet, style: .continuous)
        VStack(alignment: .leading, spacing: WP.Space.s2) {
            Text(WPStateCopy.noCurbsTitle)
                .font(WP.Font.fredoka(22, .semibold, relativeTo: .title2))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(WPStateCopy.noCurbsBody)
                .font(WP.Font.fredoka(16, .regular, relativeTo: .body))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
            Button(WPStateCopy.tryAgain, action: onTryAgain)
                .buttonStyle(InkPillButtonStyle(labelColor: .white))
                .padding(.top, WP.Space.s2)
        }
        .padding(WP.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(WP.card))
        .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
        .accessibilityElement(children: .contain)
    }
}
