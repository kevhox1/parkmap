//
//  BlockRestrictionReportSheet.swift
//  WePark
//
//  FT-15 / TF2-15 — Temporary Block-Scoped Restrictions, Stream B2 (map tap-select +
//  report sheet). Spec: docs/ft15-tf215-temporary-block-restrictions-spec.md §4.2 (tap
//  select), §5 (time window model), §7 (photo evidence & PII), §9.3 (shared primitive —
//  this ONE sheet serves both FT-15 filming and TF2-15 construction), §12 (AC-R1..AC-R9).
//
//  Entry point: ContentView's block-select floating bar "Continue" button
//  (`ActiveSheet.blockRestrictionReport(segments:)`) — `selections` is a snapshot of the
//  `Segment`s the user tapped on the map, read verbatim (blockfaceKey, coordinates) with
//  NO street-name re-derivation (spec §4.1/§4.3 — the entire point of the map-tap design).
//
//  Write path: `CommunityPinService.insertBlockScopedReport(...)` (Stream B3, PR #81 at
//  the time this file was written — NOT YET MERGED to main). This file calls that API
//  exactly as documented on that branch; it does not reimplement or duplicate any of
//  B3's upload/insert/rollback logic. See this PR's description for the merge-order
//  dependency this creates.
//
//  Form fields (§4.2 step 5, §5.2, §7):
//    - Type: Film shoot / Construction (segmented picker — §9.3's shared primitive).
//    - Selection summary (read-only, display-only — see `selectionSummary(for:)`).
//    - Restriction starts: DatePicker, defaults to now.
//    - Restriction ends (optional): DatePicker behind a toggle. Left off → the write
//      path's own `CommunityPinService.resolvedExpiresAt` fills the type-specific
//      default (24h filming / 14d construction) and clamps to the hard ceiling
//      (7d / 90d) — this view calls the SAME pure static function to compute the hint
//      text it shows the user, so the displayed default can never drift from what
//      actually gets submitted (AC-R6).
//    - Notes: optional free-text. NO structured name/phone field exists anywhere in this
//      form (AC-R7) — the placard this feature was designed around has a real name and
//      phone number printed on it (§7); capturing those in a structured, more-discoverable
//      field would be a new PII exposure surface with no product benefit over what the
//      photo (evidence-only, never shown to other users) already covers.
//    - Photo: required (AC-R5). Camera capture via `CameraCaptureView`, falling back to
//      the photo library when the camera is unavailable (Simulator has no camera
//      hardware — this fallback is also what makes the live-UI smoke in this PR's
//      checklist actually runnable in the Simulator). A small local thumbnail preview is
//      shown to the reporter before submit — this is the ONE narrow "show the photo back"
//      exception the task brief allows (confirm-before-submit, to the uploader only); the
//      photo is never surfaced to any other user anywhere in this app (§7).
//
//  PII: this file never logs, prints, or displays the photo to anyone but the capturing
//  user, pre-submit. No filename, storage path, or photo bytes appear in any error
//  message — `submitError` surfaces only `BlockScopedReportError`'s pre-written,
//  generic-on-purpose `LocalizedError` copy (mirrors `PinEvidenceUploader`'s same posture).
//
//  Invariants: no `Calendar.current` anywhere in this file (AC-I4) — date arithmetic uses
//  `Date`/`TimeInterval` only, and display formatting reuses `ParkUntilSheet.formatTime`
//  (which itself uses `Calendar.easternTime`, not `.current`). No force-unwraps.
//
//  ── COMPILE-UNVERIFIED ──────────────────────────────────────────────────────────────────
//  Written on a Linux VPS with no Xcode/Swift toolchain — never compiled or run. Requires a
//  Mac `xcodebuild build` + `test` pass before merge. See this PR's description for the
//  specific simulator smoke checklist (this is an interaction feature; a code read alone
//  cannot confirm tap-select or camera-fallback behavior).
//

import SwiftUI
import UIKit
import CoreLocation

// MARK: - BlockRestrictionReportSheet

struct BlockRestrictionReportSheet: View {

    // MARK: - Inputs

    /// The tapped `Segment`s at the moment Continue was pressed (§4.2 step 5). Non-empty
    /// by construction — ContentView's Continue button is disabled while
    /// `selectedBlockKeys` is empty (AC-R3), so this sheet is never presented with zero
    /// selections. Each element's `blockfaceKey` and coordinates are used verbatim; this
    /// file never re-derives block identity from street-name text (spec §4.1).
    let selections: [Segment]

    /// The community pin service — provides the authenticated block-scoped write path
    /// (`insertBlockScopedReport`, Stream B3).
    let pinService: CommunityPinService

