//
//  OnboardingCoachOverlay.swift
//  WePark
//
//  First-run onboarding (open item #41, `docs/design/first-run-onboarding-design.md` §2) — the
//  3 anchored, non-blocking coach bubbles shown over the real ambient map after the story deck
//  (or immediately, for upgrading users, §4.2). §0.1 of the drive-mode spec is explicit: never
//  block the map. This is NOT a dimmed, modal, tap-to-advance overlay — the map stays fully
//  interactive underneath and around every bubble at all times. Nothing here intercepts a tap
//  that isn't the bubble's own button / the persistent Skip link.
//
//  Pure presentation, same "caller owns the gate/state, this view is pure presentation"
//  contract `LocationPrimingCard`/`GoalSelectorView` already commit to: `ContentView` decides
//  WHICH mark is current, resolves every frame this view anchors against, and owns every
//  action (advance / finish / skip, and whether that write the one-shot gate). This view never
//  reads `AppConstants` and owns no persistent state of its own — only the transient pulse
//  animation phase.
//
//  Anchoring: `goalDockFrame`/`tileRowFrame`/`selectedTileFrame` arrive already resolved, in
//  the shared `onboardingCoachCoordinateSpaceName` coordinate space (measured by
//  `GoalSelectorView`'s own geometry callbacks + a matching `.onGeometryChange` at this view's
//  `ContentView` call site) — this view never hand-computes a sibling's height, it reads the
//  real rendered frame and lets `VStack`/`Spacer` flow do the rest (design doc §6: "do not
//  hand-compute screen offsets against sibling views... anchor preferences make the bubbles
//  track the real layout for free"). **Flagged deviation from the design doc's literal text:**
//  the mechanism here is `.onGeometryChange` + a named coordinate space, not literal
//  `anchorPreference`/`overlayPreferenceValue` — see `Views/GoalSelectorView.swift`'s own doc
//  comment on the two new frame callbacks, and this PR's description, for why: this exact
//  codebase already root-caused and removed a custom multi-sibling `PreferenceKey` (a `reduce`-
//  ordering bug, `BrowseNavigationSheet.swift`'s own doc comment) in favor of
//  `.onGeometryChange`, so this PR follows that same, already-proven-safe mechanism rather than
//  reintroducing the literal API family this codebase has direct, documented scar tissue with.
//  The requirement the design doc actually cares about — "track the real layout for free,
//  including at different Dynamic Type sizes" — holds identically either way.
//
//  Mark 3's anchor is a real ground->screen projection (QA follow-up to PR #149):
//  `ContentView` resolves the nearest curb's coordinate through
//  `MapViewRepresentable.CoordinatorActions.screenPointForCoordinate` (`MKMapView.convert`) and
//  hands this view a point in WINDOW (global) coordinates, or nil when no curb is on-screen
//  (then the bubble is placed with no ring - never pointing at empty space).
//
//  Layout (QA #3/#4): every bubble is clamped to the SAFE AREA at every Dynamic Type size -
//  width capped (`onboardingCoachBubbleWidth`), horizontal center clamped
//  (`onboardingCoachBubbleCenterX`), and the headline/body scroll inside a bounded region so
//  "Got it"/"Done" and Skip always stay visible and tappable.
//

import SwiftUI

struct OnboardingCoachOverlay: View {

    /// The currently-displayed mark. The caller is responsible for not mounting this view at
    /// all when there is nothing to show (`ContentView`'s `onboardingCoachMark: OnboardingCoachMark?`
    /// being `nil`) — this view always renders exactly one mark.
    let mark: OnboardingCoachMark

    /// `GoalSelectorView`'s own overall frame (mark 1's "directly above the Start Driving bar"
    /// clearance). `.zero` means "not yet measured" — the bubble falls back to the bottom of
    /// this view's own bounds rather than overlapping anything.
    let goalDockFrame: CGRect

    /// The goal-tile row's own frame (mark 1's pulsing ring target).
    let tileRowFrame: CGRect

    /// The currently-selected goal tile's own frame (mark 2's bubble clearance + ring target).
    let selectedTileFrame: CGRect

    /// Mark 3's anchor: the nearest real curb's projected position in WINDOW (global)
    /// coordinates, or `nil` when no curb is on-screen (bubble placed without a ring).
    let nearestCurbScreenPoint: CGPoint?

    /// QA #3/#4 (PR #152): the measured bottom edge of the top chrome (ASP banner) and the
    /// trailing rail's frame (Recenter, More), same coordinate space as the dock frames. Only
    /// consulted at accessibility sizes (below AX1 nothing changes). `0`/`.zero` = not measured.
    var topChromeBottom: CGFloat = 0
    var railFrame: CGRect = .zero

    /// Fired by the bubble's own "Got it"/"Done" button.
    let onPrimaryAction: () -> Void

