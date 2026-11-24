//
//  SpotPassBadgeView.swift
//  Views/SpotPass
//
//  Spot Pass C1: the seeker's full-screen badge (`docs/design/spot-pass-design.md` §2). One layout,
//  two phases: OPEN (the QR is the hero) and ARMED (a neighbor scanned: the QR is replaced by the
//  alias glyph and a coarse "Leaving in about 30 min" band; a dead QR must never stay visible).
//
//  The badge's reader is the SCANNER, not the owner: headline copy is large and capped at xxxLarge
//  (it is a sign for a stranger 0.5 to 1 m away); everything the seeker reads scales to AX5.
//  Posture ("hold it up to your window"): screen stays awake and bright while the QR shows
//  (`SpotPassScreenController`), and a success haptic fires when the pass is scanned
//  (`SpotPassSeekerStore`), because the seeker cannot see their own screen.
//
//  Layouts: iPhone 17 portrait (full card with wordmark header), short screens like iPhone SE
//  (header dropped, karma chip moves into the alias row), landscape (plate left, info right).
//  The module stays 8 pt everywhere: chrome shrinks, the QR never does.
//

import SwiftUI
import UserNotifications

struct SpotPassBadgeView: View {

    let store: SpotPassSeekerStore
    let session: SpotPassSession
    /// "Done": closes the screen; the pass stays active.
    let onDone: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var controller = SpotPassScreenController()
    @State private var night = SpotPassPreferences().nightMode
    @State private var appeared = false
    @State private var notificationsDenied = false

