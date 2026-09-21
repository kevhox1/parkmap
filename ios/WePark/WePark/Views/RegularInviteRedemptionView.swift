//
//  RegularInviteRedemptionView.swift
//  WePark
//
//  Regulars network — S7 (iOS UI session). Spec: docs/regulars-network-spec.md §3.2 (the
//  redeem-side confirm sheet), §2.4 (`redeem_regular_invite`'s four terminal states).
//  Sequencing: docs/regulars-roadmap.md, session S7.
//
//  Presented by `WeParkApp`'s `.onOpenURL` handler when `wepark://invite/<uuid>` is opened
//  (Camera-app QR scan, a tapped share-link, or any other URL-opening surface) and
//  `AppConstants.regularsEnabled == true`. Renders all four `RegularInviteRedeemResult` states
//  plus a genuine transport-error state, with honest, non-punitive copy for every non-success
//  case (`RegularInviteRedemptionCopy`, `Services/RegularsInviteRouting.swift`) — no "avoid",
//  "ticket", "fine", "evasion", or "dodge" anywhere in this file.
//
//  KNOWN, FLAGGED CONSTRAINT — the pre-confirm sheet does NOT name the inviter (spec §3.2's own
//  sketch, "Dave wants to add you as a Regular", assumes that's possible). It isn't, given the
//  merged schema: `regular_invites_select_own` restricts SELECT to `created_by = auth.uid()`, so
//  a redeeming session cannot read the invite row (or the inviter's identity) before calling
//  `redeem_regular_invite`. See `RegularsInviteRouting.swift`'s header for the full writeup and
//  this session's PR description for the flag to the orchestrator. Post-SUCCESS copy IS
//  personalized (the RPC's own response includes `regular_id`, resolved to a handle here via
//  `RegularsService.fetchProfiles(ids:)`).
//
//  No Calendar.current.
//

import SwiftUI

struct RegularInviteRedemptionView: View {
    let token: UUID
    let service: RegularsService

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case confirm
        case redeeming
        case result(RegularInviteRedeemResult)
        case transportError
    }

    @State private var phase: Phase = .confirm
    @State private var resolvedHandle: String?

    var body: some View {
        NavigationStack {
            Group {
                if !AppConstants.regularsEnabled {
                    // Defense-in-depth (see this file's header) — `WeParkApp.onOpenURL` already
                    // gates presenting this view at all on the same flag.
                    EmptyView()
                } else {
                    switch phase {
                    case .confirm:
                        confirmView
                    case .redeeming:
                        ProgressView("Adding…")
                            .padding()
                    case .result(let result):
                        resultView(result)
                    case .transportError:
                        transportErrorView
                    }
                }
            }
            .navigationTitle("Regulars invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - States

    @ViewBuilder
    private var confirmView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text(RegularInviteRedemptionCopy.preConfirmTitle)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)

            Text(RegularInviteRedemptionCopy.preConfirmBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await redeem() }
            } label: {
                Text(RegularInviteRedemptionCopy.preConfirmActionTitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)

            Button(RegularInviteRedemptionCopy.preConfirmCancelTitle) {
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        }
        .padding(24)
    }

    @ViewBuilder
    private func resultView(_ result: RegularInviteRedeemResult) -> some View {
        let copy = RegularInviteRedemptionCopy.resultCopy(for: result, regularHandle: resolvedHandle)
        VStack(spacing: 16) {
            Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(result.isSuccess ? Color.green : Color.secondary)

            Text(copy.title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)

            Text(copy.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    @ViewBuilder
    private var transportErrorView: some View {
        VStack(spacing: 16) {
            Text("Something went wrong. Check your connection and try again.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Try again") {
                phase = .confirm
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    // MARK: - Actions

    private func redeem() async {
        phase = .redeeming
        do {
            let result = try await service.redeemInvite(token: token)
            if case .success(let regularId) = result {
                let profiles = await service.fetchProfiles(ids: [regularId])
                resolvedHandle = profiles[regularId]?.username
            }
            phase = .result(result)
        } catch {
            phase = .transportError
        }
    }
}
