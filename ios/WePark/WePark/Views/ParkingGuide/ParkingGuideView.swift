//
//  ParkingGuideView.swift
//  WePark
//
//  FT-12 (docs/ft12-beginners-manual-spec.md): "Free Parking in NYC 101" — a dedicated
//  beginner's guide, distinct from the flat Q&A shape of FAQHelpView (OQ-1).
//
//  Content source of truth: docs/parking-101-content.md. This file renders that copy
//  faithfully across four sections — Pitch, Sign School, Color Legend, Rookie Mistakes —
//  each reachable via a top quick-jump chip row (ScrollViewReader + section anchors),
//  since this screen runs longer than FAQHelpView.
//
//  Entry points: SettingsView "Parking 101" row (above "Help & FAQ"), the FAQHelpView
//  cross-link (OQ-6), and the first-launch ParkingGuidePromptBanner (OQ-2).
//
//  Kept thin per the W8.5c-polish PR-1 precedent — content lives in the four extracted
//  section subviews, not inline here.
//

import SwiftUI

// MARK: - ParkingGuideSection

/// The four sections of the guide, in display order. Drives both the quick-jump chip
/// row and the ScrollViewReader anchor IDs. Pure value type — no SwiftUI/UIKit
/// dependency required to unit test the anchor-ID mapping.
enum ParkingGuideSection: String, CaseIterable, Identifiable {
    case pitch
    case signSchool
    case colorLegend
    case rookieMistakes

    var id: String { anchorID }

    /// The ScrollViewReader anchor ID for this section.
    var anchorID: String { rawValue }

    /// Chip label / section header title.
    var title: String {
        switch self {
        case .pitch:          return "The Pitch"
        case .signSchool:     return "Sign School"
        case .colorLegend:    return "Map Colors"
        case .rookieMistakes: return "Rookie Mistakes"
        }
    }

    /// SF Symbol for the section header.
    var symbol: String {
        switch self {
        case .pitch:          return "dollarsign.circle"
        case .signSchool:     return "signpost.right.and.left"
        case .colorLegend:    return "paintpalette"
        case .rookieMistakes: return "exclamationmark.triangle"
        }
    }

    /// VoiceOver label for the quick-jump chip (spec §11: "Jump to Sign School").
    var jumpAccessibilityLabel: String { "Jump to \(title)" }

    /// The sections drawn. Stoop leaves out the five-color legend: it describes the legacy orange
    /// and amber map colors, which the Stoop map does not draw (it is red or green only, so a legend
    /// with five colors would teach colors the driver never sees). Flag off: all four, unchanged.
    nonisolated static func visible(stoop: Bool) -> [ParkingGuideSection] {
        stoop ? allCases.filter { $0 != .colorLegend } : allCases
    }
}

// MARK: - ParkingGuideView

struct ParkingGuideView: View {

    private var stoop: Bool { AppConstants.designSystemV2Enabled }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    subtitleRow

                    quickJumpChipRow(proxy: proxy)
                        .padding(.bottom, 24)

                    ForEach(ParkingGuideSection.visible(stoop: stoop)) { section in
                        guideSection(section)
                            .id(section.anchorID)
                    }
                    if stoop {
                        Text("The sign on the street always wins.")
                            .font(WP.Font.fredoka(18, .semibold, relativeTo: .body))
                            .foregroundStyle(WP.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, WP.Space.s2)
                    }
                }
                .padding(.horizontal, stoop ? WP.Space.screenMargin : 16)
                .padding(.bottom, 32)
            }
            .background { if stoop { WP.paper.ignoresSafeArea() } }
        }
        .navigationTitle("Parking 101")
        .navigationBarTitleDisplayMode(stoop ? .inline : .large)
    }

    // MARK: - Subtitle

    private var subtitleRow: some View {
        Group {
            if stoop {
                Text("Free parking in NYC is doable. Here's how.")
                    .font(WP.Font.fredoka(17, .regular, relativeTo: .body))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Free parking in NYC is doable. Here's how.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // MARK: - Quick-jump chip row

    private func quickJumpChipRow(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ParkingGuideSection.visible(stoop: stoop)) { section in
                    Button {
                        withAnimation {
                            proxy.scrollTo(section.anchorID, anchor: .top)
                        }
                    } label: {
                        if stoop {
                            // Big target (48 pt), words not icons, a 1.5 line like the other round-2 chips.
                            Text(section.title)
                                .font(WP.Font.fredoka(15, .semibold, relativeTo: .callout))
                                .foregroundStyle(WP.text)
                                .padding(.horizontal, WP.Space.s4)
                                .frame(minHeight: WP.Target.minimum)
                                .background(Capsule().fill(WP.card))
                                .overlay(Capsule().strokeBorder(WP.line, lineWidth: WP.Border.fact))
                                .contentShape(Capsule())
                        } else {
                            Label(section.title, systemImage: section.symbol)
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                        }
                    }
                    .accessibilityLabel(section.jumpAccessibilityLabel)
                }
            }
        }
    }

    // MARK: - Section builder

    @ViewBuilder
    private func guideSection(_ section: ParkingGuideSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if stoop {
                Text(section.title)
                    .font(WP.Font.fredoka(24, .bold, relativeTo: .title2))
                    .foregroundStyle(WP.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 2)
            } else {
                Label(section.title, systemImage: section.symbol)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding(.bottom, 2)
            }

            switch section {
            case .pitch:          PitchSectionView().wpGuideCard()
            case .signSchool:     SignSchoolSectionView()
            case .colorLegend:    ColorLegendSectionView()
            case .rookieMistakes: RookieMistakesSectionView().wpGuideCard()
            }
        }
        .padding(.bottom, 28)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ParkingGuideView()
    }
}
