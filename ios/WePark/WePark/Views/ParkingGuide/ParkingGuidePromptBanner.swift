//
//  ParkingGuidePromptBanner.swift
//  WePark
//
//  FT-12 §7 / OQ-2: the one-shot, non-blocking first-launch banner CTA for the
//  Parking 101 guide. Rendered from ContentView's `.safeAreaInset(edge: .bottom)`
//  chain (same slot family as the W7.5 Park-Until pill / W8.5c Drive Mode bottom
//  card) — NEVER as a blocking sheet/alert. The map stays fully usable underneath at
//  all times (AC-7).
//
//  Persistence (ParkingGuidePromptGate) is owned by the caller (ContentView), matching
//  the BackgroundNoteGate usage pattern — this view is a pure presentation component
//  with two callbacks. `onOpenGuide` and `onDismiss` are both "shown" outcomes; the
//  caller calls `gate.markShown()` from either.
//
//  Auto-hide: fires `onDismiss` after ~8 seconds if the user hasn't already tapped
//  through or dismissed manually. Implemented as a `.task` so it's cancelled
//  automatically if the view disappears for any other reason.
//

import SwiftUI

struct ParkingGuidePromptBanner: View {

    /// Auto-hide delay, matching spec §7 OQ-2 ("~8s").
    static let autoHideDelaySeconds: UInt64 = 8

    /// Called when the user taps the banner body to open the guide.
    let onOpenGuide: () -> Void

    /// Called when the user taps the X to dismiss, or when the auto-hide timer fires.
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onOpenGuide) {
                HStack(spacing: 10) {
                    Image(systemName: "signpost.right.and.left")
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("New to NYC parking?")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        Text("Free parking is doable — read the guide")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New to NYC parking? Free parking is doable. Read the Parking 101 guide.")
            .accessibilityHint("Opens the Parking 101 guide")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .task {
            try? await Task.sleep(nanoseconds: Self.autoHideDelaySeconds * 1_000_000_000)
            if !Task.isCancelled {
                onDismiss()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Spacer()
        ParkingGuidePromptBanner(onOpenGuide: {}, onDismiss: {})
    }
    .background(Color(.systemGroupedBackground))
}
