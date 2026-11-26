//
//  WPSpotPassSeekerV2.swift
//  Views/SpotPass
//
//  Stoop Phase 5a: the round-2 skin (B9) of the in-app Spot Pass SEEKER screens. Shown only while
//  `AppConstants.designSystemV2Enabled` (and, as before, `spotHandoffEnabled`). Every view here is
//  a pure leaf: plain values and closures in, no store, no network. `SpotPassFlowView` and
//  `SpotPassBadgeView` keep ALL the behavior (create, poll, brightness, outcome) and only choose
//  which look to draw, so flag-off draws the old dark screens exactly as before.
//
//  Rules: cream ground (adaptive in dark), ink text, taxi only for the thing you press. No parking
//  green anywhere on a pass screen: green means "you can park" in this app, and a pass says nothing
//  about the curb ("Check the signs before you park"). The QR stays on its opaque white plate.
//  Every control is at least 48 pt; text wraps instead of truncating through AX5.
//

import SwiftUI

// MARK: - Small shared pieces

/// Labeled tuples for `WPScreenScaffold`'s `primary` / `secondary` (a plain tuple literal with a
/// leading-dot kind does not infer through the optional labeled tuple).
func wpPassPrimary(
    _ title: String, _ kind: WPPrimaryKind, _ action: @escaping () -> Void
) -> (title: String, kind: WPPrimaryKind, action: () -> Void) {
    (title: title, kind: kind, action: action)
}

func wpPassSecondary(
    _ title: String, _ action: @escaping () -> Void
) -> (title: String, action: () -> Void) {
    (title: title, action: action)
}

/// White card, 1.5 line, radius 20: one fact or one group of rows.
struct WPPassBox<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WP.Radius.tile, style: .continuous)
        VStack(alignment: .leading, spacing: 2, content: content)
            .padding(.horizontal, WP.Space.s4)
            .padding(.vertical, WP.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(WP.card))
            .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.fact))
    }
}

/// A bold line over a lighter explanation, in a box.
struct WPPassNote: View {
    let title: String
    var body_: String? = nil