    /// Fired by the persistent Skip link, same screen position on every mark.
    let onSkipAll: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// #37 6: this overlay is NOT inside the dock's type cap, so this is the real size. At
    /// accessibility sizes the dock shows one goal card (`tileRowFrame == selectedTileFrame ==`
    /// the card), so mark 1 uses the card copy and mark 2's bubble clears the whole dock, not
    /// just the card (Start Driving sits between them).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var goalCardLayout: Bool { dynamicTypeSize.isAccessibilitySize }
    @State private var pulseOn = false

    /// Vertical band reserved at the top for the persistent Skip pill (pill + padding). The
    /// pill's footnote label grows with Dynamic Type, so part of the band scales with it
    /// (60pt at standard size, ~86pt at AX5) - otherwise the bubble would overlap the pill.
    @ScaledMetric(relativeTo: .footnote) private var skipBandScaledPart: CGFloat = 14
    private var skipBandHeight: CGFloat { 46 + skipBandScaledPart }

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let insets = proxy.safeAreaInsets
            // The usable rect: `bounds` minus whatever safe-area insets apply to this view
            // (zero on any side where this view already sits inside the safe area).
            let safe = CGRect(
                x: insets.leading,
                y: insets.top,
                width: max(0, proxy.size.width - insets.leading - insets.trailing),
                height: max(0, proxy.size.height - insets.top - insets.bottom)
            )
            let globalOrigin = proxy.frame(in: .global).origin
            let curbPoint = nearestCurbScreenPoint.map {
                CGPoint(x: $0.x - globalOrigin.x, y: $0.y - globalOrigin.y)
            }
            ZStack(alignment: .topLeading) {
                ringOverlay(curbPoint: curbPoint, in: bounds)
                bubbleLayer(curbPoint: curbPoint, bounds: bounds, safe: safe)
                skipLink(safe: safe)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // §2.3: one light selection haptic per bubble's first appearance (max 3 ever).
        .sensoryFeedback(.selection, trigger: mark)
        .onAppear { pulseOn = true }
    }

    // MARK: - Pulsing ring (§2.2)

    @ViewBuilder
    private func ringOverlay(curbPoint: CGPoint?, in bounds: CGRect) -> some View {
        switch mark {
        case .goalTiles:
            if tileRowFrame != .zero {
                pulsingRing(frame: tileRowFrame, cornerRadius: 20)
            }
        case .colorMeaning:
            if selectedTileFrame != .zero {
                pulsingRing(frame: selectedTileFrame, cornerRadius: 20)
            }
        case .tapABlock:
            // No ring unless a real curb projected on-screen: never point at empty space.
            if let curbPoint, onboardingCoachPointIsOnScreen(curbPoint, in: bounds) {
                pulsingCircle(center: curbPoint)
            }
        }
    }

