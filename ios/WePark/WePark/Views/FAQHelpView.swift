//
//  FAQHelpView.swift
//  WePark
//
//  Help & FAQ screen for beginners — NYC parking basics + how to use WePark +
//  official NYC.gov links.
//
//  Content source of truth: docs/in-app-faq-content.md (on main).
//  Copy is final; this file renders it faithfully.
//
//  Entry point: SettingsView row → NavigationStack push (or sheet, matching
//  SettingsView's NavigationStack context).
//
//  The three NYC.gov links in Section 3 use Link(destination:) to open in Safari.
//  No map, no gestures, no Drive Mode, no overlay chain — safe from #31 risks.
//

import SwiftUI

// MARK: - FAQHelpView

struct FAQHelpView: View {

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Subtitle
                subtitleRow

                // Section 1 — How NYC parking works
                faqSection(
                    symbol: "car.2",
                    title: "How NYC parking works",
                    content: { section1Content }
                )

                // Section 2 — How to use WePark
                faqSection(
                    symbol: "map",
                    title: "How to use WePark",
                    content: { section2Content }
                )

                // Section 3 — Official NYC sources (tappable links)
                section3View

                // Footer disclaimer
                footerDisclaimer
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Help & FAQ")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Subtitle

    private var subtitleRow: some View {
        Text("New to NYC parking? Start here.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 24)
    }

    // MARK: - Generic section builder

    @ViewBuilder
    private func faqSection(
        symbol: String,
        title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {

            // Section header
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.bottom, 2)

            content()
        }
        .padding(.bottom, 28)
    }

    // MARK: - FT-12 (OQ-6): Parking 101 cross-link

    private var parkingGuideCrossLink: some View {
        NavigationLink {
            ParkingGuideView()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "signpost.right.and.left")
                    .imageScale(.small)
                Text("New here? Read the full Parking 101 guide")
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(.tint)
        }
        .accessibilityLabel("New here? Read the full Parking 101 guide")
        .padding(.bottom, 8)
    }

    // MARK: - Section 1 content

    @ViewBuilder
    private var section1Content: some View {
        // FT-12 (OQ-6): cross-link to the Parking 101 guide — a narrative, illustrated
        // onboarding companion to this flat Q&A list.
        parkingGuideCrossLink
        faqItem(
            question: "What is \"alternate side parking\" (ASP)?",
            answer: "On most NYC streets you must move your car off one side at posted days and times so the street sweeper can clean. A sign like \"No Parking — Mon & Thu, 9–10:30 AM\" means: don't park on that side during those hours that day. Move your car before the window starts."
        )
        faqItem(
            question: "What happens if I don't move it?",
            answer: "You'll likely get a street-cleaning ticket (around $65), and in some cases a tow. The sweeper comes during the posted window, so being there even a few minutes counts."
        )
        faqItem(
            question: "The good news: ASP gets suspended ~40 days a year.",
            answer: "On major holidays (and during snow or emergencies), ASP is suspended — you can leave your car put. WePark shows today's status at the top of the map: green = suspended (leave your car), amber = in effect (move on schedule). Always good to confirm on the official calendar (linked below)."
        )
        faqItem(
            question: "Parking meters",
            answer: "Pay at the muni-meter or by app during the posted hours. Meters are free on major legal holidays."
        )
        faqItem(
            question: "Reading the signs (the final word)",
            answer: "Signs stack top to bottom — read them all; the rules combine. Note the days and times. If a block has several signs, they all apply. When in doubt, the sign on the street is always the final word — check it before you walk away."
        )
    }

    // MARK: - Section 2 content

    @ViewBuilder
    private var section2Content: some View {
        mapColorsBlock
        bodyText("The top banner shows today's ASP status — amber = in effect (move your car on schedule), green = suspended (you're free).")
        bulletedFeature(
            icon: "magnifyingglass",
            title: "Find Parking",
            description: "Tap the drive button → \"Find Parking\" to cruise the neighborhood with no destination. The map follows your car and calls out free blocks as you pass them."
        )
        bulletedFeature(
            icon: "arrow.triangle.turn.up.right.diamond",
            title: "Drive to a destination",
            description: "Turn-by-turn navigation that's parking-aware, ending where you can actually park."
        )
        bulletedFeature(
            icon: "mappin.circle",
            title: "Save your car",
            description: "Long-press where you parked to drop a \"My Car\" pin, and get a reminder before you need to move it."
        )
        bulletedFeature(
            icon: "clock",
            title: "Park Until",
            description: "Tell us how long you're staying and we'll remind you."
        )
        bulletedFeature(
            icon: "flag",
            title: "Community reports",
            description: "Saw an enforcement agent or street sweeper? Long-press a block → Report (or tap the Report button while driving) to warn your neighbors. Tap someone else's report to confirm it (\"still there\") or dispute it (\"gone\"). Reports fade as they age."
        )
    }

    // MARK: - Map colors block (Section 2)

    private var mapColorsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The map colors")
                .font(.subheadline)
                .fontWeight(.semibold)
            colorRow(color: .green, label: "Green street = free / legal parking")
            colorRow(color: .red,   label: "Red = no parking or no standing")
            colorRow(color: Color(red: 0.92, green: 0.76, blue: 0.0),
                     label: "Amber / yellow = metered or time-restricted")
        }
        .padding(.bottom, 8)
    }

    private func colorRow(color: Color, label: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 14, height: 14)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Section 3 — Official NYC sources

    private var section3View: some View {
        VStack(alignment: .leading, spacing: 12) {

            Label("Verify it yourself (official NYC sources)", systemImage: "building.columns")
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.bottom, 2)

            Text("WePark is a community helper, not the city. Always confirm with the posted street signs and the official NYC sources below — the signs are the final word.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            nycLink(
                title: "NYC Alternate Side Parking & suspension calendar",
                url: URL(string: "https://www.nyc.gov/html/dot/html/motorist/alternate-side-parking.shtml")!
            )
            nycLink(
                title: "2026 ASP suspension calendar (PDF)",
                url: URL(string: "https://www.nyc.gov/html/dot/downloads/pdf/asp-calendar-2026.pdf")!
            )
            nycLink(
                title: "NYC parking rules & signs",
                url: URL(string: "https://www.nyc.gov/html/dot/html/motorist/parking-regulations.shtml")!
            )
        }
        .padding(.bottom, 28)
    }

    private func nycLink(title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.square")
                    .imageScale(.small)
                Text(title)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(.tint)
        }
        .accessibilityLabel(title)
        .accessibilityHint("Opens in Safari")
    }

    // MARK: - Footer disclaimer

    private var footerDisclaimer: some View {
        Text("WePark provides parking information and community reports for convenience only and does not guarantee accuracy. Parking rules change and signs are updated without notice. You are responsible for obeying all posted signs and NYC regulations. Always verify with the sign on the street.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 16)
    }

    // MARK: - Helpers

    /// A question + answer pair with bold question text.
    private func faqItem(question: String, answer: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            Text(answer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    /// Plain body text (no question heading).
    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
    }

    /// A bulleted feature row with an SF Symbol icon.
    private func bulletedFeature(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .imageScale(.small)
                .frame(width: 20, alignment: .center)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        FAQHelpView()
    }
}