    var body: some View {
        WPPassBox {
            Text(title)
                .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                .foregroundStyle(WP.text)
                .fixedSize(horizontal: false, vertical: true)
            if let body_ {
                Text(body_)
                    .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Static karma chip (taxi, 2.5 line, raised 3). Earned, so it is raised; not a button.
struct WPPassKarmaTag: View {
    let label: String

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(wpHex: WP.Hex.noParkText))
                .accessibilityHidden(true)
            Text(label)
                .font(WP.Font.fredoka(15, .bold, relativeTo: .callout))
                .foregroundStyle(WP.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, WP.Space.s4)
        .padding(.vertical, WP.Space.s2)
        .frame(minHeight: WP.Control.chipHeight)
        .background(shape.fill(WP.taxi))
        .overlay(shape.strokeBorder(WP.ink, lineWidth: WP.Border.control))
        .background(shape.fill(WP.shadow).offset(y: WP.Raise.sm))
        .padding(.bottom, WP.Raise.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

// MARK: - B9.1 intro

struct WPSeekerIntroV2: View {
    /// The seeker's first name if one is on file (enables the toggle), else nil.
    let firstName: String?
    @Binding var showFirstName: Bool
    let onCreate: () -> Void
    let onClose: () -> Void

    private var toggleEnabled: Bool { firstName != nil }

    private var helper: String {
        if !toggleEnabled { return SpotPassCopy.showFirstNameDisabled }
        return showFirstName ? SpotPassCopy.showFirstNameOn : SpotPassCopy.showFirstNameOff
    }

    var body: some View {
        WPScreenScaffold(
            onClose: onClose,
            over: WPPassCopy.seekerOver,
            title: WPPassCopy.seekerTitle,
            sub: WPPassCopy.seekerSub,
            primary: wpPassPrimary(WPPassCopy.makePass, .commitment, onCreate),
            secondary: wpPassSecondary(WPPassCopy.notNow, onClose)
        ) {
            WPListCard {
                ForEach(Array(WPPassCopy.seekerSteps.enumerated()), id: \.offset) { index, step in
                    if index > 0 { WPListDivider() }
                    HStack(alignment: .center, spacing: WP.Space.s3) {
                        Text("\(index + 1)")
                            .font(WP.Font.fredoka(17, .bold, relativeTo: .body))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(WP.ink))
                            .accessibilityHidden(true)
                        Text(step)
                            .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                            .foregroundStyle(WP.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, WP.Space.s3)
                    .frame(minHeight: WPListMetrics.rowMinHeight)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(index + 1). \(step)")
                }
            }
            WPPassNote(title: WPPassCopy.privacyTitle, body_: WPPassCopy.privacyBody)
            // Existing behavior, restyled: the opt-in first name (OFF by default; disabled with a
            // helper line while no first name is on file).
            WPListCard {
                WPListToggleRow(title: SpotPassCopy.showFirstName, subtitle: helper, isOn: $showFirstName)
                    .disabled(!toggleEnabled)
            }
            Text(SpotPassCopy.explainerPosture)
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                .foregroundStyle(WP.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Creating / failed (B9.9 for the failed case)

struct WPSeekerMessageV2: View {
    let title: String
    var body_: String? = nil
    /// Primary action (taxi when it starts something), nil for a plain "Done" screen.
    var primary: (title: String, action: () -> Void)? = nil
    var secondary: (title: String, action: () -> Void)? = nil
    var showsSpinner = false
    var onClose: (() -> Void)? = nil

    var body: some View {
        WPScreenScaffold(
            onClose: onClose,
            over: WPPassCopy.seekerOver,
            title: title,
            sub: body_,
            primary: primary.map { wpPassPrimary($0.title, .commitment, $0.action) },
            secondary: secondary.map { wpPassSecondary($0.title, $0.action) }
        ) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.large)
                    .tint(WP.ink)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .accessibilityLabel(title)
            } else {
                WPHollowToken()
                    .frame(maxWidth: .infinity, minHeight: 96)
            }
        }
    }
}

// MARK: - B9.5 departed ("Go to the spot")

struct WPSeekerDepartedV2: View {
    let glyphSymbol: String
    let tintIndex: Int
    let isSubmitting: Bool
    let submitFailed: Bool
    let onGotIt: () -> Void
    let onDidntWorkOut: () -> Void

    var body: some View {
        WPScreenScaffold(
            over: WPPassCopy.seekerOver,
            title: WPPassCopy.departedTitle,
            primary: wpPassPrimary(SpotPassCopy.gotIt, .commitment, onGotIt),
            secondary: wpPassSecondary(SpotPassCopy.didntWorkOut, onDidntWorkOut)
        ) {
            // The headline fact. Ink-outlined, not green: this card says the neighbor is leaving,
            // never that the curb is legal.
            VStack(alignment: .leading, spacing: 4) {
                Text(WPPassCopy.departedOver)
                    .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
                Text(WPPassCopy.departedBig)
                    .font(WP.Font.fredoka(44, .bold, relativeTo: .largeTitle))
                    .fixedSize(horizontal: false, vertical: true)
                Text(SpotPassCopy.departedSubtitle)
                    .font(WP.Font.fredoka(15, .medium, relativeTo: .callout))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(WP.text)
            .padding(WP.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous).fill(WP.card))
            .overlay(
                RoundedRectangle(cornerRadius: WP.Radius.card, style: .continuous)
                    .strokeBorder(WP.line, lineWidth: WP.Border.raised)
            )
            .accessibilityElement(children: .combine)

            WPPassNote(title: WPPassCopy.departedNote, body_: WPPassCopy.departedNoteBody)
            Text(SpotPassCopy.departedSafety)
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                .foregroundStyle(WP.muted)
                .fixedSize(horizontal: false, vertical: true)
            if submitFailed {
                Text(SpotPassCopy.outcomeSubmitFailed)
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .foregroundStyle(WP.text)
            }
        }
        .disabled(isSubmitting)
    }
}

// MARK: - B9.6 settled ("Thanks sent")

struct WPSeekerSettledV2: View {
    let gotSpot: Bool
    /// The real receipt ("+3 karma"), already worded by `SpotPassCopy`; nil when there is none.
    let karmaReceipt: String?
    let onKeepLooking: () -> Void
    let onDone: () -> Void

    var body: some View {
        WPScreenScaffold(
            over: WPPassCopy.seekerOver,
            title: gotSpot ? SpotPassCopy.thanksTitle : SpotPassCopy.noLuckTitle,
            sub: gotSpot ? SpotPassCopy.thanksSubtitle : nil,
            primary: gotSpot
                ? wpPassPrimary(SpotPassCopy.done, .navigation, onDone)
                : wpPassPrimary(SpotPassCopy.keepLooking, .commitment, onKeepLooking),
            secondary: gotSpot ? nil : wpPassSecondary(SpotPassCopy.done, onDone)
        ) {
            if gotSpot { WPSpotPassedStamp().padding(.vertical, WP.Space.s3) }
            if let karmaReceipt { WPPassKarmaTag(label: karmaReceipt) }
        }
    }
}

// MARK: - B9.7 / B9.9 ended

struct WPSeekerEndedV2: View {
    let isPaused: Bool
    let onMakeNew: () -> Void
    let onDone: () -> Void

    var body: some View {
        WPScreenScaffold(
            over: WPPassCopy.seekerOver,
            title: isPaused ? SpotPassCopy.passPaused : SpotPassCopy.passEnded,
            primary: isPaused
                ? wpPassPrimary(SpotPassCopy.done, .navigation, onDone)
                : wpPassPrimary(SpotPassCopy.makeNewPass, .commitment, onMakeNew),
            secondary: isPaused ? nil : wpPassSecondary(SpotPassCopy.done, onDone)
        ) {
            WPHollowToken().frame(maxWidth: .infinity, minHeight: 96)
        }
    }
}

// MARK: - B9.3 / B9.4 badge

/// What the badge shows. Plain values, so the showcase can draw it without a store.
struct WPBadgeModel {
    var token: String
    var shownName: String
    var glyphSymbol: String
    var tintIndex: Int
    var karmaLabel: String
    var isArmed: Bool
    var createdAt: Date
    var expiresAt: Date
    /// The coarse "Leaving in about 30 min" band for the armed state, computed by the caller.
    var armedLine: (Date) -> String
}

struct WPSeekerBadgeV2: View {
    let model: WPBadgeModel
    let night: Bool
    let showsBrightness: Bool
    let notificationsDenied: Bool
    let showsNightTip: Bool
    /// Pin "Stop waiting" under the scroll only when card and button both fit (the legacy rule).
    let pinsStop: Bool
    let shareURL: URL?
    let onDone: () -> Void
    let onToggleNight: () -> Void
    let onStop: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let landscape = verticalSizeClass == .compact
        ScrollView {
            VStack(spacing: WP.Space.s3) {
                if landscape {
                    HStack(alignment: .center, spacing: WP.Space.s5) {
                        plate
                        VStack(alignment: .leading, spacing: WP.Space.s3) {
                            sign
                            aliasRow
                            statusRow
                            extras
                            stopButton
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    card
                    extras
                    if !pinsStop { stopButton }
                }
            }
            .padding(.horizontal, WP.Space.screenMargin)
            .padding(.top, WP.Space.s2)
            .padding(.bottom, WP.Space.s3)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .top, spacing: 0) { topRow }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pinsStop && !landscape {
                stopButton
                    .padding(.horizontal, WP.Space.screenMargin)
                    .padding(.vertical, WP.Space.s2)
                    .background(WP.paper)
            }
        }
        .background(WP.paper.ignoresSafeArea())
    }

    // MARK: Pieces

    private var topRow: some View {
        HStack(spacing: WP.Space.s2) {
            Button("Done", action: onDone)
                .buttonStyle(WPPassTextButtonStyle())
                .accessibilityHint("Closes the pass screen. Your Spot Pass stays active.")
            Spacer(minLength: WP.Space.s2)
            if let shareURL {
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(WP.text)
                        .frame(width: WP.Target.minimum, height: WP.Target.minimum)
                }
                .accessibilityLabel("Share link")
                .accessibilityHint("Sends this pass link to a neighbor.")
            }
            if showsBrightness {
                Button(night ? "Brighter" : "Dimmer", action: onToggleNight)
                    .buttonStyle(WPClosePillStyle())
                    .accessibilityLabel("Screen brightness")
                    .accessibilityValue(night ? "Night" : "Maximum")
            }
        }
        .padding(.horizontal, WP.Space.screenMargin)
        .padding(.top, WP.Space.s2)
        .padding(.bottom, WP.Space.s2)
        .background(WP.paper)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return VStack(alignment: .leading, spacing: WP.Space.s3) {
            sign
            plate.frame(maxWidth: .infinity)
            aliasRow
            statusRow
        }
        .padding(WP.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(WP.card))
        .overlay(shape.strokeBorder(WP.line, lineWidth: WP.Border.control))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cardLabel)
    }

    /// The sign a stranger reads (capped at xxxLarge: it is held up 0.5 to 1 m from a scanner).
    @ViewBuilder private var sign: some View {
        Group {
            if model.isArmed {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    signText(line1: SpotPassCopy.armedHeadline, line2: model.armedLine(context.date))
                }
            } else {
                signText(line1: SpotPassCopy.signLine1, line2: SpotPassCopy.signLine2)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func signText(line1: String, line2: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line1)
                .font(WP.Font.fredoka(36, .bold, relativeTo: .largeTitle))
                .foregroundStyle(WP.text)
            Text(line2)
                .font(WP.Font.fredoka(20, .semibold, relativeTo: .title3))
                .foregroundStyle(WP.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// OPEN: the live QR on its opaque white plate. ARMED: the alias glyph with a check seal at the
    /// same size, so a dead QR never stays on screen.
    @ViewBuilder private var plate: some View {
        if model.isArmed {
            RoundedRectangle(cornerRadius: SpotPassTheme.plateCornerRadius, style: .continuous)
                .fill(WP.lifted)
                .overlay(
                    RoundedRectangle(cornerRadius: SpotPassTheme.plateCornerRadius, style: .continuous)
                        .strokeBorder(WP.line, lineWidth: WP.Border.fact)
                )
                .frame(width: 328, height: 328)
                .overlay {
                    AliasGlyphDisc(symbolName: model.glyphSymbol, tintIndex: model.tintIndex, size: 220, showsCheckSeal: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("A neighbor scanned your Spot Pass.")
        } else {
            SpotPassQRView(token: model.token)
        }
    }

    private var aliasRow: some View {
        HStack(spacing: WP.Space.s3) {
            AliasGlyphDisc(symbolName: model.glyphSymbol, tintIndex: model.tintIndex, size: 52)
            Text(model.shownName)
                .font(WP.Font.fredoka(28, .bold, relativeTo: .title))
                .foregroundStyle(WP.text)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            WPPassKarmaTag(label: model.karmaLabel)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.shownName), \(model.karmaLabel)")
    }

    @ViewBuilder private var statusRow: some View {
        if model.isArmed {
            Text(SpotPassCopy.courtesyLine)
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                .foregroundStyle(WP.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: WP.Space.s2) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = SpotPassCountdown.remaining(until: model.expiresAt, now: context.date)
                    let ending = SpotPassCountdown.isEnding(remaining)
                    HStack(alignment: .firstTextBaseline) {
                        Text(WPPassCopy.waitingForScan)
                        Spacer(minLength: WP.Space.s2)
                        Text(ending
                             ? "Ends in \(SpotPassCountdown.clockString(remaining))"
                             : "Good for \(SpotPassCountdown.clockString(remaining))")
                            .monospacedDigit()
                    }
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .foregroundStyle(WP.text)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Waiting for a scan. Good for \(SpotPassCountdown.spokenString(remaining))")
                }
                ProgressView(
                    timerInterval: SpotPassCountdown.safeRange(from: model.createdAt, to: model.expiresAt),
                    countsDown: true
                ) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear)
                    .tint(WP.ink)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var extras: some View {
        if notificationsDenied {
            WPPassBox {
                Text(SpotPassCopy.notificationsOffBanner)
                    .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.wpSecondary)
                .padding(.top, WP.Space.s2)
            }
        }
        if showsNightTip {
            Text(SpotPassCopy.nightTip)
                .font(WP.Font.fredoka(15, .regular, relativeTo: .callout))
                .foregroundStyle(WP.muted)
        }
    }

    private var stopButton: some View {
        Button(SpotPassCopy.stopWaiting, action: onStop)
            .buttonStyle(.wpSecondary)
            .accessibilityHint("Ends your Spot Pass. A neighbor who scanned will not be told.")
    }

    private var cardLabel: String {
        if model.isArmed { return "Spot Pass for \(model.shownName). A neighbor is on it." }
        let remaining = SpotPassCountdown.remaining(until: model.expiresAt, now: Date())
        return "Spot Pass for \(model.shownName). Good for \(SpotPassCountdown.spokenString(remaining))."
    }
}

/// A plain text button, 48 pt minimum, for "Done" in a top row.
struct WPPassTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WP.Font.fredoka(17, .semibold, relativeTo: .body))
            .foregroundStyle(WP.text)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .frame(minWidth: WP.Target.minimum, minHeight: WP.Target.minimum, alignment: .leading)
            .contentShape(Rectangle())
    }
}
