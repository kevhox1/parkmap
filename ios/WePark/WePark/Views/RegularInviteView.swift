//
//  RegularInviteView.swift
//  WePark
//
//  Regulars network — S7 (iOS UI session). Spec: docs/regulars-network-spec.md §3.2 (invite
//  flow: QR + `ShareLink`, 10-min TTL countdown, Cancel/regenerate). Sequencing:
//  docs/regulars-roadmap.md, session S7.
//
//  Presented as a sheet from `RegularsSettingsView`'s "Add a Regular" button. On appear, inserts
//  one `regular_invites` row (`RegularsService.createInvite()`) and renders it as BOTH a QR code
//  (`CoreImage`'s `CIQRCodeGenerator` — no third-party library, per this session's explicit
//  constraint) and a `ShareLink` — same underlying token, two presentations (spec decision 5).
//
//  Redemption detection: POLLS `RegularsService.fetchInvite(id:)` every 3s (not Realtime — this
//  session's dispatch explicitly defers "the live-push half of its gate" to S13; a lightweight
//  poll is the lower-risk choice for a first UI pass and the spec itself says "polls OR
//  subscribes via Realtime ... either works"). Stops polling the moment `redeemed_by` is set, an
//  invite expires, or this view disappears.
//
//  FULLY gated on `AppConstants.regularsEnabled` (defense-in-depth — the only live call site,
//  `RegularsSettingsView`, already gates presenting this sheet at all; this view repeats the
//  check per this codebase's own `communityEnabled` double-gating precedent, e.g.
//  `ContentView.swift`'s `crewFeed` closure comment on why "the caller's gate alone" wasn't
//  sufficient for a past Community 2.0 finding).
//
//  No Calendar.current.
//

import SwiftUI
import CoreImage
import UIKit

struct RegularInviteView: View {
    let service: RegularsService

    @Environment(\.dismiss) private var dismiss

    @State private var invite: RegularInvite?
    // Starts `true` (not `false`) — `.task` below always calls `createInvite()` immediately on
    // appear, so defaulting to "working" avoids a one-frame flash of `errorState`'s "couldn't
    // create an invite" copy before that call has even started.
    @State private var isWorking = true
    @State private var errorMessage: String?
    @State private var redeemedByProfile: RegularProfileSummary?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if !AppConstants.regularsEnabled {
                    EmptyView()
                } else if let redeemedByProfile {
                    successState(handle: redeemedByProfile.username)
                } else if let invite {
                    inviteState(invite)
                } else if isWorking {
                    ProgressView("Creating invite…")
                        .padding()
                } else {
                    errorState
                }
            }
            .navigationTitle("Add a Regular")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            guard AppConstants.regularsEnabled, invite == nil else { return }
            await createInvite()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    // MARK: - States

    @ViewBuilder
    private func inviteState(_ invite: RegularInvite) -> some View {
        let url = RegularsInviteLink.build(token: invite.id)
        ScrollView {
            VStack(spacing: 20) {
                Text("Show this QR code to a neighbor, or send them the link. Either one adds them the same way.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let qrImage = Self.qrCodeImage(from: url.absoluteString) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.systemGray5))
                        .frame(width: 220, height: 220)
                        .overlay(Text("QR unavailable").foregroundStyle(.secondary))
                }

                Text(url.absoluteString)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                ShareLink(item: url) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let expired = InviteCountdown.isExpired(expiresAt: invite.expiresAt, now: context.date)
                    let remaining = InviteCountdown.remainingSeconds(expiresAt: invite.expiresAt, now: context.date)
                    Text(expired ? "This invite has expired" : "Expires in \(InviteCountdown.formatted(remainingSeconds: remaining))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(expired ? Color.red : Color.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 16) {
                    Button(role: .destructive) {
                        Task { await cancelInvite(invite) }
                    } label: {
                        Text("Cancel invite")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await createInvite() }
                    } label: {
                        Text("New invite")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func successState(handle: String?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            if let handle {
                Text("\(handle) joined your Regulars")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
            } else {
                Text("Someone joined your Regulars")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    @ViewBuilder
    private var errorState: some View {
        VStack(spacing: 16) {
            Text(errorMessage ?? "Couldn't create an invite. Check your connection and try again.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try again") {
                Task { await createInvite() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    // MARK: - Actions

    private func createInvite() async {
        pollTask?.cancel()
        isWorking = true
        errorMessage = nil
        redeemedByProfile = nil
        do {
            let created = try await service.createInvite()
            invite = created
            startPolling(inviteId: created.id)
        } catch {
            invite = nil
            errorMessage = "Couldn't create an invite. Check your connection and try again."
        }
        isWorking = false
    }

    private func cancelInvite(_ invite: RegularInvite) async {
        pollTask?.cancel()
        do {
            try await service.cancelInvite(id: invite.id)
            dismiss()
        } catch {
            errorMessage = "Couldn't cancel. Try again."
        }
    }

    private func startPolling(inviteId: UUID) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                guard let fetched = try? await service.fetchInvite(id: inviteId) else { continue }
                guard fetched.id == self.invite?.id else { return } // superseded by a regenerate
                self.invite = fetched
                if let redeemedBy = fetched.redeemedBy {
                    let profiles = await service.fetchProfiles(ids: [redeemedBy])
                    self.redeemedByProfile = profiles[redeemedBy]
                    return
                }
                if InviteCountdown.isExpired(expiresAt: fetched.expiresAt, now: Date()) {
                    return
                }
            }
        }
    }

    // MARK: - QR generation

    /// Renders `string` (the invite URL's `absoluteString`) as a QR code using CoreImage's
    /// built-in `CIQRCodeGenerator` — no third-party dependency, per this session's explicit
    /// constraint. `nonisolated` so it's directly unit-testable from a plain XCTest method
    /// without a `MainActor` hop (pure function: same input always produces an equivalent-size
    /// image; CoreImage/UIImage construction touches no actor-isolated state).
    ///
    /// - Parameters:
    ///   - string: The payload to encode — the invite URL's `absoluteString`, never the bare
    ///     token (a scanner must be able to open the link directly).
    ///   - scale: Upscale factor applied to the filter's native (very small, ~1pt-per-module)
    ///     output so the rendered image is crisp at on-screen sizes. `.interpolation(.none)` at
    ///     the call site keeps QR module edges sharp rather than blurring them.
    /// - Returns: `nil` if CoreImage fails to produce an image for `string` (defensive only —
    ///   `CIQRCodeGenerator` accepts any non-empty `Data` payload up to its capacity, and an
    ///   invite URL is always well within that).
    nonisolated static func qrCodeImage(from string: String, scale: CGFloat = 10) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else { return nil }
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
