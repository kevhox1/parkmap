//
//  ConfirmPromptCard.swift
//  WePark
//
//  Community 2.0 Phase 4b — WP5 rider (build 20, S12).
//  Spec: docs/community-2.0-reconciliation-spec.md §3 Phase 4 +
//  docs/community-2.0-roadmap.md S12 row's WP5 rider +
//  docs/design/community-2.0-hero-gap-inventory.md row 13 (screenshot 13).
//
//  The proactive, in-app "did it pass?" confirm-prompt card — appears while the app is
//  FOREGROUND and a realtime-delivered `sweeper_passed` pin matches the parked car's segment
//  (`CommunityPushRelevance.firstUnseenSweeperPassedMatch`, `Services/PushRegistrationService.swift`
//  — the SAME pure predicate the background silent-push path uses, per the roadmap's own
//  framing that this card and the push notification share one relevance-gate).
//
//  Copy is VERBATIM from `design/prototype.html:104-113` (the task's own explicit
//  instruction) — do not paraphrase:
//    "🧹 Sweeper reported on your block"
//    "You're parked here. Did it pass? Your confirm tells N neighbors it's clear."
//    "Confirm — it passed"
//    "Didn't see it"
//  `N` is `pin.confirmCount` (a live number), replacing the mockup's static "148".
//
//  Presentation: a floating overlay card mounted directly in `ContentView.mapZStack`
//  (`spotPlacementConfirmOverlay`/`parkingGuideBannerOverlay`'s established "VStack + Spacer()
//  pinning content to one edge, inside the outer ZStack(alignment: .top)" pattern) — NOT a
//  modal `.sheet(item:)` through the `ActiveSheet` enum. This is the gap inventory's own
//  framing ("new overlay component, same LAYER as ArrivalPromptSheet's presentation pattern,
//  a reasonable structural precedent to reuse even though it's a different feature") — the
//  precedent being reused is "one state-machine-driven presentation slot, no stacked
//  `.sheet`s," not literally ArrivalPromptSheet's own modal-sheet mechanism. A proactive,
//  dismissible informational card the user might be mid-task around (browsing the map, mid
//  block-select, etc.) is closer to the existing `SpotPlacementConfirmCard`/
//  `ParkingGuidePromptBanner` floating-card family than to a blocking modal sheet — judgment
//  call, flagged in the PR description rather than silently decided.
//
//  No Calendar.current. No SwiftUI-avoidance tricks — plain SwiftUI view, self-contained
//  @State only for the in-flight submit guard (mirrors PinDetailSheet.ReactionsRow's own
//  isLoading pattern).
//

import SwiftUI

struct ConfirmPromptCard: View {

    // MARK: - Inputs

    /// The matching `sweeper_passed` pin this card is confirming/dismissing.
    let pin: CommunityPin

    /// Called when the user taps "Confirm — it passed". The caller (`ContentView`) performs
    /// the actual `upsertVote(.confirm)` + `callExtendPinExpiry` write (mirrors
    /// `PinDetailSheet.ReactionsRow.handleStillHere`'s existing call pair exactly — this view
    /// never talks to `CommunityPinService` directly, matching this codebase's "views don't
    /// own network calls" convention for injected-service consumers).
    let onConfirm: () -> Void

    /// Called when the user taps "Didn't see it" — dismiss only, no vote. Per spec: never
    /// re-prompts for the same `pin.id` afterward (the caller marks it seen in the shared
    /// dedupe store BEFORE this card is even shown — see `ContentView.updateConfirmPromptCandidate`).
    let onDismiss: () -> Void

    // MARK: - State

    /// Disables both buttons after the first tap so a double-tap during the async confirm
    /// write can't fire `onConfirm` twice. `ConfirmPromptCard` does not manage the pin's
    /// lifetime itself — the caller clears its own `confirmPromptPin` state once the async
    /// work (success OR failure) completes, at which point this view is torn down entirely.
    @State private var isSubmitting = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("🧹 Sweeper reported on your block")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)

            Text("You're parked here. Did it pass? Your confirm tells \(pin.confirmCount) neighbors it's clear.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    guard !isSubmitting else { return }
                    isSubmitting = true
                    onConfirm()
                } label: {
                    Text("Confirm — it passed")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.confirmGreen)
                .disabled(isSubmitting)
                .accessibilityLabel("Confirm the sweeper passed your block")
                .accessibilityHint("Tells neighbors the block is clear and extends this report's visibility.")

                Button {
                    guard !isSubmitting else { return }
                    onDismiss()
                } label: {
                    Text("Didn't see it")
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(isSubmitting)
                .accessibilityLabel("Didn't see it — dismiss without confirming")
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(Self.cardBackground, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Self.confirmGreen.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Colors

    /// `#30D158` — matches `design/prototype.html`'s confirm-card border/button color and
    /// `docs/community-2.0-reconciliation-spec.md` §6 appendix's `sweeper_passed` color.
    private static let confirmGreen = Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0)

    /// `rgba(28,32,30,0.98)` — matches the prototype's confirm-card background.
    private static let cardBackground = Color(red: 28 / 255.0, green: 32 / 255.0, blue: 30 / 255.0).opacity(0.98)
}
