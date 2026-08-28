//
//  IdentitySheet.swift
//  WePark
//
//  Community 2.0 Phase 2b (build 20 S7) — first-contribution handle/avatar sheet.
//  Spec: docs/community-2.0-reconciliation-spec.md §3 Phase 2 ("Identity sheet").
//  Visual truth: design/screenshots/12-identity-sheet.png.
//  Copy + avatar list verbatim: design/prototype.html:415-429 (markup), :1016 (avatar list).
//
//  Behavioral fix vs. the prototype's literal logic (spec §3 Phase 2, explicit): the
//  prototype's `needIdentity()` re-shows the sheet on EVERY contribution until a handle is
//  actually set (`skipIdentity` never sets `state.handle`, so the gate never latches) — a
//  straight port would re-prompt an anonymous poster on every single report. This file's
//  `CommunityIdentityGate` instead gates on "has this device ever SEEN the identity sheet" —
//  a `UserDefaults` bool set the first time the sheet is shown (regardless of pick-a-handle
//  vs. skip, marked in `IdentitySheet.onAppear`, not on any particular button tap) — never
//  re-prompts after that, on this device, ever again.
//
//  Wiring: `ReportSheet.submitReport()` and `ContentView.submitSpotPlacement()` both check
//  `CommunityIdentityInterception.shouldShowIdentitySheet(communityEnabled:identitySheetShouldShow:)`
//  before proceeding with their actual network write — "every contribution path (report
//  post, spot post)" per spec. Gated on `AppConstants.communityEnabled` explicitly: the
//  report-submit path predates Community 2.0 entirely and is live for every user today —
//  flag-off must see ZERO behavior change (no sheet ever shown, no UserDefaults write ever
//  made).
//
//  Identity save ("Join the board & post") upserts a `profiles` row (`username`, `avatar`)
//  via `CommunityPinService.upsertProfile(username:avatar:)` — NEVER `reputation` (server-
//  computed only, via §2.6's insert-on-conflict triggers; the client never writes its own
//  rep, a standing constraint).
//
//  This view owns no persistence itself (mirrors `ParkingGuidePromptBanner`'s pattern —
//  a pure presentation component with callbacks; the caller owns the gate + the network
//  write).
//

import SwiftUI

// MARK: - CommunityIdentityGate

/// One-time gate for the Community 2.0 identity sheet. Mirrors `ParkingGuidePromptGate` /
/// `BackgroundNoteGate` (`Services/Constants.swift`) exactly — same injectable-`UserDefaults`
/// shape for test isolation, same `shouldShow()`/`markShown()` API.
///
/// Usage:
///   let gate = CommunityIdentityGate()  // uses UserDefaults.standard
///   if gate.shouldShow() {
///       // present IdentitySheet
///       // IdentitySheet.onAppear calls gate.markShown() itself
///   }
struct CommunityIdentityGate {

    /// Self-contained key (not routed through `AppConstants`, unlike the two older gates)
    /// — this session's touch list is scoped to `IdentitySheet.swift` only; see this file's
    /// header. `wepark_community_identity_shown` follows the same `wepark_<feature>_shown`
    /// naming convention as `AppConstants.parkingGuidePromptShownKey` /
    /// `driveModeBackgroundNoteShownKey`.
    static let shownKey = "wepark_community_identity_shown"

    private let defaults: UserDefaults
    private let key: String

    /// Designated init — accepts any `UserDefaults` instance so tests can inject an
    /// ephemeral suite instead of polluting `UserDefaults.standard`.
    init(defaults: UserDefaults = .standard, key: String = CommunityIdentityGate.shownKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Returns `true` if the identity sheet has never been shown on this device.
    func shouldShow() -> Bool {
        !defaults.bool(forKey: key)
    }

    /// Persists that the sheet has been shown. Subsequent `shouldShow()` calls return
    /// `false` — regardless of what the user picked ("Join the board & post" vs. "Post
    /// anonymously"), since this is called from `IdentitySheet.onAppear`, not from either
    /// button's action.
    func markShown() {
        defaults.set(true, forKey: key)
    }
}

// MARK: - CommunityIdentityInterception

/// Pure, `nonisolated` gating logic shared by every contribution path (report submit, spot
/// post) that needs to decide "show the identity sheet before proceeding, or go straight
/// through?" `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for this target — `nonisolated`
/// keeps this callable from a plain XCTest method without a MainActor hop.
enum CommunityIdentityInterception {

