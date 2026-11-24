//
//  ClipChoosingView.swift
//  WePark Clip
//
//  Beat 1 (spec 6.1, design 3.2, 3.3): the first screen. Alias + glyph handshake, leaving-time
//  chips with "10 min" preselected, one huge CTA pinned at the bottom. Nothing is asked before
//  this tap: no sign-in, no notification prompt, no location prompt.
//

import SwiftUI

struct ClipChoosingView: View {
    @Bindable var controller: ClipFlowController
    var onReport: (HandoffReportReason) -> Void

    @Environment(\.clipIsShortScreen) private var isShort
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showPicker = false
    @State private var showReport = false
    @State private var pickedDate = Date()

    private var isArming: Bool { controller.phase == .arming }

    var body: some View {
        ScrollView {
            VStack(spacing: isShort ? 14 : 20) {
                topRow
                ClipGlyphDisc(
                    glyph: controller.glyph, alias: controller.alias,
                    size: typeSize.isAccessibilitySize ? 72 : (isShort ? 64 : 96), floats: true
                )
                .redacted(reason: controller.preview == nil ? .placeholder : [])
                headline
                Text(ClipCopy.subline)
                    .font(isShort ? .callout : .title3)
                    .foregroundStyle(SpotPassTheme.lavender)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                chipsSection
                Text(ClipCopy.consent)
                    .font(.footnote)
                    .foregroundStyle(SpotPassTheme.lavender)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { pinnedCTA }
        .sheet(isPresented: $showPicker) { pickerSheet }
        .confirmationDialog(ClipCopy.reportTitle, isPresented: $showReport, titleVisibility: .visible) {
            ForEach(ClipCopy.reportReasons, id: \.0) { reason, title in
                Button(title) { onReport(reason) }
            }
        }
    }

    // MARK: Pieces

    private var topRow: some View {
        HStack {
            ClipWordmark()
            Spacer()
            Button {
                showReport = true
            } label: {
                Image(systemName: "flag")
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Report this pass")
        }
        .frame(minHeight: 44)
    }

    private var headline: some View {
        Text(ClipCopy.headline(name: controller.preview?.name))
            .font(isShort ? .system(.title, design: .rounded).weight(.bold) : .clipHeadline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 0 : (isShort ? 68 : 88), alignment: .top)
            .accessibilityAddTraits(.isHeader)
            .animation(.easeInOut(duration: 0.25), value: controller.preview?.name)
    }

    private var chipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ClipCopy.chipsLabel)
                .font(.headline)
                .foregroundStyle(.white)
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 10) { allChips }
                } else {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) { chip(.now); chip(.minutes(10)); chip(.minutes(30)) }
                        HStack(spacing: 10) { chip(.minutes(60)); customChip }
                    }
                }
            }
            .disabled(isArming)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ClipCopy.chipsLabel)
    }

    @ViewBuilder private var allChips: some View {
        chip(.now); chip(.minutes(10)); chip(.minutes(30)); chip(.minutes(60)); customChip
    }

    private func chip(_ option: LeaveChoice) -> some View {
        ClipChip(
            title: ClipCopy.chipTitle(option), accessibilityLabel: ClipCopy.chipAccessibilityLabel(option),
            isSelected: controller.choice == option
        ) { controller.select(option) }
    }

    private var customChip: some View {
        let title: String
        if case .custom(let date) = controller.choice {
            title = ClipCopy.clockTime(date)
        } else {
            title = ClipCopy.pickTimeTitle
        }
        return ClipChip(
            title: title, accessibilityLabel: ClipCopy.chipAccessibilityLabel(.custom(Date())),
            isSelected: controller.choice.isCustom, wide: true
        ) {
            pickedDate = max(pickedDate, Date())
            showPicker = true
        }
    }

    private var pinnedCTA: some View {
        VStack(spacing: 6) {
            if let failure = controller.armFailure {
                Text(failure == .busy ? ClipCopy.busyBody : ClipCopy.offlineBody)
                    .font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
            }
            Button {
                Task { await controller.arm() }
            } label: {
                if isArming {
                    ProgressView().tint(SpotPassTheme.ink)
                } else {
                    Text(ClipCopy.cta(choice: controller.choice, name: controller.preview?.name))
                }
            }
            .buttonStyle(ClipHeroButtonStyle())
            .disabled(isArming)
            .accessibilityLabel(ClipCopy.cta(choice: controller.choice, name: controller.preview?.name))
            .accessibilityHint(ClipCopy.consent)
            if !typeSize.isAccessibilitySize {
                Text(ClipCopy.underCTA).font(.footnote).foregroundStyle(SpotPassTheme.lavender)
            }
            SpotPassTextButton(title: ClipCopy.notLeavingSoon) { controller.notLeavingSoon() }
                .disabled(isArming)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial.opacity(0.0))
    }

    private var pickerSheet: some View {
        let range = LeaveChoice.pickableRange(from: Date())
        return VStack(spacing: 16) {
            Text(ClipCopy.pickTimeTitle).font(.title2.bold()).foregroundStyle(.white)
            DatePicker("", selection: $pickedDate, in: range, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .colorScheme(.dark)
            Text(ClipCopy.pickTimeHelper).font(.footnote).foregroundStyle(SpotPassTheme.lavender)
            Button(ClipCopy.pickTimeSet) {
                controller.select(.custom(pickedDate))
                showPicker = false
            }
            .buttonStyle(SpotPassButtonStyle(kind: .paper))
        }
        .padding(20)
        .presentationDetents([.medium])
        .background(SpotPassTheme.ink)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Chip

struct ClipChip: View {
    let title: String
    let accessibilityLabel: String
    let isSelected: Bool
    var wide = false
    let action: () -> Void

    @Environment(\.clipIsShortScreen) private var isShort
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSelected { Image(systemName: "checkmark.circle.fill") }
                Text(title).lineLimit(2).minimumScaleFactor(0.8)
            }
            .font(.headline)
            .foregroundStyle(isSelected ? SpotPassTheme.ink : .white)
            .frame(maxWidth: .infinity, minHeight: isShort ? 52 : SpotPassTheme.buttonHeight)
            .frame(minWidth: 96)
            .background(isSelected ? Color.white : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .layoutPriority(wide ? 1 : 0)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
