//
//  WPOnboardingV2.swift
//  WePark
//
//  Stoop Phase 6a (B1): the round-2 first-run screens. Presented by `ContentView` in place of
//  `OnboardingStoryView`, `LocationPrimingCard` and `OnboardingCoachOverlay` ONLY while
//  `AppConstants.designSystemV2Enabled` is true. Pure presentation: when and whether each one
//  shows, the one-shot gates, and the permission request all stay in `ContentView`, exactly as
//  before. Onboarding teaches only the base view: a two-state map (park / don't), an end time, and
//  how long you're staying. "Show all sign details" is never mentioned here.
//

import SwiftUI

// MARK: - Story deck (B1.1 to B1.3)

struct WPOnboardingStoryV2: View {

    /// Fired by the last card's primary button OR Skip from any card (same contract as
    /// `OnboardingStoryView.onFinish`: the caller decides what finishing means).
    let onFinish: () -> Void

    @State private var cardIndex: Int
    @State private var chipIndex = WPStoryExample.selectedChipIndex
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    init(onFinish: @escaping () -> Void, startIndex: Int = 0) {
        self.onFinish = onFinish
        _cardIndex = State(initialValue: min(max(startIndex, 0), OnboardingStoryCard.allCases.count - 1))
    }

    var body: some View {
        deck
            .sensoryFeedback(.selection, trigger: cardIndex)
            .background(WP.paper.ignoresSafeArea())
    }

    /// Reduce Motion swaps the page slide for a crossfade (same rule as the flag-off deck).
    @ViewBuilder
    private var deck: some View {
        if reduceMotion {
            ZStack {
                ForEach(OnboardingStoryCard.allCases, id: \.rawValue) { card in
                    page(card)
                        .opacity(card.rawValue == cardIndex ? 1 : 0)
                        .allowsHitTesting(card.rawValue == cardIndex)
                        .accessibilityHidden(card.rawValue != cardIndex)
                }
            }
            .animation(.easeInOut, value: cardIndex)
        } else {
            TabView(selection: $cardIndex) {
                ForEach(OnboardingStoryCard.allCases, id: \.rawValue) { card in
                    page(card).tag(card.rawValue)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    private func page(_ card: OnboardingStoryCard) -> some View {
        WPScreenScaffold(
            closeLabel: "Skip",
            onClose: { onFinish() },
            over: card.v2Progress,
            title: card.v2Title,
            sub: card.v2Sub,
            primary: (title: card.v2PrimaryLabel, kind: WPPrimaryKind.commitment, action: { advance(from: card) }),
            secondary: nil
        ) {
            content(for: card)
        }
    }

    private func advance(from card: OnboardingStoryCard) {
        if onboardingStoryIsFinalCard(card) {
            onFinish()
        } else if let next = onboardingStoryNextCard(after: card) {
            cardIndex = next.rawValue
        }
    }

    @ViewBuilder
    private func content(for card: OnboardingStoryCard) -> some View {
        switch card {
        case .problem: linesCard
        case .ask: endTimeCards
        case .payoff: goalCards
        }
    }

    // MARK: B1.1 the two lines

    private var linesCard: some View {
        WPListCard {
            lineRow(kind: .park, title: WPStoryLines.parkTitle, sub: WPStoryLines.parkSub)
            WPListDivider()
            lineRow(kind: .dont, title: WPStoryLines.dontTitle, sub: WPStoryLines.dontSub)
        }
    }

    private func lineRow(kind: CurbLineKind, title: String, sub: String) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s2))
            : AnyLayout(HStackLayout(spacing: WP.Space.s4))
        return layout {
            WPCurbSample(kind: kind)
                .frame(width: 80, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(WP.Font.fredoka(24, .bold, relativeTo: .title2))
                    .foregroundStyle(WP.text)
                Text(sub)
                    .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, WP.Space.s3)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(sub)")
    }

    // MARK: B1.2 every free has an end

    private var endTimeCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WPStoryExample.label.uppercased())
                .font(WP.Font.fredoka(12, .semibold, relativeTo: .caption))
                .kerning(0.8)
                .foregroundStyle(WP.muted)
            let shape = RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
            VStack(alignment: .leading, spacing: WP.Space.s1) {
                Text(WPStoryExample.factLead)
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                Text(WPStoryExample.factTime)
                    .font(WP.Font.fredoka(44, .bold, relativeTo: .largeTitle))
                    .fixedSize(horizontal: false, vertical: true)
                Text(WPStoryExample.factNext)
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Ink on the park fill in both modes (the fill does not change in dark).
            .foregroundStyle(WP.ink)
            .padding(WP.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(WP.park))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Example. \(WPStoryExample.factLead) \(WPStoryExample.factTime). \(WPStoryExample.factNext)")
            noteCard(title: WPStoryExample.remindTitle, body: WPStoryExample.remindBody)
        }
    }

    // MARK: B1.3 how long you're staying

