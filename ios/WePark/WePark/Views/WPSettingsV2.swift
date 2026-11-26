//
//  WPSettingsV2.swift
//  WePark
//
//  Stoop Phase 6a (B15): the round-2 More sheet, Settings (with Reminders, Help and About),
//  "What the colors mean", and the Stoop skin for account deletion / suggest-a-neighborhood.
//  Presented by `ContentView` in place of `MoreMenuSheet`, `SettingsView` and `MapKeyLegendView`
//  ONLY while `AppConstants.designSystemV2Enabled` is true. Pure presentation over the same
//  storage the flag-off screens use (`notificationsMuted`, `ReminderOffsets`, `DrivingVoice`);
//  scheduling semantics are untouched: `ContentView` still persists offsets and reschedules.
//

import SwiftUI
import UserNotifications

// MARK: - Shared pieces

/// Title row of a Stoop sheet: 28/700 title and the 48pt close pill.
struct WPSheetTitleBar: View {
    let title: String
    var closeLabel: String = "Close"
    let onClose: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes the pill drops under the title so a long word never breaks.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: WP.Space.s2))
        return layout {
            Text(title)
                .font(WP.Font.fredoka(28, .bold, relativeTo: .title))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button(closeLabel, action: onClose)
                .buttonStyle(WPClosePillStyle())
        }
        .padding(.horizontal, WP.Space.screenMargin)
        .padding(.top, WP.Space.s4)
        .padding(.bottom, WP.Space.s2)
    }
}