    /// A pulsing outline ring traced on `frame` — disabled under Reduce Motion in favor of a
    /// static ring (§2.2). Never intercepts touches (`allowsHitTesting(false)`): it is a visual
    /// trace only, the real control underneath stays fully tappable.
    private func pulsingRing(frame: CGRect, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(Color.white, lineWidth: 3)
            .frame(width: frame.width + 8, height: frame.height + 8)
            .position(x: frame.midX, y: frame.midY)
            .opacity(reduceMotion ? 0.9 : (pulseOn ? 1.0 : 0.45))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: pulseOn
            )
            .allowsHitTesting(false)
    }

    /// Mark 3's ring: a plain pulsing circle on the projected nearest-curb point.
    private func pulsingCircle(center: CGPoint) -> some View {
        Circle()
            .stroke(Color.white, lineWidth: 3)
            .frame(width: 56, height: 56)
            .position(center)
            .opacity(reduceMotion ? 0.9 : (pulseOn ? 1.0 : 0.45))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: pulseOn
            )
            .allowsHitTesting(false)
    }

    // MARK: - Bubble (§2.2/§2.3)

    /// Every bubble is laid out inside a bounded REGION (inside the safe area, below the Skip
    /// band, above whatever it must clear) and aligned to one edge of it; the card itself
    /// scrolls its text if the region is too short (AX sizes), so it can never leave the screen.
    @ViewBuilder
    private func bubbleLayer(curbPoint: CGPoint?, bounds: CGRect, safe: CGRect) -> some View {
        let topLimit = onboardingCoachRegionTop(
            safeMinY: safe.minY, skipTop: skipTop(safe: safe), skipBandHeight: skipBandHeight
        )
        switch mark {
        case .goalTiles:
            bubbleRegion(
                anchorX: nil, safe: safe, top: topLimit,
                bottom: bottomLimit(above: goalDockFrame, safe: safe), alignment: .bottom
            )
        case .colorMeaning:
            bubbleRegion(
                anchorX: nil, safe: safe, top: topLimit,
                bottom: bottomLimit(above: goalCardLayout ? goalDockFrame : selectedTileFrame, safe: safe),
                alignment: .bottom
            )
        case .tapABlock:
            let anchor = curbPoint.flatMap { onboardingCoachPointIsOnScreen($0, in: bounds) ? $0 : nil }
            let dockTop = bottomLimit(above: goalDockFrame, safe: safe)
            if let anchor {
                // Keep clear of the 56pt ring (28pt radius) plus a gap.
                let gap: CGFloat = 40
                if onboardingCoachBubbleFitsAbove(anchorY: anchor.y, topLimit: topLimit, gap: gap, minimumHeight: 140) {
                    bubbleRegion(anchorX: anchor.x, safe: safe, top: topLimit, bottom: anchor.y - gap, alignment: .bottom)
                } else {
                    bubbleRegion(anchorX: anchor.x, safe: safe, top: anchor.y + gap, bottom: dockTop, alignment: .top)
                }
            } else {
                // No on-screen curb: place the bubble in the upper-middle, no ring.
                bubbleRegion(
                    anchorX: nil, safe: safe, top: topLimit,
                    bottom: max(topLimit + 140, safe.midY), alignment: .bottom
                )
            }
        }
    }

    /// The bottom edge of the region above `frame` (12pt gap), or the safe-area bottom when the
    /// frame is not measured yet.
    private func bottomLimit(above frame: CGRect, safe: CGRect) -> CGFloat {
        guard frame != .zero else { return safe.maxY - 12 }
        return min(safe.maxY - 12, frame.minY - 12)
    }

    /// Minimum region height before the bubble is allowed to overlap whatever it would otherwise
    /// clear. At accessibility Dynamic Type sizes the dock fills most of the screen, leaving no
    /// room above it - the bubble then overlaps the top of the dock (still fully on-screen and
    /// tappable) instead of collapsing to nothing and clipping.
    @ScaledMetric(relativeTo: .headline) private var minimumBubbleRegionHeight: CGFloat = 170

    private func bubbleRegion(
        anchorX: CGFloat?, safe: CGRect, top: CGFloat, bottom: CGFloat, alignment: Alignment
    ) -> some View {
        let bounds = onboardingCoachBubbleVerticalBounds(
            top: top, bottom: bottom, safeMaxY: safe.maxY,
            minimumHeight: minimumBubbleRegionHeight, accessibilityLayout: goalCardLayout
        )
        let height = max(1, bounds.bottom - bounds.top)
        // QA #4: keep clear of the trailing rail (Recenter, More) at AX sizes only.
        let safeMaxX = goalCardLayout
            ? onboardingCoachRailAdjustedSafeMaxX(
                safeMaxX: safe.maxX, railFrame: railFrame, regionTop: bounds.top, regionBottom: bounds.bottom
            )
            : safe.maxX
        let width = onboardingCoachBubbleWidth(safeWidth: safeMaxX - safe.minX)
        let x = onboardingCoachBubbleCenterX(
            anchorX: anchorX, bubbleWidth: width, safeMinX: safe.minX, safeMaxX: safeMaxX
        )
        return bubbleCard(width: width)
            .frame(width: width, height: height, alignment: alignment)
            .position(x: x, y: bounds.top + height / 2)
    }

    /// `.regularMaterial` callout — same card family `LocationPrimingCard`/
    /// `SpotPlacementConfirmCard` already use, not a new chrome idiom. The text block scrolls
    /// (only when it does not fit); the primary button stays pinned below it.
    private func bubbleCard(width: CGFloat) -> some View {
        let text = VStack(alignment: .leading, spacing: 10) {
            Text(mark.title(accessibilityLayout: goalCardLayout))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = mark.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .vertical) {
                text
                ScrollView { text }
            }
            Button(action: onPrimaryAction) {
                Text(mark.primaryActionLabel)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Persistent Skip link (§2.3: same screen position on every mark)

    /// Skip's top edge: legacy `safe.minY + 8`; at AX sizes below the measured top chrome (ASP banner).
    private func skipTop(safe: CGRect) -> CGFloat {
        onboardingCoachSkipTop(
            safeMinY: safe.minY, topChromeBottom: topChromeBottom, accessibilityLayout: goalCardLayout
        )
    }

    private func skipLink(safe: CGRect) -> some View {
        HStack {
            Spacer()
            Button(action: onSkipAll) {
                Text("Skip")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Skip")
            .accessibilityHint("Skips the tour and leaves the live map exactly as it is.")
            Spacer()
        }
        .frame(width: safe.width)
        .offset(x: safe.minX, y: skipTop(safe: safe))
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        OnboardingCoachOverlay(
            mark: .goalTiles,
            goalDockFrame: CGRect(x: 16, y: 560, width: 361, height: 220),
            tileRowFrame: CGRect(x: 16, y: 640, width: 361, height: 128),
            selectedTileFrame: CGRect(x: 16, y: 640, width: 115, height: 128),
            nearestCurbScreenPoint: nil,
            onPrimaryAction: {},
            onSkipAll: {}
        )
    }
}
