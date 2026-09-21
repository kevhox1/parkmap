//
//  RegularsSettingsView.swift
//  WePark
//
//  Regulars network — S7 (iOS UI session). Spec: docs/regulars-network-spec.md §3.1 (the
//  Regulars home surface: list + remove/block + "Add a Regular"). Sequencing:
//  docs/regulars-roadmap.md, session S7.
//
//  Reached ONLY via `SettingsView`'s "Regulars" row, which is itself gated on
//  `AppConstants.regularsSettingsRowVisible()` (`Services/Constants.swift`, S5) — while
//  `regularsEnabled == false` (today's shipped default) that row never renders, so this view is
//  never even pushed onto the navigation stack. This file's own top-level gate below is
//  defense-in-depth, mirroring this codebase's `communityEnabled` double-gating precedent
//  (`ContentView.swift`'s `crewFeed` closure comment: "kept as a second, redundant-but-harmless
//  line of defense, not the authoritative gate").
//
//  Handle/avatar resolution: `RegularsService.fetchProfiles(ids:)` (S7 addition) reads the
//  pre-existing, app-wide public `profiles` table — see that method's own doc comment for why
//  this is not a new privacy surface on top of the Regulars-owned tables.
//
//  "Remove" (plain unfriend, `RegularsService.removeRegular`) and "Block" (severs the edge
//  server-side via a trigger, `RegularsService.block`) are both `.swipeActions` — full-row-height
//  buttons, not a tiny inline "x", per this repo's standing bigger-touch-target preference.
//
//  No Calendar.current — `Date.formatted(date:time:)` is Foundation's own `FormatStyle` API, not
//  a hand-rolled Calendar computation.
//

import SwiftUI

struct RegularsSettingsView: View {
    let service: RegularsService

    @State private var profiles: [UUID: RegularProfileSummary] = [:]
    @State private var isLoading = false
    @State private var showingInviteSheet = false
    @State private var actionError: String?

    var body: some View {
        Group {
            if !AppConstants.regularsSettingsRowVisible() {
                EmptyView()
            } else {
                content
            }
        }
        .navigationTitle("Regulars")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard AppConstants.regularsSettingsRowVisible() else { return }
            await refresh()
        }
        .sheet(isPresented: $showingInviteSheet, onDismiss: {
            Task { await refresh() }
        }) {
            RegularInviteView(service: service)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        List {
            if let actionError {
                Section {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if service.edges.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No Regulars yet")
                            .font(.headline)
                        Text("Add the people you actually know on your block. They get first crack at your spot when you're leaving, and a quick heads-up when you're moving your car.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section("Your Regulars") {
                    ForEach(service.edges) { edge in
                        regularRow(for: edge)
                    }
                }
            }

            Section {
                Button {
                    showingInviteSheet = true
                } label: {
                    Label("Add a Regular", systemImage: "qrcode")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
        .overlay {
            if isLoading && service.edges.isEmpty {
                ProgressView()
            }
        }
        .refreshable {
            await refresh()
        }
    }

    @ViewBuilder
    private func regularRow(for edge: RegularEdge) -> some View {
        let ownId = service.authService?.currentUserId
        let otherId = ownId.flatMap { edge.otherUserId(ownUserId: $0) }
        let profile = otherId.flatMap { profiles[$0] }

        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(.systemGray5))
                    .frame(width: 40, height: 40)
                if let avatar = profile?.avatar {
                    Text(avatar)
                        .font(.system(size: 18))
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.username ?? "Regular")
                    .font(.subheadline.weight(.semibold))
                Text("Regular since \(edge.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await remove(otherId: otherId) }
            } label: {
                Label("Remove", systemImage: "person.fill.xmark")
            }

            Button {
                Task { await block(otherId: otherId) }
            } label: {
                Label("Block", systemImage: "hand.raised.fill")
            }
            .tint(.orange)
        }
    }

    // MARK: - Actions

    private func refresh() async {
        isLoading = true
        await service.fetchEdges()
        isLoading = false

        guard let ownId = service.authService?.currentUserId else { return }
        let otherIds = service.edges.compactMap { $0.otherUserId(ownUserId: ownId) }
        guard !otherIds.isEmpty else { return }
        let fetched = await service.fetchProfiles(ids: otherIds)
        for (id, summary) in fetched {
            profiles[id] = summary
        }
    }

    private func remove(otherId: UUID?) async {
        guard let otherId else { return }
        actionError = nil
        do {
            try await service.removeRegular(otherUserId: otherId)
        } catch {
            actionError = "Couldn't remove. Check your connection and try again."
        }
    }

    private func block(otherId: UUID?) async {
        guard let otherId else { return }
        actionError = nil
        do {
            try await service.block(userId: otherId)
            // `regular_blocks`' own `delete_regular_edge_on_block` trigger already severed the
            // edge server-side (07-regulars-schema.sql §S1-3) — re-fetch so the local list
            // reflects that rather than trying to replicate the server's own deletion logic here.
            await service.fetchEdges()
        } catch {
            actionError = "Couldn't block. Check your connection and try again."
        }
    }
}