/// A list row with a title and a trailing value. Stacks the value under the title at
/// accessibility sizes so neither truncates.
struct WPValueRow: View {
    let title: String
    let value: String
    var showsChevron: Bool = true
    var action: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if let action {
            Button(action: action) { rowBody }
                .buttonStyle(WPListRowPressStyle())
        } else {
            rowBody
        }
    }

    private var rowBody: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: WP.Space.s3))
        return HStack(spacing: WP.Space.s3) {
            layout {
                Text(title)
                    .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                    .foregroundStyle(WP.text)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                if !typeSize.isAccessibilitySize { Spacer(minLength: WP.Space.s2) }
                Text(value)
                    .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                    .foregroundStyle(WP.muted)
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WP.muted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, WP.Space.s2)
        .frame(maxWidth: .infinity, minHeight: WPListMetrics.rowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Wrapping row of non-tappable chips.
struct WPChipFlowLayout: Layout {
    var spacing: CGFloat = WP.Space.s2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Small section header above a list card (15/700).
private struct WPSectionHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .font(WP.Font.fredoka(15, .bold, relativeTo: .callout))
            .foregroundStyle(WP.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - More sheet (B15.1)

struct WPMoreSheetV2: View {
    /// Already filtered by `moreMenuVisibleRows` (the one source of truth, unchanged).
    let rows: [MoreMenuRow]
    /// "Show all sign details" on/off, read from the caller so state has one owner.
    let signDetailsOn: Bool
    let onSelect: (MoreMenuRow) -> Void
    let onToggleSignDetails: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WPSheetTitleBar(title: "More", onClose: onDone)
            ScrollView {
                WPListCard {
                    ForEach(Array(rows.enumerated()), id: \.element.title) { index, row in
                        if index > 0 { WPListDivider() }
                        if row == .showAllRules {
                            WPListToggleRow(
                                title: row.title,
                                isOn: Binding(get: { signDetailsOn }, set: { _ in onToggleSignDetails() })
                            )
                            .accessibilityHint(row.subtitle)
                        } else {
                            WPListRow(title: row.title, trailing: .chevron) { onSelect(row) }
                                .accessibilityHint(row.subtitle)
                        }
                    }
                }
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.bottom, WP.Space.s4)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(WP.card.ignoresSafeArea())
    }
}

// MARK: - Settings (B15.2)

private enum WPSettingsRoute: Hashable {
    case reminders
    case help
    case helpTopic(String)
    case about
    case sources
    case regulars
}

struct WPSettingsV2: View {

    @Binding var notificationsMuted: Bool
    @Binding var offsets: ReminderOffsets
    let drivingVoice: DrivingVoice
    let regularsService: RegularsService
    let onUnmute: () -> Void
    let onOffsetsChange: () -> Void
    let appVersion: String
    let buildNumber: String

    @Environment(\.dismiss) private var dismiss
    @Environment(SupabaseAuthService.self) private var authService: SupabaseAuthService?
    @State private var path: [WPSettingsRoute] = []
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var showSuggest = false
    @State private var deleteModel: AccountDeletionModel?
    @State private var showDelete = false

    var body: some View {
        NavigationStack(path: $path) {
            root
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: WPSettingsRoute.self) { route in destination(route) }
        }
        .background(WP.paper.ignoresSafeArea())
        .task { await refreshNotificationStatus() }
        .onChange(of: offsets) { _, newOffsets in
            ReminderOffsets.save(newOffsets, to: .standard)
            onOffsetsChange()
        }
        .sheet(isPresented: $showSuggest) {
            SuggestNeighborhoodSheet(viewedLatitude: nil, viewedLongitude: nil)
        }
        .sheet(isPresented: $showDelete, onDismiss: handleDeleteDismissed) {
            if let deleteModel {
                DeleteAccountConfirmView(model: deleteModel, onFinished: { showDelete = false })
            }
        }
    }

    // MARK: Root

    private var root: some View {
        VStack(spacing: 0) {
            WPSheetTitleBar(title: "Settings") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.s3) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, rows in
                        WPListCard {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                if index > 0 { WPListDivider() }
                                rowView(row)
                            }
                        }
                    }
                    #if DEBUG
                    developerRow
                    #endif
                }
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.bottom, WP.Space.s6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(WP.paper.ignoresSafeArea())
    }

    private var sections: [[WPSettingsLogic.Row]] {
        WPSettingsLogic.sections(
            suggestVisible: AppConstants.coverageSuggestionVisible(),
            deleteVisible: AppConstants.accountDeletionRowVisible() && authService != nil,
            regularsVisible: AppConstants.regularsSettingsRowVisible()
        )
    }

    @ViewBuilder
    private func rowView(_ row: WPSettingsLogic.Row) -> some View {
        switch row {
        case .reminders:
            WPValueRow(
                title: "Reminders",
                value: WPSettingsLogic.reminderSummary(offsets: offsets, muted: notificationsMuted)
            ) { path.append(.reminders) }
        case .voice:
            WPListToggleRow(
                title: "Voice while driving",
                isOn: Binding(get: { !drivingVoice.isMuted }, set: { drivingVoice.isMuted = !$0 })
            )
        case .notifications:
            WPValueRow(
                title: "Notifications",
                value: WPSettingsLogic.notificationStatusLabel(notificationStatus)
            ) { openSystemSettings() }
            .accessibilityHint("Opens WePark in iOS Settings.")
        case .regulars:
            WPListRow(title: "Regulars", trailing: .chevron) { path.append(.regulars) }
        case .suggestNeighborhood:
            WPListRow(title: "Suggest a neighborhood", trailing: .chevron) { showSuggest = true }
        case .deleteAccount:
            Button { presentDelete() } label: {
                HStack {
                    Text("Delete account")
                        .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                        .foregroundStyle(WP.noParkText)
                    Spacer(minLength: WP.Space.s2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(WP.muted)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, WP.Space.s2)
                .frame(maxWidth: .infinity, minHeight: WPListMetrics.rowMinHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(WPListRowPressStyle())
            .accessibilityHint("Permanently deletes your WePark account. You will be asked to confirm.")
        case .help:
            WPListRow(title: "Help and FAQ", trailing: .chevron) { path.append(.help) }
        case .about:
            WPListRow(title: "About", trailing: .chevron) { path.append(.about) }
        }
    }

    #if DEBUG
    private var developerRow: some View {
        WPListCard {
            NavigationLink {
                DesignSystemGalleryView()
            } label: {
                Text("Design system gallery (debug)")
                    .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                    .foregroundStyle(WP.text)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: WPListMetrics.rowMinHeight, alignment: .leading)
            }
        }
    }
    #endif

    // MARK: Destinations

    @ViewBuilder
    private func destination(_ route: WPSettingsRoute) -> some View {
        switch route {
        case .reminders:
            WPReminderSettingsV2(
                notificationsMuted: $notificationsMuted,
                offsets: $offsets,
                onUnmute: onUnmute,
                onBack: { pop() }
            )
            .toolbar(.hidden, for: .navigationBar)
        case .help:
            WPHelpV2(onBack: { pop() }, onOpenTopic: { path.append(.helpTopic($0)) })
                .toolbar(.hidden, for: .navigationBar)
        case .helpTopic(let id):
            WPHelpTopicV2(topicID: id, onBack: { pop() })
                .toolbar(.hidden, for: .navigationBar)
        case .about:
            WPAboutV2(
                version: WPSettingsLogic.versionLabel(version: appVersion, build: buildNumber),
                onBack: { pop() },
                onSources: { path.append(.sources) }
            )
            .toolbar(.hidden, for: .navigationBar)
        case .sources:
            WPRulesSourcesV2(onBack: { pop() })
                .toolbar(.hidden, for: .navigationBar)
        case .regulars:
            RegularsSettingsView(service: regularsService)
        }
    }

    private func pop() { if !path.isEmpty { path.removeLast() } }

    // MARK: Actions

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func presentDelete() {
        guard let authService else { return }
        // A fresh model per presentation, so an earlier failure message never lingers.
        deleteModel = AccountDeletionModel(deleter: AccountDeletionService(authService: authService))
        showDelete = true
    }

    /// Same follow-up as the flag-off section: thank the user, then close Settings.
    private func handleDeleteDismissed() {
        guard let deleteModel, deleteModel.isDeleted else { return }
        ToastService.shared.show(message: "Your account was deleted")
        dismiss()
    }
}

// MARK: - Reminders (B15.3)

/// The one reminder option set (DECISIONS #8), bound to the same `ReminderOffsets` storage My Car
/// uses. The parent persists on change and reschedules (`onOffsetsChange`).
struct WPReminderOptionSet: View {
    @Binding var offsets: ReminderOffsets
    var isEnabled: Bool = true
    var chipHeight: CGFloat = 64

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: WP.Space.s2),
            count: typeSize.isAccessibilitySize ? 1 : 4
        )
        LazyVGrid(columns: columns, spacing: WP.Space.s1) {
            ForEach(WPSettingsLogic.LeadOption.allCases, id: \.chipTitle) { option in
                WPChoiceChip(
                    title: option.chipTitle,
                    isSelected: option.isOn(in: offsets),
                    height: chipHeight
                ) { offsets = option.toggled(in: offsets) }
                .disabled(!isEnabled)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
    }
}

