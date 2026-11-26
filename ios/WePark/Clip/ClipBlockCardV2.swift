//
//  ClipBlockCardV2.swift
//  WePark Clip
//
//  Stoop Phase 5b: the clip's existing on-demand "This block" lookup (earned reveal, location used
//  once) restyled with Stoop tokens. Same `ClipBlockController`, same states and formatting as
//  `ClipBlockCard`; only the look changes. Mounted from `WPClipArmedFlow` behind the flag.
//  (Round-2 B11.6 "block rules inside the clip" itself needs backend work and is not part of this.)
//

import SwiftUI

struct WPClipBlockCard: View {
    let block: ClipBlockController

    var body: some View {
        WPClipCard {
            switch block.state {
            case .idle:
                teaser
            case .locating, .loading:
                HStack(spacing: 10) {
                    ProgressView().tint(WP.ink)
                    Text(ClipCopy.blockTitle).font(WP.Font.fredoka(17, .semibold, relativeTo: .headline)).foregroundStyle(WP.text)
                }
                .frame(minHeight: 64)
                .accessibilityLabel("Looking up this block")
            case .result(let result, let index):
                resultCard(result, index: index)
            case .noRule:
                note(ClipCopy.blockNoRule)
            case .denied:
                note(ClipCopy.blockDenied)
            case .failed:
                note(ClipCopy.blockFailed)
                WPClipTextButton(title: ClipCopy.tryAgain) { Task { await block.show() } }
            }
        }
        .animation(.easeOut(duration: 0.3), value: block.state)
    }

    private var teaser: some View {
        VStack(alignment: .leading, spacing: 8) {
            WPClipCardText(title: ClipCopy.blockTeaserTitle, detail: ClipCopy.blockTeaserSub)
            Button { Task { await block.show() } } label: {
                Text(ClipCopy.blockShowMe)
                    .font(WP.Font.fredoka(18, .semibold, relativeTo: .headline))
                    .foregroundStyle(WP.text)
                    .frame(maxWidth: .infinity, minHeight: WP.Target.standard)
                    .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.control))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show me this block")
            .accessibilityHint("Uses your location once to look up street cleaning.")
            Text(ClipCopy.blockFootnote)
                .font(WP.Font.fredoka(14, .regular, relativeTo: .footnote)).foregroundStyle(WP.muted)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(WP.Font.fredoka(16, .regular, relativeTo: .body)).foregroundStyle(WP.text)
    }

    private func resultCard(_ result: ClipBlockResult, index: Int) -> some View {
        let side = result.sides[min(index, result.sides.count - 1)]
        let now = Date()
        return VStack(alignment: .leading, spacing: 8) {
            Text(ClipCopy.blockTitle).font(WP.Font.fredoka(22, .bold, relativeTo: .title2)).foregroundStyle(WP.text)
            if let window = side.window {
                if window.isInEffect(at: now) {
                    Text(ClipCopy.blockHappeningNow)
                        .font(WP.Font.fredoka(16, .semibold, relativeTo: .body)).foregroundStyle(WP.noParkText)
                }
                Text(ClipCopy.blockSideLine).font(WP.Font.fredoka(15, .regular, relativeTo: .callout)).foregroundStyle(WP.muted)
                Text(ClipBlockFormat.windowLine(window)).font(WP.Font.fredoka(22, .bold, relativeTo: .title2)).foregroundStyle(WP.text)
                Text(ClipBlockFormat.nextLine(window)).font(WP.Font.fredoka(16, .regular, relativeTo: .body)).foregroundStyle(WP.text)
            } else {
                note(ClipCopy.blockNoRule)
            }
            Text(ClipCopy.blockNearestCurb).font(WP.Font.fredoka(14, .regular, relativeTo: .footnote)).foregroundStyle(WP.muted)
            if result.sides.count > 1 {
                WPClipTextButton(title: ClipCopy.blockWrongSide) { block.switchSide() }
            }
            Divider().overlay(WP.divider)
            Text(ClipCopy.blockCheckSigns).font(WP.Font.fredoka(14, .semibold, relativeTo: .footnote)).foregroundStyle(WP.text)
            Text(ClipCopy.blockForwardLink).font(WP.Font.fredoka(14, .regular, relativeTo: .footnote)).foregroundStyle(WP.muted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ClipBlockFormat.accessibilitySummary(side.window, now: now))
    }
}