    /// Called when the sheet should dismiss (on success, Cancel, or the toolbar Cancel
    /// button). ContentView's `.sheet(item:)` `onDismiss` closure separately clears the
    /// map highlight (`selectedBlockKeys`) — this closure only needs to clear `activeSheet`.
    let onDismiss: () -> Void

    // MARK: - Closure type (§9.3: one sheet, two types)

    /// UI-facing subset of `PinType` this primitive serves — filming and construction
    /// only (§9.3). A local, narrower enum (mirrors `ReportSheet.ReportType`'s existing
    /// precedent) rather than exposing the full 10-case `PinType` in a picker.
    enum ClosureType: CaseIterable, Hashable {
        case filmShoot
        case construction

        var pinType: PinType {
            switch self {
            case .filmShoot:    return .filming
            case .construction: return .construction
            }
        }

        var label: String {
            switch self {
            case .filmShoot:    return "Film shoot"
            case .construction: return "Construction"
            }
        }

        var symbolName: String {
            switch self {
            case .filmShoot:    return "video.fill"
            case .construction: return "hammer.fill"
            }
        }

        var tintColor: Color {
            switch self {
            case .filmShoot:    return .purple
            case .construction: return ParkingColors.constructionOrange
            }
        }

        /// Display copy for the "we'll assume this ends in X" hint (§5.2). Matches
        /// `CommunityPinService.defaultReportWindow(for:)`'s values exactly (24h / 14d) —
        /// if one side of this pair is ever retuned, update both (same note B3 already
        /// carries on the numeric constants).
        var defaultWindowLabel: String {
            switch self {
            case .filmShoot:    return "24 hours"
            case .construction: return "14 days"
            }
        }
    }

    // MARK: - State

    @State private var closureType: ClosureType = .filmShoot
    @State private var startsAt: Date = Date()
    @State private var hasEndTime: Bool = false
    @State private var endsAt: Date = Date().addingTimeInterval(24 * 3600)
    @State private var notes: String = ""

    @State private var capturedImage: UIImage? = nil
    @State private var showCamera: Bool = false

    @State private var isSubmitting: Bool = false
    @State private var submitError: String? = nil

    // MARK: - Derived

    /// The end date that will actually be submitted if the user leaves "Restriction
    /// ends" off — computed via the SAME pure static function B3's write path calls, so
    /// the hint text below can never drift from what gets sent to the server (AC-R6).
    private var resolvedExpiresAt: Date {
        CommunityPinService.resolvedExpiresAt(
            pinType: closureType.pinType,
            startsAt: startsAt,
            requested: hasEndTime ? endsAt : nil
        )
    }

    /// The latest end time the user can pick before the write path's own hard-ceiling
    /// clamp (defense in depth only — `hardCeiling` is enforced server-side by
    /// `pins_block_scoped_ceiling_chk` regardless of what the client sends; clamping the
    /// picker's own range here just avoids letting the user pick something that would
    /// silently get clamped without their noticing).
    private var maxEndDate: Date {
        let ceiling = CommunityPinService.hardCeiling(for: closureType.pinType) ?? (90 * 24 * 3600)
        return startsAt.addingTimeInterval(ceiling)
    }

    private var isSubmitEnabled: Bool {
        BlockRestrictionReportSheet.isSubmitEnabled(hasPhoto: capturedImage != nil, isSubmitting: isSubmitting)
    }