struct WPReminderSettingsV2: View {
    @Binding var notificationsMuted: Bool
    @Binding var offsets: ReminderOffsets
    let onUnmute: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WPSheetTitleBar(title: "Reminders", closeLabel: "Back", onClose: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.s3) {
                    WPListCard {
                        WPListToggleRow(
                            title: "Park reminders",
                            subtitle: "Turn every parking reminder off or on.",
                            isOn: activeBinding
                        )
                    }
                    Text("How long before a curb changes should WePark remind you?")
                        .font(WP.Font.fredoka(17, .regular, relativeTo: .body))
                        .foregroundStyle(WP.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, WP.Space.s2)
                    WPReminderOptionSet(offsets: $offsets, isEnabled: !notificationsMuted)
                    WPListCard {
                        WPListToggleRow(title: "Also the night before", isOn: $offsets.remindNightBefore)
                            .disabled(notificationsMuted)
                        WPListDivider()
                        // The scheduler fires the night-before reminder at a fixed hour, so this is
                        // a fact, not a control.
                        WPValueRow(
                            title: "Night-before time",
                            value: WPSettingsLogic.nightBeforeTimeLabel(hour: AppConstants.nightBeforeHourET),
                            showsChevron: false
                        )
                    }
                    .opacity(notificationsMuted ? 0.5 : 1)
                    Text("Used each time you park. You can still switch reminders off for one parked car in My Car.")
                        .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                        .foregroundStyle(WP.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.bottom, WP.Space.s6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(WP.paper.ignoresSafeArea())
    }

    /// The switch shows the ACTIVE state (the inverse of the mute flag); turning it back on fires
    /// `onUnmute` exactly like the flag-off Settings toggle.
    private var activeBinding: Binding<Bool> {
        Binding(
            get: { !notificationsMuted },
            set: { isActive in
                let wasMuted = notificationsMuted
                notificationsMuted = !isActive
                if wasMuted && isActive { onUnmute() }
            }
        )
    }
}

// MARK: - Help (B15.7)

struct WPHelpV2: View {
    let onBack: () -> Void
    let onOpenTopic: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            WPSheetTitleBar(title: "Help", closeLabel: "Back", onClose: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.s3) {
                    WPListCard {
                        ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                            if index > 0 { WPListDivider() }
                            WPListRow(title: topic.question, trailing: .chevron) { onOpenTopic(topic.id) }
                        }
                    }
                    WPListCard {
                        NavigationLink {
                            FAQHelpView()
                        } label: {
                            HStack {
                                Text("NYC parking basics")
                                    .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                                    .foregroundStyle(WP.text)
                                Spacer(minLength: WP.Space.s2)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(WP.muted)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 18)
                            .frame(maxWidth: .infinity, minHeight: WPListMetrics.rowMinHeight, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(WPListRowPressStyle())
                    }
                }
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.bottom, WP.Space.s6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(WP.paper.ignoresSafeArea())
    }

    private var topics: [WPHelpTopic] { WPHelpTopic.topics(spotPassEnabled: AppConstants.spotHandoffEnabled) }
}

struct WPHelpTopicV2: View {
    let topicID: String
    let onBack: () -> Void