    var body: some View {
        GeometryReader { proxy in
            let short = proxy.size.height < SpotPassTheme.shortScreenHeight
            let landscape = verticalSizeClass == .compact
            let pinned = Self.pinsStopButton(short: short, landscape: landscape, dynamicTypeSize: dynamicTypeSize)
            ScrollView {
                VStack(spacing: 16) {
                    Group {
                        if landscape {
                            landscapeContent
                        } else {
                            portraitContent(short: short)
                        }
                    }
                    // F5: when there is not room to pin the button, it is the last item of the
                    // scrolling content, so it can never cover the alias or the countdown.
                    if !landscape && !pinned {
                        stopButton(short: short)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                // When pinned, leave room under the content for the bar so nothing rests behind it.
                .padding(.bottom, pinned ? (short ? 20 : 12) : 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .top, spacing: 0) { topRow }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if pinned {
                    stopButton(short: short)
                        .padding(.horizontal, 16)
                        .padding(.top, short ? 12 : 8)
                        .padding(.bottom, short ? 12 : 8)
                        .frame(maxWidth: .infinity)
                        .background(SpotPassTheme.ink)
                }
            }
        }
        .spotPassBackdrop()
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85)) {
                appeared = true
            }
            syncScreen()
        }
        .onChange(of: store.phase) { _, _ in syncScreen() }
        .onChange(of: scenePhase) { _, newPhase in
            syncScreen()
            if newPhase == .active { Task { await refreshNotificationStatus() } }
        }
        .onDisappear { controller.end() }
        .task { await refreshNotificationStatus() }
    }

    /// F5: pin "Stop waiting" to the bottom only when the card and the button both fit. At
    /// accessibility sizes, and on short screens at large sizes, the card is taller than the
    /// screen, so the button joins the scrolling content instead of covering it.
    nonisolated static func pinsStopButton(short: Bool, landscape: Bool, dynamicTypeSize: DynamicTypeSize) -> Bool {
        if landscape { return false }
        if dynamicTypeSize.isAccessibilitySize { return false }
        if short && dynamicTypeSize >= .xxLarge { return false }
        return true
    }

    // MARK: - Pieces

    private var isArmed: Bool { store.phase == .armed }

    /// Design §2.1 top row: Done (text, 44 x 56 hit area) left; share (VoiceOver only) and the
    /// brightness toggle right.
    private var topRow: some View {
        HStack {
            SpotPassTextButton(
                title: "Done",
                minHeight: SpotPassTheme.buttonHeight,
                accessibilityHint: "Closes the pass screen. Your Spot Pass stays active.",
                action: onDone
            )
            Spacer()
            if voiceOverEnabled, let url = SpotPassQR.url(token: session.token) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: SpotPassTheme.buttonHeight, height: SpotPassTheme.buttonHeight)
                }
                .accessibilityLabel("Share link")
                .accessibilityHint("Sends this pass link to a neighbor.")
            }
            if store.phase == .open { brightnessButton }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: SpotPassTheme.buttonHeight)
        .background(SpotPassTheme.ink)
    }

    private var brightnessButton: some View {
        Button {
            night.toggle()
            SpotPassPreferences().nightMode = night
            syncScreen(nightChanged: true)
        } label: {
            Image(systemName: night ? "moon.fill" : "sun.max.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: SpotPassTheme.buttonHeight, height: SpotPassTheme.buttonHeight)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Screen brightness")
        .accessibilityValue(night ? "Night" : "Maximum")
        .accessibilityAddTraits(.isButton)
    }

    private func stopButton(short: Bool) -> some View {
        Button {
            Task { await store.stopWaiting() }
        } label: {
            Text("Stop waiting")
        }
        .buttonStyle(SpotPassButtonStyle(kind: .secondary, minHeight: short ? 52 : SpotPassTheme.buttonHeight))
        .accessibilityHint("Ends your Spot Pass. A neighbor who scanned will not be told.")
    }

    // MARK: Portrait

    private func portraitContent(short: Bool) -> some View {
        VStack(spacing: 16) {
            card(short: short)
            if notificationsDenied { deniedBanner }
            if store.phase == .open, Self.isNightHour(Date()) { nightTip }
        }
    }

    private func card(short: Bool) -> some View {
        let padding: CGFloat = short ? 11 : 20
        return VStack(alignment: .leading, spacing: short ? 8 : 12) {
            Group {
                if !short { header }
                signBlock(short: short)
            }
            .modifier(BadgeEntrance(appeared: appeared, reduceMotion: reduceMotion))

            plate
                .frame(maxWidth: .infinity)

            Group {
                aliasRow(short: short)
                statusRow
            }
            .modifier(BadgeEntrance(appeared: appeared, reduceMotion: reduceMotion))
        }
        .padding(padding)
        .frame(maxWidth: .infinity)
        .background(SpotPassTheme.cardGradient, in: RoundedRectangle(cornerRadius: SpotPassTheme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SpotPassTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(SpotPassTheme.lavender.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cardAccessibilityLabel)
    }

    /// Wordmark left, karma bucket chip right (design §2.1 header, 56 pt).
    private var header: some View {
        HStack {
            Label("WePark", systemImage: "mappin.circle.fill")
                .font(.headline)
                .foregroundStyle(.white)
                // F5: never break the wordmark mid-word at large text sizes.
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            Spacer()
            KarmaChip(label: store.karmaBucketLabel, compact: dynamicTypeSize.isAccessibilitySize)
        }
        .frame(minHeight: 36)
    }

    /// The sign headline (design §2.3, §9.3). OPEN: "Leaving soon? / Scan to pass me your spot."
    /// ARMED: "A neighbor's on it." plus the coarse band, refreshed every 30 s.
    @ViewBuilder
    private func signBlock(short: Bool) -> some View {
        if isArmed {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                SpotPassSign(
                    line1: SpotPassCopy.armedHeadline,
                    line2: armedLine(at: context.date),
                    compact: short
                )
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        } else {
            SpotPassSign(line1: SpotPassCopy.signLine1, line2: SpotPassCopy.signLine2, compact: short)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
    }

    private func armedLine(at date: Date) -> String {
        guard let leaveAt = store.leaveAt else { return SpotPassCopy.armedFallbackLine }
        return SpotPassCountdown.band(leaveAt: leaveAt, expiresAt: store.expiresAt, now: date).line
    }

    /// The 328 pt plate. OPEN: the live QR. ARMED: the alias glyph with a check seal at the same
    /// size so nothing jumps (design §2.5).
    @ViewBuilder
    private var plate: some View {
        if isArmed {
            RoundedRectangle(cornerRadius: SpotPassTheme.plateCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 328, height: 328)
                .overlay {
                    AliasGlyphDisc(
                        symbolName: SpotPassGlyph.symbolName(for: session.glyph),
                        tintIndex: SpotPassGlyph.tintIndex(for: session.id),
                        size: 220,
                        showsCheckSeal: true
                    )
                }
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("A neighbor scanned your Spot Pass.")
        } else {
            SpotPassQRView(token: session.token)
        }
    }

    /// Glyph disc + alias (capped at xxxLarge on the card; the full alias is in the VoiceOver label).
    private func aliasRow(short: Bool) -> some View {
        HStack(spacing: 12) {
            AliasGlyphDisc(
                symbolName: SpotPassGlyph.symbolName(for: session.glyph),
                tintIndex: SpotPassGlyph.tintIndex(for: session.id),
                size: short ? 44 : 52
            )
            .overlay { PulseRing(size: short ? 44 : 52, animates: !reduceMotion && !isArmed) }
            Text(session.shownName)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            if short {
                KarmaChip(label: store.karmaBucketLabel, compact: dynamicTypeSize.isAccessibilitySize)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.shownName), \(SpotPassGlyph.symbolName(for: session.glyph).replacingOccurrences(of: ".fill", with: "")) glyph")
    }

    /// OPEN: "Spot Pass · good for 19:42" + a 6 pt TTL bar. ARMED: the courtesy line.
    @ViewBuilder
    private var statusRow: some View {
        if isArmed {
            Text(SpotPassCopy.courtesyLine)
                .font(.footnote)
                .foregroundStyle(SpotPassTheme.lavender)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = SpotPassCountdown.remaining(until: session.expiresAt, now: context.date)
                    let ending = SpotPassCountdown.isEnding(remaining)
                    Text(ending
                         ? "Ends in \(SpotPassCountdown.clockString(remaining))"
                         : "Spot Pass \u{00B7} good for \(SpotPassCountdown.clockString(remaining))")
                        .font(.subheadline.weight(ending ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(SpotPassTheme.lavender)
                        .accessibilityLabel("Good for \(SpotPassCountdown.spokenString(remaining))")
                }
                ProgressView(
                    timerInterval: SpotPassCountdown.safeRange(from: session.createdAt, to: session.expiresAt),
                    countsDown: true
                ) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear)
                    .tint(SpotPassTheme.lavender)
                    .accessibilityHidden(true)
            }
        }
    }

    private var cardAccessibilityLabel: String {
        if isArmed { return "Spot Pass for \(session.shownName). A neighbor is on it." }
        let remaining = SpotPassCountdown.remaining(until: session.expiresAt, now: Date())
        return "Spot Pass for \(session.shownName). Good for \(SpotPassCountdown.spokenString(remaining))."
    }

    // MARK: Landscape (design §2.6: header hidden, Stop in a trailing column, plate stays 328)

    private var landscapeContent: some View {
        HStack(alignment: .center, spacing: 24) {
            plate
            VStack(alignment: .leading, spacing: 12) {
                signBlock(short: true)
                aliasRow(short: true)
                statusRow
                if notificationsDenied { deniedBanner }
                stopButton(short: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Banners

    /// Design §9.5: notifications denied. The poll still works while this screen is open.
    private var deniedBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(SpotPassCopy.notificationsOffBanner)
                .font(.body)
                .foregroundStyle(.white)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(SpotPassButtonStyle(kind: .secondary))
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var nightTip: some View {
        Text(SpotPassCopy.nightTip)
            .font(.footnote)
            .foregroundStyle(SpotPassTheme.lavender)
    }

    // MARK: Behavior

    /// Local time between 8 pm and 6 am (design §2.6: the tip appears only then).
    static func isNightHour(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 20 || hour < 6
    }

    private func syncScreen(nightChanged: Bool = false) {
        controller.apply(
            boost: SpotPassBrightnessPolicy.shouldBoost(phase: store.phase, isSceneActive: scenePhase == .active),
            night: night,
            nightChanged: nightChanged
        )
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDenied = settings.authorizationStatus == .denied
    }
}

// MARK: - Sign headline

/// The sign a stranger reads: heavy rounded line 1, semibold lavender line 2. The caller caps
/// Dynamic Type at xxxLarge on this view (design §2.3); `@ScaledMetric` here sees that cap.
struct SpotPassSign: View {
    let line1: String
    let line2: String
    var compact = false

    @ScaledMetric(relativeTo: .largeTitle) private var line1Size: CGFloat = 34
    @ScaledMetric(relativeTo: .title2) private var line2Size: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line1)
                .font(.system(size: compact ? line1Size * 28 / 34 : line1Size, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text(line2)
                .font(.system(size: compact ? line2Size * 20 / 22 : line2Size, weight: .semibold, design: .rounded))
                .foregroundStyle(SpotPassTheme.lavender)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Motion

/// Chrome entrance: translateY +24 to 0 and fade (design §2.9). The QR plate is NOT inside this
/// modifier: it is composited at final size and fully opaque before anything moves (a camera may
/// catch it mid-animation). Reduce Motion: a plain crossfade.
private struct BadgeEntrance: ViewModifier {
    let appeared: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: (appeared || reduceMotion) ? 0 : 24)
    }
}

/// The waiting pulse on the alias glyph (design §2.9: scale 1.0 to 1.12, opacity .5 to 0, 2.4 s loop).
/// Static ring under Reduce Motion.
struct PulseRing: View {
    let size: CGFloat
    let animates: Bool

    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(SpotPassTheme.lavender.opacity(animates ? (expanded ? 0 : 0.5) : 0.35), lineWidth: 2)
            .frame(width: size, height: size)
            .scaleEffect(animates && expanded ? 1.12 : 1)
            .onAppear {
                guard animates else { return }
                withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
            .accessibilityHidden(true)
    }
}