    private var goalCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: WP.Space.s2))
                : AnyLayout(HStackLayout(spacing: WP.Space.s2))
            layout {
                ForEach(Array(WPStoryExample.goalChips.enumerated()), id: \.offset) { index, chip in
                    WPGoalTile(
                        title: chip.title,
                        subtitle: chip.sub,
                        isSelected: index == chipIndex
                    ) { chipIndex = index }
                }
            }
            .padding(.top, WP.Raise.md)
            noteCard(title: WPStoryExample.longerStayTitle, body: WPStoryExample.longerStayBody)
        }
    }

    private func noteCard(title: String, body: String) -> some View {
        WPListCard {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(body)
                    .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, WP.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Location priming (B1.4)

/// The round-2 location ask. Same two outcomes as `LocationPrimingCard`: "Allow location" lets the
/// caller fire the real system prompt; "Not now" and Skip are the zero-side-effect dismissal. The
/// caller owns the one-shot gate and the permission request.
struct WPLocationPrimingV2: View {
    let onAllow: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        WPScreenScaffold(
            closeLabel: WPLocationPrimingCopy.skip,
            onClose: onNotNow,
            title: WPLocationPrimingCopy.title,
            sub: WPLocationPrimingCopy.sub,
            primary: (title: WPLocationPrimingCopy.allow, kind: WPPrimaryKind.commitment, action: onAllow),
            secondary: (title: WPLocationPrimingCopy.notNow, action: onNotNow)
        ) {
            WPListCard {
                ForEach(Array(WPLocationPrimingCopy.facts.enumerated()), id: \.offset) { index, fact in
                    if index > 0 { WPListDivider() }
                    Text(fact)
                        .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                        .foregroundStyle(WP.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18)
                        .padding(.vertical, WP.Space.s3)
                        .frame(maxWidth: .infinity, minHeight: WPListMetrics.rowMinHeight, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Coach marks (B1.6 to B1.8)

/// The three anchored coach cards. Non-blocking: no scrim, the map stays interactive around the
/// card. Layout reuses the flag-off overlay's pure region math (`OnboardingCoachModel.swift`), so
/// the card is clamped to the safe area at every Dynamic Type size and never covers the dock.
struct WPCoachOverlayV2: View {

    let mark: OnboardingCoachMark
    /// The goal sheet's own frame (the card sits just above it). `.zero` = not measured.
    let goalDockFrame: CGRect
    /// The goal tile row's frame (mark 1's ring). `.zero` = not measured, no ring.
    let tileRowFrame: CGRect
    /// Marks 2 and 3: the projected anchor in WINDOW coordinates (the nearest curb for mark 2, the
    /// resting car token for mark 3), or nil when there is nothing on-screen to point at.
    let anchorScreenPoint: CGPoint?
    var topChromeBottom: CGFloat = 0
    var userDotScreenPoint: CGPoint? = nil
    var railFrame: CGRect = .zero
    /// True when the resting car token is actually drawn (`ContentView.v2ShowsRestingToken`).
    /// Mark 3's words and the room left for the token follow this, not only the type size.
    var tokenVisible: Bool = true
    let onNext: () -> Void
    let onSkip: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var accessibilityLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    @ScaledMetric(relativeTo: .headline) private var minimumRegionHeight: CGFloat = 140

    /// Room for the card when it sits under the resting token (card is about 154pt at the default size).
    private let restingCardHeight: CGFloat = 176
    private let margin: CGFloat = 18
    private let maxWidth: CGFloat = 420

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let insets = proxy.safeAreaInsets
            let safe = CGRect(
                x: insets.leading, y: insets.top,
                width: max(0, proxy.size.width - insets.leading - insets.trailing),
                height: max(0, proxy.size.height - insets.top - insets.bottom)
            )
            let origin = proxy.frame(in: .global).origin
            let anchor = anchorScreenPoint
                .map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
                .flatMap { onboardingCoachPointIsOnScreen($0, in: bounds) ? $0 : nil }
            ZStack(alignment: .topLeading) {
                ring(anchor: anchor)
                bubble(anchor: anchor, origin: origin, safe: safe)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sensoryFeedback(.selection, trigger: mark)
    }

    // MARK: Ring (4pt taxi, 2.5pt ink outline, no scrim)

    @ViewBuilder
    private func ring(anchor: CGPoint?) -> some View {
        switch mark {
        case .goalTiles:
            if tileRowFrame != .zero {
                ringShape(RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous))
                    .frame(width: tileRowFrame.width + 8, height: tileRowFrame.height + 8)
                    .position(x: tileRowFrame.midX, y: tileRowFrame.midY)
            }
        case .colorMeaning, .tapABlock:
            if let anchor {
                ringShape(Circle())
                    .frame(width: 64, height: 64)
                    .position(anchor)
            }
        }
    }

    private func ringShape<S: InsettableShape>(_ shape: S) -> some View {
        ZStack {
            shape.inset(by: -2).stroke(WP.taxi, lineWidth: 4)
            shape.inset(by: -5.25).stroke(WP.ink, lineWidth: WP.Border.control)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Placement

    @ViewBuilder
    private func bubble(anchor: CGPoint?, origin: CGPoint, safe: CGRect) -> some View {
        let top = onboardingCoachSkipTop(
            safeMinY: safe.minY, topChromeBottom: topChromeBottom, accessibilityLayout: accessibilityLayout
        )
        let dockTop = bottomLimit(above: goalDockFrame, safe: safe)
        // The resting car token (and its "Drag to a curb to park" hint) sits at 28% of the screen
        // height. Cards that do not point at it stay below it; the token is hidden at AX sizes.
        let belowToken = (accessibilityLayout || !tokenVisible) ? top : max(top, UIScreen.main.bounds.height * 0.28 + 26 - origin.y)
        switch mark {
        case .goalTiles:
            if accessibilityLayout {
                region(anchorX: nil, safe: safe, top: top, bottom: markOneBottom(top: top, dockBottom: dockTop, origin: origin, safe: safe), alignment: .bottom)
            } else {
                // Between the car token and the search row: top-aligned under the token.
                region(anchorX: nil, safe: safe, top: belowToken, bottom: belowToken + restingCardHeight, alignment: .top)
            }
        case .colorMeaning, .tapABlock:
            if let anchor {
                let gap: CGFloat = 36
                if onboardingCoachBubbleFitsAbove(anchorY: anchor.y, topLimit: top, gap: gap, minimumHeight: 160) {
                    region(anchorX: anchor.x, safe: safe, top: top, bottom: anchor.y - gap, alignment: .bottom)
                } else {
                    region(anchorX: anchor.x, safe: safe, top: anchor.y + gap, bottom: accessibilityLayout ? dockTop : anchor.y + gap + restingCardHeight, alignment: .top)
                }
            } else {
                // Nothing on-screen to point at: sit just above the goal sheet, like mark 1.
                if accessibilityLayout {
                    region(anchorX: nil, safe: safe, top: top, bottom: dockTop, alignment: .bottom)
                } else {
                    region(anchorX: nil, safe: safe, top: belowToken, bottom: belowToken + restingCardHeight, alignment: .top)
                }
            }
        }
    }

    private func markOneBottom(top: CGFloat, dockBottom: CGFloat, origin: CGPoint, safe: CGRect) -> CGFloat {
        guard !accessibilityLayout, let global = userDotScreenPoint else { return dockBottom }
        let width = cardWidth(safeWidth: safe.width)
        let centerX = onboardingCoachBubbleCenterX(
            anchorX: nil, bubbleWidth: width, safeMinX: safe.minX, safeMaxX: safe.maxX
        )
        return onboardingCoachBottomAvoidingUserDot(
            bottom: dockBottom, top: top,
            dot: CGPoint(x: global.x - origin.x, y: global.y - origin.y),
            bubbleMinX: centerX - width / 2, bubbleMaxX: centerX + width / 2,
            minimumHeight: minimumRegionHeight
        )
    }

    private func bottomLimit(above frame: CGRect, safe: CGRect) -> CGFloat {
        guard frame != .zero else { return safe.maxY - 12 }
        // The search / More / Locate row (48 tall) floats just above the goal sheet and is not
        // part of its frame, so clear it too. At accessibility sizes the sheet has no such row.
        let toolbarClearance: CGFloat = accessibilityLayout ? 0 : 54
        return min(safe.maxY - 12, frame.minY - 14 - toolbarClearance)
    }

    private func cardWidth(safeWidth: CGFloat) -> CGFloat {
        max(0, min(maxWidth, safeWidth - 2 * margin))
    }

    private func region(anchorX: CGFloat?, safe: CGRect, top: CGFloat, bottom: CGFloat, alignment: Alignment) -> some View {
        let vertical = onboardingCoachBubbleVerticalBounds(
            top: top, bottom: bottom, safeMaxY: safe.maxY,
            minimumHeight: minimumRegionHeight, accessibilityLayout: accessibilityLayout
        )
        let height = max(1, vertical.bottom - vertical.top)
        let safeMaxX = accessibilityLayout
            ? onboardingCoachRailAdjustedSafeMaxX(
                safeMaxX: safe.maxX, railFrame: railFrame, regionTop: vertical.top, regionBottom: vertical.bottom
            )
            : safe.maxX
        let width = cardWidth(safeWidth: safeMaxX - safe.minX)
        // The card is centred on the screen; the pointer ring (not the card) carries the anchor.
        let x = onboardingCoachBubbleCenterX(
            anchorX: anchorX, bubbleWidth: width, safeMinX: safe.minX, safeMaxX: safeMaxX
        )
        return card
            .frame(width: width, height: height, alignment: alignment)
            .position(x: x, y: vertical.top + height / 2)
    }

    /// The card scrolls only when the text does not fit (AX sizes), so Skip and Next stay reachable.
    private var card: some View {
        let content = WPCoachCard(
            step: mark.rawValue + 1,
            total: OnboardingCoachMark.allCases.count,
            title: mark.v2Title(accessibilityLayout: accessibilityLayout, tokenVisible: tokenVisible),
            message: mark.v2Message(accessibilityLayout: accessibilityLayout, tokenVisible: tokenVisible),
            nextTitle: mark.v2NextLabel,
            onSkip: onSkip,
            onNext: onNext
        )
        return ViewThatFits(in: .vertical) {
            content
            ScrollView { content }.scrollBounceBehavior(.basedOnSize)
        }
    }
}