    var body: some View {
        let topic = WPHelpTopic.topics(spotPassEnabled: AppConstants.spotHandoffEnabled)
            .first { $0.id == topicID }
        VStack(spacing: 0) {
            WPSheetTitleBar(title: "Help", closeLabel: "Back", onClose: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.s3) {
                    if let topic {
                        Text(topic.question)
                            .font(WP.Font.fredoka(24, .semibold, relativeTo: .title2))
                            .foregroundStyle(WP.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(topic.answer)
                            .font(WP.Font.fredoka(17, .regular, relativeTo: .body))
                            .foregroundStyle(WP.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.top, WP.Space.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(WP.paper.ignoresSafeArea())
    }
}

// MARK: - About (B15.8)

struct WPAboutV2: View {
    let version: String
    let onBack: () -> Void
    let onSources: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WPSheetTitleBar(title: "About", closeLabel: "Back", onClose: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.s3) {
                    Text("WePark")
                        .font(WP.Font.fredoka(36, .bold, relativeTo: .largeTitle))
                        .foregroundStyle(WP.text)
                    Text(WPSettingsLogic.aboutTagline)
                        .font(WP.Font.fredoka(17, .regular, relativeTo: .body))
                        .foregroundStyle(WP.text)
                        .fixedSize(horizontal: false, vertical: true)
                    WPListCard {
                        WPValueRow(title: "Version", value: version, showsChevron: false)
                        WPListDivider()
                        WPListRow(title: "Where the rules come from", trailing: .chevron, action: onSources)
                    }
                    .padding(.top, WP.Space.s2)
                }
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.bottom, WP.Space.s6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(WP.paper.ignoresSafeArea())
    }
}

struct WPRulesSourcesV2: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            WPSheetTitleBar(title: "The rules", closeLabel: "Back", onClose: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.s3) {
                    Text(WPAboutSources.note)
                        .font(WP.Font.fredoka(17, .regular, relativeTo: .body))
                        .foregroundStyle(WP.text)
                        .fixedSize(horizontal: false, vertical: true)
                    WPListCard {
                        ForEach(Array(WPAboutSources.links.enumerated()), id: \.offset) { index, link in
                            if index > 0 { WPListDivider() }
                            if let url = URL(string: link.url) {
                                Link(destination: url) {
                                    HStack(spacing: WP.Space.s3) {
                                        Text(link.title)
                                            .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                                            .foregroundStyle(WP.text)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: WP.Space.s2)
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                                            .foregroundStyle(WP.muted)
                                            .accessibilityHidden(true)
                                    }
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, WP.Space.s2)
                                    .frame(maxWidth: .infinity, minHeight: WPListMetrics.rowMinHeight, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.bottom, WP.Space.s6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(WP.paper.ignoresSafeArea())
    }
}

// MARK: - What the colors mean (B15.6)

struct WPColorsMeanV2: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            WPSheetTitleBar(title: "What the colors mean") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: WP.Space.s3) {
                    WPSectionHeader(text: WPColorsCopy.mapHeader)
                    WPListCard {
                        lineRow(.park, title: WPColorsCopy.parkTitle, sub: WPColorsCopy.parkSub)
                        WPListDivider()
                        lineRow(.dont, title: WPColorsCopy.dontTitle, sub: WPColorsCopy.dontSub)
                    }
                    WPSectionHeader(text: WPColorsCopy.detailHeader)
                        .padding(.top, WP.Space.s2)
                    WPListCard {
                        ForEach(Array(WPColorsCopy.detailRows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { WPListDivider() }
                            detailRow(row.kind, label: row.label)
                        }
                    }
                    WPSectionHeader(text: WPColorsCopy.pinsHeader)
                        .padding(.top, WP.Space.s2)
                    WPChipFlowLayout {
                        ForEach(WPColorsCopy.pinLabels, id: \.self) { WPInfoChip(text: $0) }
                    }
                }
                .padding(.horizontal, WP.Space.screenMargin)
                .padding(.bottom, WP.Space.s6)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(WP.paper.ignoresSafeArea())
    }

    private func lineRow(_ kind: CurbLineKind, title: String, sub: String) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s2))
            : AnyLayout(HStackLayout(spacing: WP.Space.s4))
        return layout {
            WPCurbSample(kind: kind).frame(width: 64, height: 8).accessibilityHidden(true)
            (Text(title).font(WP.Font.fredoka(17, .bold, relativeTo: .body))
                + Text(" \u{00B7} \(sub)").font(WP.Font.fredoka(17, .regular, relativeTo: .body)))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, WP.Space.s3)
        .frame(maxWidth: .infinity, minHeight: WPListMetrics.rowMinHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func detailRow(_ kind: CurbLineKind, label: String) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WP.Space.s2))
            : AnyLayout(HStackLayout(spacing: WP.Space.s4))
        return layout {
            WPCurbSample(kind: kind).frame(width: 64, height: 8).accessibilityHidden(true)
            Text(label)
                .font(WP.Font.fredoka(17, .bold, relativeTo: .body))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, WP.Space.s3)
        .frame(maxWidth: .infinity, minHeight: WPListMetrics.rowMinHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