    private var summaryText: String {
        BlockRestrictionReportSheet.selectionSummary(for: selections)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        selectionSummarySection
                        typeSection
                        timeSection
                        notesSection
                        photoSection
                    }
                    .padding(20)
                }

                Divider()
                submitSection
            }
            .navigationTitle("Report a Closure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraCaptureView(capturedImage: $capturedImage) {
                    showCamera = false
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Selection summary section

    @ViewBuilder
    private var selectionSummarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Selected blocks", systemImage: "map")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(summaryText)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Type section

    @ViewBuilder
    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's closing this block?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Closure type", selection: $closureType) {
                ForEach(ClosureType.allCases, id: \.self) { type in
                    Label(type.label, systemImage: type.symbolName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .tint(closureType.tintColor)
            .accessibilityLabel("Closure type")
        }
    }

    // MARK: - Time section

    @ViewBuilder
    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            DatePicker(
                "Restriction starts",
                selection: $startsAt,
                displayedComponents: [.date, .hourAndMinute]
            )
            .accessibilityLabel("Restriction starts")

            Toggle("Set an end time", isOn: $hasEndTime)
                .accessibilityLabel("Set an end time")
                .accessibilityHint("When off, we'll assume a default end time based on the closure type.")

            if hasEndTime {
                DatePicker(
                    "Restriction ends",
                    selection: $endsAt,
                    in: startsAt...maxEndDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .accessibilityLabel("Restriction ends")
            } else {
                Text(defaultWindowHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The "ends" DatePicker's own `in: startsAt...maxEndDate` range depends on
        // `startsAt` — reset a stale `endsAt` selection back within range whenever
        // `startsAt` moves past it (e.g. user pushes the start time later than a
        // previously-picked end time).
        .onChange(of: startsAt) { _, newStart in
            if endsAt <= newStart {
                endsAt = newStart.addingTimeInterval(3600)
            }
        }
    }

    /// §5.2's required copy, generalized across both closure types: "We'll assume this
    /// ends in 24 hours unless you say otherwise — <formatted date>. You can always
    /// report it again." The "24 hours" / "14 days" half is fixed per-type (§5.3); the
    /// formatted date half is computed via the SAME `resolvedExpiresAt` the write path
    /// actually submits (AC-R6).
    private var defaultWindowHint: String {
        "We'll assume this ends in \(closureType.defaultWindowLabel) unless you say otherwise" +
        " — \(ParkUntilSheet.formatTime(resolvedExpiresAt)). You can always report it again."
    }

    // MARK: - Notes section

    @ViewBuilder
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes (optional)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("e.g. \"North Six\" production, posted on pole", text: $notes, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Notes")
        }
    }

    // MARK: - Photo section

    @ViewBuilder
    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Evidence photo")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Required. Photo evidence of the posted sign — used for verification only, never shown to other users.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let image = capturedImage {
                HStack(spacing: 12) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)

                    Button {
                        showCamera = true
                    } label: {
                        Text("Retake")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Retake evidence photo")

                    Spacer()
                }
            } else {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Take evidence photo")
                .accessibilityHint("Opens the camera to photograph the posted sign.")
            }
        }
    }

    // MARK: - Submit section

    @ViewBuilder
    private var submitSection: some View {
        VStack(spacing: 12) {
            if let error = submitError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await submit() }
            } label: {
                ZStack {
                    if isSubmitting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Submit Report")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(isSubmitEnabled ? Color.accentColor : Color.secondary.opacity(0.4))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!isSubmitEnabled)
            .accessibilityLabel("Submit closure report")
            .accessibilityHint(capturedImage == nil ? "Take a photo first" : "Submits this closure report")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Submit

    /// AC-R4: submits one `pins` row per selected blockface, all sharing one
    /// `report_group_id` (Stream B3's `insertBlockScopedReport`). AC-R8: a failed submit
    /// leaves every `@State` field (including `capturedImage`) untouched in this
    /// still-open sheet — `submitError` is the only thing that changes — so the user can
    /// retry without re-entering anything.
    private func submit() async {
        // BlockScopedReportSelection reads blockfaceKey + a coordinate verbatim off each
        // tapped Segment — no street-name re-derivation (spec §4.1). Segments with no
        // usable coordinate (should not occur for real tile data — every rendered
        // segment has a non-empty `line`) are skipped rather than sent with a placeholder
        // 0,0 coordinate.
        let blockScopedSelections: [BlockScopedReportSelection] = selections.compactMap { segment in
            guard let coord = segment.midpoint ?? segment.coordinates.first else { return nil }
            return BlockScopedReportSelection(
                blockfaceKey: segment.blockfaceKey,
                lat: coord.latitude,
                lng: coord.longitude
            )
        }
        guard !blockScopedSelections.isEmpty else {
            submitError = "Something went wrong with your block selection. Try selecting the blocks again."
            return
        }
        guard let image = capturedImage, let photoData = image.jpegData(compressionQuality: 0.7) else {
            submitError = "No photo was captured."
            return
        }

        isSubmitting = true
        submitError = nil

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            _ = try await pinService.insertBlockScopedReport(
                pinType: closureType.pinType,
                selections: blockScopedSelections,
                startsAt: startsAt,
                expiresAt: hasEndTime ? endsAt : nil,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                evidencePhoto: photoData
            )
            onDismiss()
        } catch {
            // Surfaces BlockScopedReportError's own LocalizedError copy (including the
            // distinct rate-limit message) rather than a single generic fallback for
            // every failure — task instruction: "surface its error to the user clearly,
            // don't swallow it."
            submitError = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't submit your report. Check your connection and try again."
        }

        isSubmitting = false
    }

    // MARK: - Pure helpers (testable without a SwiftUI view instance)

    /// AC-R5: Submit is enabled only when a photo has been captured and no submit is
    /// already in flight. Type is always non-nil (default `.filmShoot`), so this doesn't
    /// need to gate on it separately.
    static func isSubmitEnabled(hasPhoto: Bool, isSubmitting: Bool) -> Bool {
        hasPhoto && !isSubmitting
    }

    /// Builds the plain-text confirmation summary shown at the top of the sheet (spec
    /// §4.2 step 5's own example: "E 2nd St, 3rd Ave–1st Ave, both curbs (4 blockfaces)").
    /// Purely for user confirmation — never re-parsed or re-used to derive submission
    /// identity (§4.1/§4.3; the actual submission reads `blockfaceKey` off each `Segment`
    /// directly, not from this string).
    ///
    /// Known, deliberate simplification: for a selection spanning exactly 2 distinct
    /// cross streets (the common single-block case), this renders "<lo>–<hi>" exactly
    /// like the spec's example. For 3+ distinct cross streets (Kevin's own 2-block
    /// canonical case touches 3 — 3rd/2nd/1st Ave, since 2nd Ave is the shared internal
    /// boundary), this renders a comma-separated list instead of trying to compute just
    /// the two OUTER endpoints — the spec's own §4.1 explicitly names "which block is
    /// adjacent to which along a named, non-numeric street" as a real street-topology
    /// problem the tile data doesn't encode as a graph ("numbered avenues make it look
    /// easy; it isn't easy in general"). Attempting that here for display text would be
    /// exactly the kind of on-device re-derivation the whole tap-select design exists to
    /// avoid. Flagged in this PR's description, not silently attempted.
    static func selectionSummary(for segments: [Segment]) -> String {
        guard !segments.isEmpty else { return "No blocks selected" }

        let blockfaceCount = Set(segments.map(\.blockfaceKey)).count
        let faceWord = blockfaceCount == 1 ? "blockface" : "blockfaces"
        let streets = Set(segments.map(\.street))

        guard streets.count == 1, let street = streets.first else {
            return "\(streets.count) streets selected — \(blockfaceCount) \(faceWord) total"
        }

        let crossStreetsRaw = Array(Set(segments.flatMap { [$0.fromStreet, $0.to] })).sorted()
        let crossStreets = crossStreetsRaw.map(formattedStreetName)
        let crossLabel = crossStreets.count <= 2
            ? crossStreets.joined(separator: "\u{2013}")
            : crossStreets.joined(separator: ", ")

        let sides = Set(segments.map(\.side))
        let curbLabel = sides.count > 1 ? "both curbs" : "one curb"

        return "\(formattedStreetName(street)), \(crossLabel), \(curbLabel) (\(blockfaceCount) \(faceWord))"
    }

    /// Converts an ALL-CAPS street name from tile data to Title Case for display.
    /// Same word-by-word approach as `ArrivalPromptSheet.formattedStreetName` — duplicated
    /// per this project's established view-file-local formatting-helper convention
    /// (see `RuleRow.formatMinutes`'s doc comment on why duplication is intentional
    /// rather than a shared utility).
    private static func formattedStreetName(_ rawStreet: String) -> String {
        rawStreet.split(separator: " ").map { word in
            let str = String(word)
            return str.prefix(1).uppercased() + str.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

// MARK: - CameraCaptureView

/// `UIViewControllerRepresentable` wrapper around `UIImagePickerController` for evidence
/// photo capture (§7). SwiftUI has no native camera-capture API as of iOS 17 — this is
/// the standard UIKit-bridge pattern, matching this project's existing precedent of
/// dropping to UIKit only when SwiftUI genuinely can't do it (`MapViewRepresentable`).
///
/// Falls back to the photo library when the camera is unavailable
/// (`UIImagePickerController.isSourceTypeAvailable(.camera)` is `false` on every
/// Simulator — there is no camera hardware to report). This fallback is not a new
/// capture path invented for this feature; it is the same defensive pattern countless
/// iOS apps use for devices/environments without a camera, and it is also what makes
/// this PR's live-UI smoke checklist runnable at all in the Simulator.
struct CameraCaptureView: UIViewControllerRepresentable {

    /// Binding into the parent's `@State private var capturedImage`. Set on a successful
    /// capture/pick; left untouched on cancel.
    @Binding var capturedImage: UIImage?

    /// Called after either a successful capture/pick or a cancel — the parent dismisses
    /// the presenting `.sheet(isPresented:)` in response.
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        // No dynamic state to sync — the picker's configuration is fixed at creation.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView

        init(_ parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.capturedImage = info[.originalImage] as? UIImage
            parent.onDismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onDismiss()
        }
    }
}