    /// `true` only when BOTH:
    ///   - `communityEnabled` — flag-off contribution paths (the report-submit path
    ///     predates Community 2.0 entirely) must see zero behavior change: no sheet ever
    ///     shown, no `UserDefaults` write ever made.
    ///   - `identitySheetShouldShow` — the show-once gate has never fired on this device
    ///     (pass `CommunityIdentityGate().shouldShow()` at the call site).
    nonisolated static func shouldShowIdentitySheet(
        communityEnabled: Bool,
        identitySheetShouldShow: Bool
    ) -> Bool {
        communityEnabled && identitySheetShouldShow
    }
}

// MARK: - IdentitySheet

/// "Say hi to the crew" — 8-avatar picker + handle field + CTA / skip.
/// Copy verbatim, `design/prototype.html:418-419,427`.
struct IdentitySheet: View {

    /// 8-emoji avatar list, verbatim order — `design/prototype.html:1016`.
    static let avatarOptions: [String] = ["🥯", "☕", "🚕", "🌇", "🦝", "🍕", "🗽", "🐿️"]

    /// A short, friendly generated handle for the pre-filled text field — see `handle`'s own
    /// doc comment for why this exists beyond matching the prototype's screenshot. Not a
    /// uniqueness-guaranteeing scheme (the reconciliation spec §2.5 explicitly made the
    /// handle "decorative, not a login identifier... a cosmetic non-issue, not a security
    /// one" when it dropped the column's UNIQUE constraint) — just non-empty, every time.
    static func generateDefaultHandle() -> String {
        "Neighbor" + String(Int.random(in: 1000...9999))
    }

    /// Called when "Join the board & post" is tapped. `username` is the trimmed handle text
    /// — in practice always non-nil/non-empty, since the field is pre-filled with a
    /// generated suggestion (see `handle`'s own doc comment for why this matters beyond
    /// cosmetics). `avatar` is the selected emoji, or nil if none was picked.
    let onSave: (_ username: String?, _ avatar: String?) -> Void

    /// Called when "Post anonymously" is tapped — no `profiles` write happens for this path.
    let onSkip: () -> Void

    @State private var selectedAvatar: String? = nil

    /// Pre-filled with a generated suggestion (`design/screenshots/12-identity-sheet.png`
    /// shows "MottStRegular" already in the field, not typed live in the demo — this is the
    /// prototype's own actual behavior, not a departure from it). This is NOT just cosmetic:
    /// `public.profiles.username` is `text ... not null` (`supabase/01-mvp-schema.sql:10`) —
    /// Phase 0's migration (§2.5) only dropped the column's UNIQUE constraint
    /// (`profiles_username_key`), not its `NOT NULL`. A user's FIRST-EVER `upsertProfile`
    /// call may be inserting their `profiles` row for the very first time (before any
    /// reputation trigger has had a chance to create one) — sending `username: nil` there
    /// would violate the NOT NULL constraint. Starting the field non-empty means "Join the
    /// board & post" always sends a real handle without the user needing to type anything,
    /// closing that gap client-side without touching schema.
    @State private var handle: String = IdentitySheet.generateDefaultHandle()
    @FocusState private var handleFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Say hi to the crew")
                    .font(.title2.weight(.bold))
                Text("First report! Pick how neighbors see you. No account — this lives on your phone and signs your reports.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(Self.avatarOptions, id: \.self) { emoji in
                    avatarButton(emoji)
                }
            }

            TextField("Pick a handle", text: $handle)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14))
                .focused($handleFieldFocused)
                .submitLabel(.done)
                .accessibilityLabel("Handle")

            Button {
                // `handle` starts pre-filled (see its own doc comment) so `trimmed` is
                // non-empty on the common path; still guarded here rather than assumed, so
                // a user who explicitly clears the field gets a `nil` username (not an
                // empty-string one) — a rare edge case (requires deliberately deleting the
                // pre-fill) accepted as a known, disclosed gap rather than adding a
                // disable-the-CTA-on-empty-handle behavior the prototype itself never has.
                let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
                onSave(trimmed.isEmpty ? nil : trimmed, selectedAvatar)
            } label: {
                Text("Join the board & post")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 4.0 / 255, green: 41.0 / 255, blue: 15.0 / 255))
            .background(Color(red: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255), in: Capsule())

            Button(action: onSkip) {
                Text("Post anonymously")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .onAppear {
            // Marks "shown" the moment this view mounts — regardless of which button the
            // user eventually taps. See this file's header + `CommunityIdentityGate`'s own
            // doc comment for why this is the fix vs. the prototype's literal (re-prompting)
            // `needIdentity()` logic.
            CommunityIdentityGate().markShown()
        }
    }

    @ViewBuilder
    private func avatarButton(_ emoji: String) -> some View {
        let isSelected = selectedAvatar == emoji
        Button {
            selectedAvatar = emoji
        } label: {
            Text(emoji)
                .font(.system(size: 22))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(.systemGray5)))
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Color(red: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255) : Color.clear,
                        lineWidth: 2
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Avatar option \(emoji)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
