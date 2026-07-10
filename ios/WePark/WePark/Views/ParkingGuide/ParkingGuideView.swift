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
}

// MARK: - ParkingGuideView

struct ParkingGuideView: View {

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    subtitleRow

                    quickJumpChipRow(proxy: proxy)
                        .padding(.bottom, 24)

                    ForEach(ParkingGuideSection.allCases) { section in
                        guideSection(section)
                            .id(section.anchorID)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Parking 101")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Subtitle

    private var subtitleRow: some View {
        Text("Free parking in NYC is doable. Here's how.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 16)
    }

    // MARK: - Quick-jump chip row

    private func quickJumpChipRow(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ParkingGuideSection.allCases) { section in
                    Button {
                        withAnimation {
                            proxy.scrollTo(section.anchorID, anchor: .top)
                        }
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
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
            Label(section.title, systemImage: section.symbol)
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.bottom, 2)

            switch section {
            case .pitch:          PitchSectionView()
            case .signSchool:     SignSchoolSectionView()
            case .colorLegend:    ColorLegendSectionView()
            case .rookieMistakes: RookieMistakesSectionView()
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
