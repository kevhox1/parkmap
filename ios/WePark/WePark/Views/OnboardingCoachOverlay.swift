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
//  Mark 3's anchor is a bearing-based approximation, not an exact MapKit screen projection —
//  see `Models/OnboardingCoachModel.swift`'s `onboardingCoachBearingOffset(...)` doc comment
//  for the full, flagged reasoning (this PR's dispatch holds `MapViewRepresentable` untouched).
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

    /// Mark 3's already-resolved anchor offset (points, from this view's own center) toward the
    /// nearest real curb segment, or `.zero` to anchor exactly at center — the design doc's own
    /// named fallback for "no segment is within range."
    let nearestCurbOffset: CGSize

    /// Fired by the bubble's own "Got it"/"Done" button.
    let onPrimaryAction: () -> Void

    /// Fired by the persistent Skip link, same screen position on every mark.
    let onSkipAll: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseOn = false

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .top) {
                ringOverlay(in: bounds)
                bubbleLayer(in: bounds)
                skipLink
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
    private func ringOverlay(in bounds: CGRect) -> some View {
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
            pulsingCircle(center: curbAnchorPoint(in: bounds))
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

    /// Mark 3's ring is a plain pulsing circle at the approximate anchor point — NOT traced
    /// along the real polyline (flagged deviation, see this file's header + the model's own
    /// doc comment on `onboardingCoachBearingOffset`).
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

    private func curbAnchorPoint(in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.midX + nearestCurbOffset.width, y: bounds.midY + nearestCurbOffset.height)
    }

    // MARK: - Bubble (§2.2/§2.3)

    @ViewBuilder
    private func bubbleLayer(in bounds: CGRect) -> some View {
        switch mark {
        case .goalTiles:
            bottomAnchoredBubble(clearance: clearance(above: goalDockFrame, in: bounds))
        case .colorMeaning:
            bottomAnchoredBubble(clearance: clearance(above: selectedTileFrame, in: bounds))
        case .tapABlock:
            centerAnchoredBubble(at: curbAnchorPoint(in: bounds), in: bounds)
        }
    }

    /// The vertical space between `bounds`'s bottom edge and the TOP of `frame` — pinning a
    /// bubble just above `frame` is then a plain `Spacer()` + a fixed-height clear reservation,
    /// not a hand-computed offset. `.zero` (not yet measured) reserves zero clearance so the
    /// bubble still renders (near the very bottom) rather than vanishing.
    private func clearance(above frame: CGRect, in bounds: CGRect) -> CGFloat {
        guard frame != .zero else { return 0 }
        return max(0, bounds.maxY - frame.minY)
    }

    private func bottomAnchoredBubble(clearance: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            bubbleCard
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            Color.clear.frame(height: clearance)
        }
    }

    private func centerAnchoredBubble(at point: CGPoint, in bounds: CGRect) -> some View {
        bubbleCard
            .padding(.horizontal, 20)
            .frame(maxWidth: bounds.width)
            .position(x: point.x, y: max(bounds.minY + 90, point.y - 70))
    }

    /// `.regularMaterial` callout — same card family `LocationPrimingCard`/
    /// `SpotPlacementConfirmCard` already use, not a new chrome idiom.
    private var bubbleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mark.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = mark.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .frame(maxWidth: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mark.subtitle.map { "\(mark.title). \($0)" } ?? mark.title)
    }

    // MARK: - Persistent Skip link (§2.3: same screen position on every mark)

    private var skipLink: some View {
        VStack {
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
            .padding(.top, 60)
            Spacer(minLength: 0)
        }
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
            nearestCurbOffset: .zero,
            onPrimaryAction: {},
            onSkipAll: {}
        )
    }
}
