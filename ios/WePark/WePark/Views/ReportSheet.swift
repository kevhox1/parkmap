//
//  ReportSheet.swift
//  WePark
//
//  Tier 3 Sub-PR #2 — Universal Community Reporting.
//  Spec: docs/tier3-patrol-report-spec.md §3.4 / §6.
//
//  Entry points:
//   - Resting long-press on map → confirmationDialog "Report enforcement or sweeper"
//     → ActiveSheet.reportPin(coord: <long-press-coord>)
//   - In-drive "Report" button tap → ActiveSheet.reportPin(coord: <current-GPS>)
//
//  Both paths present the same ReportSheet; the coordinate is injected at presentation time.
//
//  Write path: calls CommunityPinService.insertCrowdPin(type:meta:lat:lng:segmentId:zoneId:notes:).
//  meta: [String: Any]? is built from EnforcementActiveMeta / SweeperPassedMeta serialized to
//  a dictionary matching the JSONB column shape.
//
//  Copy compliance (AC-R17): no "avoid", "ticket", "fine", "evasion", or "dodge" language.
//
//  Marker icons (spec §9 — @designer note):
//   - enforcement_active: shield.fill (blue) — placeholder per spec §9.1.
//     No docs/design/tier3-marker-icons.md found at build time; placeholder used.
//   - sweeper_passed: exclamationmark.triangle.fill (orange) — placeholder per spec §9.2.
//     truck.box.fill is not available pre-iOS 18 (iOS 17 min target); using triangle instead.
//
//  Community 2.0 Phase 2a (build 20 S6) additions — spec: docs/community-2.0-reconciliation-spec.md
//  §3 Phase 2 ("Report grid" / "Confirm the street"), design/prototype.html:361-411,
//  design/screenshots/09-report-confirm-street.png. Both gated behind
//  `AppConstants.communityEnabled` — flag-off keeps this file's pre-existing straight-to-
//  heading flow byte-identical (product rule 7 / AC-P1.3-style parity):
//   - A third row, "Street closure" (🚧), hands off to the EXISTING
//     `ActiveSheet.blockRestrictionReport` multi-block flow via `onRequestStreetClosure` —
//     zero new code in `BlockRestrictionReportSheet.swift` (AC-P2.3).
//   - A "confirm the street" candidate list (current segment + opposite curb + one neighbor
//     each direction, up to 4 — `CandidateSegmentSearch.confirmStreetCandidates`) lets the
//     user correct which blockface a report is filed against before submitting. Only the
//     `segmentId` written to `insertCrowdPin` changes when a different candidate is picked —
//     `coordinate` (the actual GPS/tap point) is never altered.
//
//  Community 2.0 Phase 2b (build 20 S7) additions — spec: docs/community-2.0-reconciliation-spec.md
//  §3 Phase 2 + roadmap S7 rider, design/screenshots/08-report-grid.png,
//  design/prototype.html:358-382. Flag-gated the same way as Phase 2a's additions above:
//   - Report grid restyle: the type rows become a 2×2 `LazyVGrid` of tile cards (flag-ON
//     only — `showsReportGrid`; `body`'s `else` branch keeps the flag-off list byte-identical
//     to PR #95's shipped code). A 4th tile, "Spot open," routes into the new map-tap
//     placement flow (`Views/SpotPlacementView.swift`) via `onRequestSpotPlacement`.
//   - Identity-sheet interception (`Views/IdentitySheet.swift`) in front of `submitReport()`
//     — gated on BOTH `AppConstants.communityEnabled` (this report-submit path predates
//     Community 2.0 entirely; flag-off must see zero behavior change) AND the show-once
//     `CommunityIdentityGate`.
//

import SwiftUI
import MapKit

// MARK: - ReportSheet

struct ReportSheet: View {

    // MARK: - Inputs

    /// The coordinate at which the pin will be dropped.
    ///
    /// Resting path: the long-press coordinate on the map.
    /// In-drive path: the user's current GPS at the moment the Report button was tapped.
    let coordinate: CLLocationCoordinate2D

    /// The community pin service — provides the authenticated write path.
    let pinService: CommunityPinService

    /// Called when the sheet should dismiss (on success or cancel).
    let onDismiss: () -> Void

    /// Bug #4: Resolved street/block name for the "Reporting on X" context line.
    ///
    /// In-drive path: injected from `drivingContext?.street` (the same street name
    /// shown in the DriveModeBottomCard). This is already resolved by the existing
    /// DrivingContextService segment search — no new resolution needed.
    ///
    /// Resting path: nil (no continuous GPS + segment search in resting mode).
    ///
    /// When non-nil, the sheet shows "Reporting on <streetName>" below the header.
    /// When nil, falls back to "Reporting at current location".
    var streetName: String? = nil

    /// FT-11: The resolved tile segment at the report location.
    ///
    /// Resting path: injected from `findCandidateSegments` when the long-press lands
    /// on a named block. Nil when the long-press is off any segment.
    ///
    /// In-drive path: injected from DrivingContextService's nearest segment.
    ///
    /// When non-nil and the selected type supports it, the two-arrow direction picker
    /// is shown so the user can specify which way the agent/sweeper is heading.
    /// When nil (OD-1): picker is hidden and `heading_toward` is omitted from meta.
    var segment: Segment? = nil

    /// Community 2.0 Phase 2a (build 20 S6): up to 4 candidates for the "confirm the street"
    /// step, precomputed at the report-entry call site (both `ContentView` entry points) via
    /// `CandidateSegmentSearch.confirmStreetCandidates(for:in:)` — the current segment, its
    /// opposite curb, and one neighboring block each direction. Empty whenever `segment` is
    /// nil (OD-1). Note this array being non-empty is necessary but not sufficient for the
    /// step to render — `AppConstants.communityEnabled == false` hides it regardless (see
    /// `showsConfirmStreetStep`).
    var confirmCandidates: [Segment] = []

    /// Community 2.0 Phase 2a (build 20 S6): called when the user taps the "Street closure"
    /// row. Hands off to the EXISTING multi-block `BlockRestrictionReportSheet` flow
    /// (`ActiveSheet.blockRestrictionReport`) rather than this sheet's own type-select-then-
    /// submit path — `ContentView` wires this straight to `enterBlockSelectMode()`, the same
    /// function the pre-existing resting long-press dialog's "Report closure" button already
    /// calls. `nil` by default — no test in this file constructs a `ReportSheet` view instance
    /// (only its pure static helpers), so an optional with a safe no-op default keeps this an
    /// additive change rather than a required initializer parameter everywhere.
    var onRequestStreetClosure: (() -> Void)? = nil

    /// Community 2.0 Phase 2b (build 20 S7): called when the user taps the "Spot open" grid
    /// tile. Hands off to `ContentView`'s new map-tap placement flow
    /// (`SpotPlacementView`/`enterSpotPlacementMode()`) rather than this sheet's own
    /// type-select-then-submit path — same shape as `onRequestStreetClosure` above. `nil` by
    /// default for the same reason: no test in this file constructs a `ReportSheet` view
    /// instance directly.
    var onRequestSpotPlacement: (() -> Void)? = nil

    // MARK: - QA STOP-AND-INSTRUMENT (PR #95) — plain data, DEBUG-only consumer

    /// Human-readable description of where `coordinate` came from — "long-press (resting)"
    /// vs "current GPS (in-drive)" — threaded from both `ContentView` entry points so the
    /// `#if DEBUG`-only console diagnostics (`logDiagnosticsToConsole`) can show it without
    /// guessing. The on-screen footer this originally also fed was removed once the STOP-AND-
    /// INSTRUMENT root cause was found (no code bug — a discoverability/scroll finding, not a
    /// mount-condition defect); this property stays because the console print path still
    /// reads it. Not read by any production behavior; plain metadata, harmless to carry in
    /// Release builds (only the print()-ing of it is `#if DEBUG`-gated).
    var coordinateSource: String = "unknown"

    /// The radius (meters) `ContentView` used for the segment search that produced `segment`/
    /// `confirmCandidates` — must match `ContentView.pinDropRadiusMeters` (35.0 today).
    /// Threaded through rather than duplicated as a literal here, so the console diagnostics
    /// can never silently drift from the real constant. Same reasoning as `coordinateSource`
    /// above — kept for `logDiagnosticsToConsole`, the on-screen footer was removed.
    var candidateSearchRadiusMeters: Double = 35.0

    // MARK: - Primary type selection

    enum ReportType {
        case enforcementActive
        case sweeper
    }

    // MARK: - Sweeper direction (per OQ-R5: both "passed" and "approaching")

    enum SweeperDirection: CaseIterable {
        case passed       // SweeperPassedMeta direction = "passed"
        case approaching  // SweeperPassedMeta direction = "coming_soon"

        var label: String {
            switch self {
            case .passed:     return "Sweeper passed"
            case .approaching: return "Sweeper approaching"
            }
        }

        var directionRawValue: String {
            switch self {
            case .passed:     return "passed"
            case .approaching: return "coming_soon"
            }
        }
    }

    // MARK: - State

    @State private var selectedType: ReportType? = nil
    @State private var selectedSubTag: EnforcementActiveMeta.SubTag? = nil
    @State private var sweeperDirection: SweeperDirection = .passed
    @State private var isSubmitting: Bool = false
    @State private var submitError: String? = nil

    /// FT-11: The chosen or auto-derived travel direction.
    ///
    /// Set by the `HeadingTowardPicker` (user tap) or auto-derived for one-way sweeper
    /// segments. Nil when the picker is hidden (off-segment, OD-1) or not yet chosen.
    @State private var selectedHeadingToward: HeadingToward? = nil

    /// Community 2.0 Phase 2a (build 20 S6): the user's pick from the "confirm the street"
    /// candidate list. Seeded from `segment` at init (see the custom `init` below) so that
    /// with `AppConstants.communityEnabled == false` — where the confirm-street section never
    /// renders and this value is therefore never reassigned — `effectiveSegment` always equals
    /// `segment`, preserving today's flow byte-for-byte (product rule 7).
    @State private var confirmedSegment: Segment?

    /// Community 2.0 Phase 2b (build 20 S7): holds the "resume this contribution" closure
    /// while the identity sheet is up. Non-nil drives the identity `.sheet(isPresented:)`
    /// below (see `body`) — set by `submitReport()`'s interception check, cleared and
    /// invoked (in that order) by `IdentitySheet`'s `onSave`/`onSkip` callbacks.
    @State private var pendingIdentityAction: (() -> Void)? = nil

    // MARK: - Init

    /// Custom init only to seed `confirmedSegment` from `segment` — every other property
    /// keeps its declared default, so existing call sites that don't pass
    /// `confirmCandidates`/`onRequestStreetClosure`/`onRequestSpotPlacement`/
    /// `coordinateSource`/`candidateSearchRadiusMeters` are unaffected.
    init(
        coordinate: CLLocationCoordinate2D,
        pinService: CommunityPinService,
        onDismiss: @escaping () -> Void,
        streetName: String? = nil,
        segment: Segment? = nil,
        confirmCandidates: [Segment] = [],
        onRequestStreetClosure: (() -> Void)? = nil,
        onRequestSpotPlacement: (() -> Void)? = nil,
        coordinateSource: String = "unknown",
        candidateSearchRadiusMeters: Double = 35.0
    ) {
        self.coordinate = coordinate
        self.pinService = pinService
        self.onDismiss = onDismiss
        self.streetName = streetName
        self.segment = segment
        self.confirmCandidates = confirmCandidates
        self.onRequestStreetClosure = onRequestStreetClosure
        self.onRequestSpotPlacement = onRequestSpotPlacement
        self.coordinateSource = coordinateSource
        self.candidateSearchRadiusMeters = candidateSearchRadiusMeters
        _confirmedSegment = State(initialValue: segment)
    }

    // MARK: - Derived

    private var isReportEnabled: Bool {
        ReportSheet.isEnabled(selectedType: selectedType, isSubmitting: isSubmitting)
    }

    /// Community 2.0 Phase 2a (build 20 S6): the segment used downstream for the direction
    /// picker and the `insertCrowdPin` `segmentId` — `segment` as detected, unless the user
    /// picked a different candidate in the "confirm the street" step (flag-on only; see
    /// `confirmedSegment`'s doc comment for why flag-off is unaffected).
    private var effectiveSegment: Segment? { confirmedSegment }

    /// Community 2.0 Phase 2a (build 20 S6): whether the "confirm the street" section should
    /// render. Instance wrapper over the pure static `showsConfirmStreetStep` — reads the real
    /// `AppConstants.communityEnabled` flag for production call sites; tests call the static
    /// function directly with both flag values.
    private var showsConfirmStreetStep: Bool {
        ReportSheet.showsConfirmStreetStep(
            communityEnabled: AppConstants.communityEnabled,
            selectedType: selectedType,
            candidates: confirmCandidates
        )
    }

    /// FT-11: True when the direction picker should be shown.
    ///
    /// Rules (from spec §5.2 / stream B2):
    ///   - enforcement active + segment non-nil → always show
    ///   - sweeper + segment non-nil + NOT one-way → show
    ///   - sweeper + segment nil OR one-way → hide (auto-derived or off-segment)
    ///
    /// Community 2.0 Phase 2a: reads `effectiveSegment`, not the raw `segment` input, so a
    /// "confirm the street" pick is reflected downstream — the picker itself
    /// (`headingTowardPickerRow`/`headingArrowButton`) is otherwise untouched.
    private var shouldShowDirectionPicker: Bool {
        guard let type = selectedType, let seg = effectiveSegment else { return false }
        switch type {
        case .enforcementActive:
            return true
        case .sweeper:
            // One-way segment: auto-derive, no picker needed.
            return seg.oneway != true
        }
    }

    /// FT-11: Auto-derived heading for a one-way sweeper report.
    ///
    /// Computed from `segment.onewayToward` when the segment is one-way. Returns nil
    /// for two-way segments or when oneway data is absent (picker fallback).
    ///
    /// Community 2.0 Phase 2a: reads `effectiveSegment` — see `shouldShowDirectionPicker`.
    private var autoHeadingToward: HeadingToward? {
        guard let seg = effectiveSegment, seg.oneway == true else { return nil }
        switch seg.onewayToward {
        case "from": return .from
        case "to":   return .toward_to
        default:     return nil
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("What's happening?")
                        .font(.title2.weight(.semibold))
                    Text("Help your neighbors find safe parking.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // Bug #4: "Reporting on X" context line — surfaces the resolved block
                    // name so the user can confirm they are reporting on the correct street.
                    // In-drive: streetName comes from drivingContext?.street (DrivingContextService).
                    // Resting: streetName is nil → fallback label shown.
                    HStack(spacing: 4) {
                        Image(systemName: "location.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(ReportSheet.locationContextLabel(streetName: streetName))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {

                        if ReportSheet.showsReportGrid(communityEnabled: AppConstants.communityEnabled) {
                            // Community 2.0 Phase 2b (build 20 S7 rider) — report grid restyle.
                            // design/screenshots/08-report-grid.png, prototype.html:358-382.
                            // Flag-ON only: this ENTIRELY replaces the flag-off list below (the
                            // `else` branch), rather than co-existing with it — see
                            // `showsReportGrid`'s doc comment.
                            //
                            // Resolves S6's disclosed closure-row-order deviation (open-items
                            // #12 / gap-inventory WP-small): in a 2×2 grid, every tile has a
                            // FIXED slot — closure takes its prototype position (bottom-right,
                            // 4th cell) without needing the list's "render first" workaround,
                            // because nothing is ever inserted BETWEEN grid cells (see below).
                            reportGridSection
                                .padding(.horizontal, 20)
                                .padding(.bottom, 4)

                            // Per-type detail sections — PRESERVES the S6 fix's invariant (no
                            // tile's hit-target may shift as a side effect of selecting another
                            // tile): rendered BELOW the WHOLE grid, never between cells, so a
                            // grid cell's fixed slot never moves regardless of what gets
                            // selected. Byte-for-byte the SAME conditionals/views as the
                            // flag-off list's own (below), just placed once after the grid
                            // instead of interleaved between Row 1/Row 2.
                            if selectedType == .enforcementActive {
                                subTagPickerRow
                                    .padding(.leading, 20)
                                    .padding(.bottom, 4)
                            }
                            if selectedType == .enforcementActive && showsConfirmStreetStep {
                                confirmStreetSection
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 4)
                            }
                            if selectedType == .enforcementActive && shouldShowDirectionPicker {
                                headingTowardPickerRow
                                    .padding(.leading, 20)
                                    .padding(.bottom, 4)
                            }
                            if selectedType == .sweeper {
                                sweeperDirectionRow
                                    .padding(.leading, 20)
                                    .padding(.bottom, 4)
                            }
                            if selectedType == .sweeper && showsConfirmStreetStep {
                                confirmStreetSection
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 4)
                            }
                            if selectedType == .sweeper && shouldShowDirectionPicker {
                                headingTowardPickerRow
                                    .padding(.leading, 20)
                                    .padding(.bottom, 4)
                            }
                        } else {
                            // Flag-OFF: byte-identical to the pre-S7 list flow (PR #95,
                            // unchanged by this session). Do NOT restructure this branch — see
                            // PR #95's "S6 saga" (this file's own header comment) for why
                            // flag-off parity here is treated as sacred.

                            // Row 3: Street closure (Community 2.0 Phase 2a, build 20 S6).
                            //
                            // QA pass 2 / PR #95 Mac-gate blocker fix — POSITION, not just gating:
                            // this row used to render LAST, after Row 2 and whichever per-type
                            // detail (subtag/direction toggle, confirm-street section, heading
                            // picker) that row's own selection had inserted. Selecting Row 1 or
                            // Row 2 inserts that detail in the SAME synchronous transaction as the
                            // tap that selected it, which shifts every sibling BELOW the inserted
                            // content — including a row sitting after Row 2's conditional block.
                            // For an ordinary row (e.g. Row 2 shifting when Row 1's detail is
                            // inserted — a pre-existing, harmless pattern already present before
                            // this PR) a stray mis-hit during that shift is a total non-event: it
                            // just sets `selectedType` again. For Row 3 it is NOT harmless: its
                            // action (`onRequestStreetClosure` → `enterBlockSelectMode()`)
                            // force-hides `activeSheet` — exactly the "report sheet AND browse
                            // sheet both gone, no crash logged" fingerprint reported at the Mac
                            // gate. Fix: render Row 3 FIRST, before Row 1/Row 2 and ALL of their
                            // conditional detail, so nothing dynamic is EVER inserted above it —
                            // its position (and hit-test target) cannot move for any reason.
                            //
                            // This branch only fires when `communityEnabled == false`, at which
                            // point `showsStreetClosureTile` below is always false too — Row 3
                            // never actually renders here; the row-ordering fix is kept verbatim
                            // anyway so this branch stays a literal, provably-unchanged copy of
                            // PR #95's shipped code (byte-identical diff-ability over cleverness).
                            if ReportSheet.showsStreetClosureTile(communityEnabled: AppConstants.communityEnabled) {
                                streetClosureRow
                            }

                            // MARK: Primary type rows

                            // Row 1: Enforcement active
                            reportTypeRow(
                                label: "Enforcement active",
                                sublabel: "Officer or cleaning truck on the block",
                                symbolName: "shield.fill",
                                tintColor: .blue,
                                type: .enforcementActive
                            )

                            // Sub-tag picker: visible only when Enforcement active is selected
                            if selectedType == .enforcementActive {
                                subTagPickerRow
                                    .padding(.leading, 20)
                                    .padding(.bottom, 4)
                            }

                            // Community 2.0 Phase 2a (build 20 S6): "confirm the street" —
                            // communityEnabled-gated, so flag-off skips straight to the direction
                            // picker below exactly as it did before this session.
                            if selectedType == .enforcementActive && showsConfirmStreetStep {
                                confirmStreetSection
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 4)
                            }

                            // FT-11: Direction picker for enforcement (always when segment non-nil).
                            if selectedType == .enforcementActive && shouldShowDirectionPicker {
                                headingTowardPickerRow
                                    .padding(.leading, 20)
                                    .padding(.bottom, 4)
                            }

                            // Row 2: Sweeper
                            reportTypeRow(
                                label: "Street sweeper",
                                sublabel: "Sweeping truck on or near this block",
                                symbolName: "exclamationmark.triangle.fill",
                                tintColor: .orange,
                                type: .sweeper
                            )

                            // Sweeper direction toggle: visible only when sweeper is selected
                            if selectedType == .sweeper {
                                sweeperDirectionRow
                                    .padding(.leading, 20)
                                    .padding(.bottom, 4)
                            }

                            // Community 2.0 Phase 2a (build 20 S6): "confirm the street" for sweeper.
                            if selectedType == .sweeper && showsConfirmStreetStep {
                                confirmStreetSection
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 4)
                            }

                            // FT-11: Direction picker for sweeper (only when not auto-derived).
                            if selectedType == .sweeper && shouldShowDirectionPicker {
                                headingTowardPickerRow
                                    .padding(.leading, 20)
                                    .padding(.bottom, 4)
                            }
                        }

                    }
                    .padding(.vertical, 12)
                }

                Divider()

                // MARK: Error + CTA

                VStack(spacing: 12) {
                    if let error = submitError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await submitReport() }
                    } label: {
                        ZStack {
                            if isSubmitting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Text("Report")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(isReportEnabled ? Color.accentColor : Color.secondary.opacity(0.4))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!isReportEnabled)
                    .accessibilityLabel("Submit report")
                    .accessibilityHint("Reports the selected condition at this location.")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
            #if DEBUG
            // QA STOP-AND-INSTRUMENT (PR #95, 2026-08-28) — root cause found (no code bug;
            // discoverability finding logged for S13), on-screen footer removed post-diagnosis.
            // These triggers are kept — console-only, free, useful later — see
            // `logDiagnosticsToConsole`'s own doc comment.
            .onAppear { logDiagnosticsToConsole(trigger: "onAppear") }
            .onChange(of: selectedType) { _, _ in logDiagnosticsToConsole(trigger: "selectedType changed") }
            .onChange(of: confirmCandidates.count) { _, _ in logDiagnosticsToConsole(trigger: "confirmCandidates.count changed") }
            #endif
        }
        // Community 2.0 Phase 2b (build 20 S7): identity-sheet interception. Presented as a
        // nested sheet-on-sheet (a standard, supported SwiftUI pattern) rather than a new
        // `ActiveSheet` case, so this stays entirely local to `ReportSheet.swift` — no
        // `ContentView` wiring needed for the report-submit contribution path. QA pass 1
        // (PR #96, Finding #2) confirmed this specific pattern is NOT at risk — nesting one
        // sheet inside an already-presented sheet's own content is the standard, safe shape;
        // only `ContentView`'s OWN top-level second `.sheet` (the spot-post path's identity
        // gate) needed to move onto the single `ActiveSheet` presenter — see that file's
        // `ActiveSheet.identityPrompt` case for the fix.
        //
        // See `submitReport()` for the gating check and `IdentitySheet.swift`'s header for
        // the full design.
        .sheet(isPresented: Binding(
            get: { pendingIdentityAction != nil },
            set: { isPresented in
                if !isPresented { pendingIdentityAction = nil }
            }
        )) {
            IdentitySheet(
                onSave: { username, avatar in
                    let action = pendingIdentityAction
                    pendingIdentityAction = nil
                    Task {
                        do {
                            try await pinService.upsertProfile(username: username, avatar: avatar)
                        } catch {
                            // QA pass 1 fix (PR #96, Finding #1): surfaced, not `try?`-swallowed
                            // — the underlying report still posts on its own independent
                            // network call regardless (`action?()` below), so a failed profile
                            // save is never fatal to the user's actual contribution, but it
                            // shouldn't be silently invisible to a developer either.
                            #if DEBUG
                            print("[ReportSheet] upsertProfile failed: \(error)")
                            #endif
                        }
                    }
                    action?()
                },
                onSkip: {
                    let action = pendingIdentityAction
                    pendingIdentityAction = nil
                    action?()
                }
            )
            .presentationDetents([.medium])
        }
    }

    // MARK: - Report type row builder

    @ViewBuilder
    private func reportTypeRow(
        label: String,
        sublabel: String,
        symbolName: String,
        tintColor: Color,
        type: ReportType
    ) -> some View {
        let isSelected = selectedType == type
        Button {
            // QA pass 2 round 2 (PR #95): routed through the pure `destination(forTapping:)`
            // model instead of setting `selectedType` directly, so this button's ACTUAL
            // behavior is what the 8 `ReportGridRoutingTests` assert against — a future edit
            // that breaks the routing contract now breaks this button too, not just a
            // disconnected test double. `showsConfirmStreet` isn't consumed here (the
            // confirm-street section reads the instance `showsConfirmStreetStep` computed
            // property when rendering); only the `type` payload drives this closure.
            switch ReportSheet.destination(
                forTapping: .type(type),
                communityEnabled: AppConstants.communityEnabled,
                candidates: confirmCandidates
            ) {
            case .selectType(let resolvedType, _):
                selectedType = resolvedType
                // Reset sub-state when type changes
                if resolvedType != .enforcementActive { selectedSubTag = nil }
                if resolvedType != .sweeper { sweeperDirection = .passed }
                // FT-11: Reset direction picker selection when the top-level type changes.
                selectedHeadingToward = nil
            case .streetClosureHandoff:
                // Unreachable: this row always taps `.type(type)`, which `destination(forTapping:)`
                // always resolves to `.selectType` (tested — `testDestination_typeTile_preservesTappedType_neverTheOtherOne`
                // and the streetClosureHandoff-never-equals-selectType tests). Defensive no-op.
                break
            case .spotPlacementHandoff:
                // Unreachable for the same reason as `.streetClosureHandoff` above —
                // Community 2.0 Phase 2b (build 20 S7): this row always taps `.type(type)`,
                // never `.spotOpen`. Defensive no-op.
                break
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? tintColor : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isSelected ? .primary : .primary)
                    Text(sublabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(tintColor)
                        .font(.system(size: 20))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(isSelected ? tintColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Sub-tag picker row (Enforcement sub-types, per AC-R14)

    /// Horizontal pill row. Order: Cleaning truck first (per OQ-R2 / community-1.0-direction §6).
    /// "Not sure" maps to nil (no sub_tag). Default is no selection (nil).
    @ViewBuilder
    private var subTagPickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What kind?")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    subTagPill(label: "Cleaning truck",   tag: .cleaningTruck)
                    subTagPill(label: "Parking agent",    tag: .parkingAgent)
                    subTagPill(label: "Tow truck",        tag: .towTruck)
                    // "Not sure" maps to nil — explicitly tapping deselects
                    Button {
                        selectedSubTag = nil
                    } label: {
                        Text("Not sure")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selectedSubTag == nil ? Color.blue.opacity(0.15) : Color(.systemGray6))
                            .foregroundStyle(selectedSubTag == nil ? .blue : .secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Not sure — no sub-type selected")
                    .accessibilityAddTraits(selectedSubTag == nil ? [.isSelected] : [])
                }
                .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func subTagPill(label: String, tag: EnforcementActiveMeta.SubTag) -> some View {
        let isSelected = selectedSubTag == tag
        Button {
            selectedSubTag = isSelected ? nil : tag
        } label: {
            Text(label)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue.opacity(0.15) : Color(.systemGray6))
                .foregroundStyle(isSelected ? .blue : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Sweeper direction row (per OQ-R5: "passed" + "approaching")

    @ViewBuilder
    private var sweeperDirectionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Direction?")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            HStack(spacing: 8) {
                ForEach(SweeperDirection.allCases, id: \.directionRawValue) { direction in
                    let isSelected = sweeperDirection == direction
                    Button {
                        sweeperDirection = direction
                    } label: {
                        Text(direction.label)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.orange.opacity(0.15) : Color(.systemGray6))
                            .foregroundStyle(isSelected ? .orange : .secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(direction.label)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - FT-11: Heading-toward direction picker row

    /// Two-arrow picker letting the user specify which direction the agent/sweeper
    /// is travelling. Each arrow button is:
    ///   - Labeled with the cross-street name it points toward (fromStreet / to).
    ///   - Oriented to the actual block bearing using a rotated SF Symbol chevron.
    ///   - Visually selected (filled background) when tapped.
    ///
    /// Shown for:
    ///   - `enforcement_active` when segment is non-nil (always).
    ///   - `sweeper_passed` when segment is non-nil and NOT one-way.
    ///
    /// Hidden entirely when the segment is nil (OD-1).
    ///
    /// Accessibility: each button has an accessibilityLabel equal to the cross-street name.
    ///
    /// Community 2.0 Phase 2a: reads `effectiveSegment` (may be a "confirm the street" pick)
    /// instead of the raw `segment` input — the picker's own rendering/bearing logic below is
    /// otherwise byte-for-byte unchanged, per this session's "keep HeadingTowardPicker exactly
    /// as-is downstream" constraint.
    @ViewBuilder
    private var headingTowardPickerRow: some View {
        if let seg = effectiveSegment {
            let bearingToFrom = SegmentBearing.bearing(segment: seg, toward: .from)
            let bearingToTo   = SegmentBearing.bearing(segment: seg, toward: .toward_to)

            VStack(alignment: .leading, spacing: 6) {
                Text("Which way?")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)

                HStack(spacing: 8) {
                    // Arrow toward the "from" cross-street
                    headingArrowButton(
                        label: seg.fromStreet,
                        toward: .from,
                        bearing: bearingToFrom
                    )
                    // Arrow toward the "to" cross-street
                    headingArrowButton(
                        label: seg.to,
                        toward: .toward_to,
                        bearing: bearingToTo
                    )
                }
                .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private func headingArrowButton(
        label: String,
        toward: HeadingToward,
        bearing: Double
    ) -> some View {
        let isSelected = selectedHeadingToward == toward
        let tint: Color = selectedType == .enforcementActive ? .blue : .orange

        Button {
            selectedHeadingToward = toward
        } label: {
            HStack(spacing: 6) {
                // Chevron rotated to the real block bearing.
                // Bearing is compass-degrees (0=north, 90=east). `chevron.forward` points
                // EAST natively, so (bearing - 90) corrects the 90° offset — see below.
                // Build-7 FT-11 chevron orientation fix:
                // `chevron.forward` points EAST natively. SwiftUI rotationEffect is CW
                // from the element's rest orientation. Without correction, bearing=0 (north)
                // renders the chevron pointing east (90° off).
                // Applying (bearing - 90) corrects: bearing=0→−90°→north ✓, bearing=90→0°→east ✓.
                Image(systemName: "chevron.forward")
                    .font(.system(size: 14, weight: .bold))
                    .rotationEffect(.degrees(bearing - 90))
                    .foregroundStyle(isSelected ? tint : .secondary)

                Text(label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isSelected ? tint : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? tint.opacity(0.15) : Color(.systemGray6))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Heading toward \(label)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Community 2.0 Phase 2a (build 20 S6): Confirm the street

    /// "CONFIRM THE STREET" — up to 4 candidate rows (current segment + opposite curb + one
    /// neighbor each direction), matching design/screenshots/09-report-confirm-street.png.
    /// Tapping a row reassigns `confirmedSegment`, which flows into `effectiveSegment` and
    /// from there into the (unchanged) direction picker and the submit payload's `segmentId`.
    @ViewBuilder
    private var confirmStreetSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            // QA pass 1 (PR #95) Finding #3: rendered ALL-CAPS via `.textCase(.uppercase)` to
            // match design/screenshots/09-report-confirm-street.png's letterspaced-caps
            // section-label treatment (prototype.html:390's "CONFIRM THE STREET") — same
            // idiom this codebase already uses for other all-caps section labels
            // (`DriveModeBottomCard.swift`'s eyebrow label, `PinDetailSheet.swift`'s
            // "Community Check"), layered on top of this file's own `.footnote.weight(.medium)`
            // + `.secondary` treatment (`subTagPickerRow`/`sweeperDirectionRow`/
            // `headingTowardPickerRow`'s existing section labels) rather than hardcoding the
            // string in caps.
            Text("Confirm the street")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)

            VStack(spacing: 7) {
                ForEach(confirmCandidates) { candidate in
                    confirmStreetRow(candidate)
                }
            }
        }
    }

    @ViewBuilder
    private func confirmStreetRow(_ candidate: Segment) -> some View {
        let isSelected = candidate.blockfaceKey == (effectiveSegment?.blockfaceKey ?? segment?.blockfaceKey)
        Button {
            confirmedSegment = candidate
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(StreetNameNormalizer.canonical(candidate.street)) — \(ReportSheet.sideDisplayName(candidate.side))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("btwn \(StreetNameNormalizer.canonical(candidate.fromStreet)) & \(StreetNameNormalizer.canonical(candidate.to))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(StreetNameNormalizer.canonical(candidate.street)), \(ReportSheet.sideDisplayName(candidate.side)), "
            + "between \(StreetNameNormalizer.canonical(candidate.fromStreet)) and \(StreetNameNormalizer.canonical(candidate.to))"
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Community 2.0 Phase 2a (build 20 S6): Street closure tile

    /// Row 3 of the report grid — hands off to the existing block-select → closure-report
    /// flow via `onRequestStreetClosure` rather than participating in this sheet's own
    /// type-select-then-submit path (no `selectedType` case for it). Copy verbatim from
    /// design/prototype.html:376-380.
    @ViewBuilder
    private var streetClosureRow: some View {
        Button {
            // QA pass 2 round 2 (PR #95): routed through `destination(forTapping:)` — same
            // reasoning as `reportTypeRow`'s Button above. `communityEnabled`/`candidates`
            // don't change `.streetClosure`'s resolved destination, but the call site still
            // passes the real values so the model always evaluates the live decision.
            switch ReportSheet.destination(
                forTapping: .streetClosure,
                communityEnabled: AppConstants.communityEnabled,
                candidates: confirmCandidates
            ) {
            case .streetClosureHandoff:
                onRequestStreetClosure?()
            case .selectType:
                // Unreachable: this row always taps `.streetClosure`, which always resolves
                // to `.streetClosureHandoff` (tested). Defensive no-op.
                break
            case .spotPlacementHandoff:
                // Unreachable for the same reason as `.selectType` above — Community 2.0
                // Phase 2b (build 20 S7): this row always taps `.streetClosure`, never
                // `.spotOpen`. Defensive no-op.
                break
            }
        } label: {
            HStack(spacing: 14) {
                Text("🚧")
                    .font(.system(size: 22))
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Street closure")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Filming or construction holding the curb — photo helps")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("Street closure")
        .accessibilityHint("Filming or construction holding the curb — photo helps. Opens the closure report flow.")
    }

    // MARK: - Community 2.0 Phase 2b (build 20 S7 rider): Report grid restyle

    /// The 2×2 tile grid — `design/screenshots/08-report-grid.png`,
    /// `design/prototype.html:358-382`. Flag-ON only (see `showsReportGrid`); `body`'s
    /// `else` branch keeps the flag-off list untouched.
    ///
    /// Icon choice per the gap-inventory's judgment call #4 (`docs/design/community-2.0-hero-gap-inventory.md`):
    /// restyle toward native SF Symbols rather than a pixel port of the prototype's card
    /// styling — reuses the SAME symbols the pre-existing list rows already established
    /// (`shield.fill` / `exclamationmark.triangle.fill`), plus the prototype's own literal
    /// "P" glyph for Spot open (not an emoji — the prototype itself uses plain bold text
    /// here) and the closure tile's already-shipped "🚧" (PR #95, kept as-is rather than
    /// "fixed" to an SF Symbol — that's an S6-shipped call, out of this rider's scope).
    /// Border tints ARE prototype-exact (`design/prototype.html:365,369,373,377` /
    /// spec §6 appendix) — community blue #0A84FF + the other per-type colors already in
    /// the reconciliation spec's palette table, per Kevin's locked decision #6
    /// ("prototype-exact fidelity") for this net-new surface.
    @ViewBuilder
    private var reportGridSection: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            reportGridCard(
                tile: .type(.enforcementActive),
                borderColor: ReportSheet.gridColor(hex: 0xFF9F0A),
                title: "Enforcement active",
                sublabel: "Agent working this block — heads-up to move or feed the meter"
            ) {
                Image(systemName: "shield.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ReportSheet.gridColor(hex: 0xFF9F0A))
            }
            reportGridCard(
                tile: .type(.sweeper),
                borderColor: ReportSheet.gridColor(hex: 0x30D158),
                title: "Sweeper passed",
                sublabel: "The broom came through — block's been cleaned"
            ) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ReportSheet.gridColor(hex: 0x30D158))
            }
            reportGridCard(
                tile: .spotOpen,
                borderColor: ReportSheet.gridColor(hex: 0x0A84FF),
                title: "Spot open",
                sublabel: "Walking past an empty legal spot? Takes 2 seconds, earns rep"
            ) {
                Text("P")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(ReportSheet.gridColor(hex: 0x0A84FF))
            }
            reportGridCard(
                tile: .streetClosure,
                borderColor: ReportSheet.gridColor(hex: 0xE8730D),
                title: "Street closure",
                sublabel: "Filming or construction holding the curb — photo helps"
            ) {
                Text("🚧").font(.system(size: 20))
            }
        }
    }

    @ViewBuilder
    private func reportGridCard<Icon: View>(
        tile: ReportGridTile,
        borderColor: Color,
        title: String,
        sublabel: String,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        let isSelected = isGridTileSelected(tile)
        Button {
            handleGridTileTap(tile)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                icon()
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(sublabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.systemGray6).opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(borderColor.opacity(isSelected ? 0.9 : 0.35), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("\(title). \(sublabel)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Whether a given grid tile should render in its "selected" visual state. Only
    /// `.type` tiles can ever be selected (they set `selectedType`); `.streetClosure` and
    /// `.spotOpen` are one-tap hand-offs to a different flow entirely and are never
    /// "selected" within this sheet's own state.
    private func isGridTileSelected(_ tile: ReportGridTile) -> Bool {
        if case .type(let type) = tile { return selectedType == type }
        return false
    }

    /// Single tap-routing entry point for all 4 grid tiles. Kept SEPARATE from
    /// `reportTypeRow`'s / `streetClosureRow`'s own inline `destination(forTapping:)`
    /// switches (each of which just grew one additive no-op arm for the new
    /// `.spotPlacementHandoff` case) rather than refactoring those two into calling this —
    /// per this session's "keep the diff minimal" constraint, not touching QA'd, shipped
    /// PR #95 code beyond the mechanical exhaustive-switch addition it needs to compile.
    private func handleGridTileTap(_ tile: ReportGridTile) {
        switch ReportSheet.destination(
            forTapping: tile,
            communityEnabled: AppConstants.communityEnabled,
            candidates: confirmCandidates
        ) {
        case .selectType(let resolvedType, _):
            selectedType = resolvedType
            if resolvedType != .enforcementActive { selectedSubTag = nil }
            if resolvedType != .sweeper { sweeperDirection = .passed }
            selectedHeadingToward = nil
        case .streetClosureHandoff:
            onRequestStreetClosure?()
        case .spotPlacementHandoff:
            onRequestSpotPlacement?()
        }
    }

    /// Small per-file hex→Color helper (matches `CrewFeedSection`'s own `fileprivate
    /// static func color(hex:)` precedent — duplicated rather than shared, per this
    /// codebase's established house style; see `CandidateSegmentSearch`'s duplicated
    /// geometry helpers for the same reasoning).
    fileprivate static func gridColor(hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    // MARK: - Submit

    /// Community 2.0 Phase 2b (build 20 S7): identity-sheet interception in front of the
    /// report-submit contribution path (spec §3 Phase 2: "wire needIdentity-style
    /// interception in front of every contribution path (report post, spot post)").
    ///
    /// Gated on BOTH `AppConstants.communityEnabled` AND the show-once gate
    /// (`CommunityIdentityInterception.shouldShowIdentitySheet`) — this report-submit path
    /// predates Community 2.0 entirely and is live for every user today, flag-off or not, so
    /// flag-off must see ZERO behavior change here: no sheet ever shown, no `UserDefaults`
    /// write ever made, `performSubmit(type:)` called immediately exactly as `submitReport()`
    /// used to do its whole job inline before this session.
    private func submitReport() async {
        guard let type = selectedType else { return }

        if CommunityIdentityInterception.shouldShowIdentitySheet(
            communityEnabled: AppConstants.communityEnabled,
            identitySheetShouldShow: CommunityIdentityGate().shouldShow()
        ) {
            // Defer the actual submit until the identity sheet resolves (save or skip).
            // `isSubmitting` deliberately stays false here — the CTA isn't "in flight" while
            // the identity sheet is up, matching the prototype's needIdentity(cb)
            // gate-then-proceed shape (`design/prototype.html:1014`'s `placePost`/`repPost`
            // pattern of wrapping the real action in `this.needIdentity(() => {...})`).
            pendingIdentityAction = { Task { await performSubmit(type: type) } }
            return
        }

        await performSubmit(type: type)
    }

    /// The actual network submit — split out of `submitReport()` so the identity
    /// interception above can defer this call until "Join the board & post" / "Post
    /// anonymously" resolves, without duplicating the meta-building/heading-resolution logic.
    /// Byte-for-byte the same body `submitReport()` had before this session.
    private func performSubmit(type: ReportType) async {
        isSubmitting = true
        submitError = nil

        // FT-11: Resolve the effective heading_toward.
        // For one-way sweeper: use the auto-derived value.
        // For picker cases: use the user's selection (may be nil if not yet chosen).
        let effectiveHeading: HeadingToward?
        if type == .sweeper, let autoHeading = autoHeadingToward {
            effectiveHeading = autoHeading
        } else {
            effectiveHeading = selectedHeadingToward
        }

        do {
            let (pinType, meta) = ReportSheet.buildMeta(
                type: type,
                subTag: selectedSubTag,
                sweeperDirection: sweeperDirection,
                headingToward: effectiveHeading
            )
            try await pinService.insertCrowdPin(
                type: pinType,
                meta: meta,
                lat: coordinate.latitude,
                lng: coordinate.longitude,
                // FT-11: wire segmentId (was hard-coded nil). Community 2.0 Phase 2a: reads
                // effectiveSegment so a "confirm the street" pick is what actually gets
                // written — coordinate (the real GPS/tap point) above is never altered by it.
                segmentId: effectiveSegment?.id,
                zoneId: nil,
                notes: nil
            )
            onDismiss()
        } catch {
            submitError = "Couldn't submit. Check your connection and try again."
        }

        isSubmitting = false
    }

    #if DEBUG
    // MARK: - QA STOP-AND-INSTRUMENT diagnostics (DEBUG-only, PR #95)
    //
    // Two reasoned hypothesis-fix rounds (QA round 2: routing-model dropped side effect —
    // refuted by diff; QA round 3: no-candidates guess — refuted by Kevin pinning simulator
    // GPS directly on Mott St between Prince & Spring, 40.7228,-73.9945, and still seeing no
    // confirm-street section) did not move the symptom. Per the repo's standing rule against
    // a third blind hypothesis fix, this instrumented the ACTUAL live state instead of
    // guessing again.
    //
    // Root cause found via the instrumentation: NOT a code bug. The confirm-street section
    // mounted correctly all along — it landed below the sheet's visible fold before the user
    // scrolled. Discoverability finding logged for the S13 hero-parity pass, not a functional
    // defect. The on-screen, screenshot-able footer that made this diagnosable has served its
    // purpose and is removed post-diagnosis; `logDiagnosticsToConsole` below is KEPT —
    // console-only, free, useful if a similar question comes up again later.
    //
    // Zero behavior change outside DEBUG builds: this entire block and its trigger call sites
    // in `body` compile out completely in Release — `#if DEBUG` is a compiler conditional, not
    // a runtime flag, so a TestFlight/App Store build never contains this code at all.

    /// Prints a readout of every input to the confirm-street mount decision — console-only
    /// (the on-screen footer this used to also drive was removed once the root cause was
    /// found; this function is kept for future debugging, per the dispatch instruction).
    private func logDiagnosticsToConsole(trigger: String) {
        let candidatesNonEmpty = !confirmCandidates.isEmpty
        let typeMatches = selectedType == .enforcementActive || selectedType == .sweeper
        print("""
        [ReportSheet DEBUG diagnostics] trigger=\(trigger)
          AppConstants.communityEnabled=\(AppConstants.communityEnabled)
          selectedType=\(selectedType.map { "\($0)" } ?? "nil")
          coordinate=(\(coordinate.latitude), \(coordinate.longitude)) source=\(coordinateSource)
          segment=\(segment.map { $0.id } ?? "nil") searchRadius=\(candidateSearchRadiusMeters)m
          confirmCandidates.count=\(confirmCandidates.count)
          mount: communityEnabled=\(AppConstants.communityEnabled) candidatesNonEmpty=\(candidatesNonEmpty) typeMatches=\(typeMatches)
          VERDICT showsConfirmStreetStep=\(showsConfirmStreetStep)
        """)
    }
    #endif

    // MARK: - Meta builder (type → insertCrowdPin args)

    /// Pure static function: converts a report type + selection state into the
    /// `(PinType, [String: Any]?)` pair that `insertCrowdPin(type:meta:...)` expects.
    ///
    /// Static + explicit parameters = directly testable without a SwiftUI view instance.
    ///
    /// Mapping per spec §6 table:
    ///   enforcement_active + subTag? → PinType.enforcementActive + {sub_tag: <rawValue>} or nil
    ///   sweeper passed               → PinType.sweeperPassed + {direction: "passed"}
    ///   sweeper approaching          → PinType.sweeperPassed + {direction: "coming_soon"}
    ///
    /// FT-11: `headingToward` is an additional optional parameter. When non-nil, the
    /// raw value (`"from"` or `"to"`) is written into the meta dict as `"heading_toward"`.
    /// When nil, the key is omitted entirely (AC-20: no spurious nil in meta).
    static func buildMeta(
        type: ReportType,
        subTag: EnforcementActiveMeta.SubTag?,
        sweeperDirection: SweeperDirection,
        headingToward: HeadingToward? = nil
    ) -> (PinType, [String: Any]?) {
        switch type {
        case .enforcementActive:
            var dict: [String: Any] = [:]
            if let tag = subTag {
                dict["sub_tag"] = tag.rawValue
            }
            if let heading = headingToward {
                dict["heading_toward"] = heading.rawValue
            }
            // If dict is empty (no sub_tag, no heading_toward) → return nil meta
            // (matches the DB null-meta case for generic enforcement).
            return (.enforcementActive, dict.isEmpty ? nil : dict)

        case .sweeper:
            var dict: [String: Any] = ["direction": sweeperDirection.directionRawValue]
            if let heading = headingToward {
                dict["heading_toward"] = heading.rawValue
            }
            return (.sweeperPassed, dict)
        }
    }

    // MARK: - isReportEnabled (static, for test access)

    /// Returns whether the Report CTA should be enabled for the given selection state.
    ///
    /// Pure static function — testable without a SwiftUI view instance.
    static func isEnabled(selectedType: ReportType?, isSubmitting: Bool) -> Bool {
        selectedType != nil && !isSubmitting
    }

    // MARK: - locationContextLabel (static, for test access)

    /// Returns the "Reporting on X" context label for the given street name.
    ///
    /// Pure static function — testable without a SwiftUI view instance.
    ///
    /// - Parameter streetName: The resolved block/street name, or nil when unavailable.
    /// - Returns: "Reporting on <streetName>" when non-nil; "Reporting at current location" otherwise.
    static func locationContextLabel(streetName: String?) -> String {
        if let name = streetName, !name.isEmpty {
            return "Reporting on \(name)"
        }
        return "Reporting at current location"
    }

    // MARK: - Community 2.0 Phase 2a (build 20 S6): grid + confirm-step gating (static, for test access)

    /// Row 3 ("Street closure") visibility. Pure passthrough of the flag today, but kept as a
    /// named function (rather than an inline `AppConstants.communityEnabled` check at the call
    /// site) so it reads consistently with `showsConfirmStreetStep` below and is directly
    /// testable with both flag states, matching this codebase's `AppConstants.communityPhase1PinTypes(enabled:)`
    /// / `RealtimeMergeGate.computeMergeablePinTypes(communityEnabled:)` convention of testing
    /// gating logic via an explicit parameter rather than mutating the real `let` flag.
    static func showsStreetClosureTile(communityEnabled: Bool) -> Bool {
        communityEnabled
    }

    /// Community 2.0 Phase 2b (build 20 S7 rider): whether the report grid (2×2 tile
    /// cards, `design/screenshots/08-report-grid.png`) should render instead of the
    /// pre-S7 list. `true` exactly when `communityEnabled` — the SAME flag
    /// `showsStreetClosureTile` already gates on, so grid-vs-list and closure-tile
    /// visibility can never disagree with each other. Flag-off keeps the list byte-
    /// identical to before this rider (`body`'s `else` branch).
    static func showsReportGrid(communityEnabled: Bool) -> Bool {
        communityEnabled
    }

    /// Whether the "confirm the street" candidate list should render.
    ///
    /// `false` whenever `communityEnabled` is `false` — regardless of `selectedType`/
    /// `candidates` — so flag-off keeps the pre-Community-2.0 straight-to-heading flow
    /// byte-identical (product rule 7 / AC-P1.3-style parity). Otherwise `true` only for
    /// `enforcementActive`/`sweeper` (explicitly enumerated, not just "any non-nil type" —
    /// `ReportType` currently has only these two cases, but Phase 2b is expected to add a
    /// `spotOpen`-shaped case with its OWN placement flow that must NOT pick up this step by
    /// accident) with a non-empty candidate list (empty only when `segment` was nil at entry,
    /// OD-1 — nothing to confirm against).
    static func showsConfirmStreetStep(
        communityEnabled: Bool,
        selectedType: ReportType?,
        candidates: [Segment]
    ) -> Bool {
        guard communityEnabled, !candidates.isEmpty else { return false }
        switch selectedType {
        case .enforcementActive, .sweeper: return true
        case nil: return false
        }
    }

    // MARK: - Report grid tap routing (static, for test access — QA pass 2 / PR #95 Mac-gate
    // blocker fix, build 20 S6)

    /// One of the report grid's four tiles — the tap TARGET, not the resulting state.
    enum ReportGridTile: Equatable {
        case type(ReportType)
        case streetClosure
        /// Community 2.0 Phase 2b (build 20 S7): the grid's 4th tile ("Spot open",
        /// `design/prototype.html:371-375`). Routes into the map-tap placement flow — never
        /// into `selectedType` (this sheet has no `.spotOpen` `ReportType` case; placement
        /// is its own flow, entirely separate from the select-a-type-then-submit path the
        /// other 3 tiles share).
        case spotOpen
    }

    /// What tapping a given grid tile leads to.
    ///
    /// Extracted as a pure, `Equatable` model so grid ROUTING is directly testable for both
    /// `communityEnabled` states without hosting a SwiftUI view (this codebase doesn't use
    /// ViewInspector or similar — QA pass 1 Finding #2 on this file flagged exactly this gap).
    /// Root cause of the Mac-gate blocker this fixes: `.streetClosure` (Row 3) used to render
    /// AFTER Row 1/Row 2 and whichever per-type detail their selection had inserted — so its
    /// on-screen position (and hit-test target) moved as a direct side effect of tapping a
    /// `.type` tile, racing the tap's touch-up against the relayout. `body`'s fix moves Row 3
    /// to render FIRST, before any conditional content can ever be inserted above it, removing
    /// the PRECONDITION for that race, with zero change to Rows 1/2's own (already flag-off-
    /// verified) interleaved detail structure.
    ///
    /// QA pass 2 round 2: `reportTypeRow`'s and `streetClosureRow`'s Button actions both
    /// `switch` on `destination(forTapping:communityEnabled:candidates:)`'s result to perform
    /// their actual side effects — this is not a parallel/decorative model, it is THE decision
    /// both live buttons execute. A future edit that makes a tile's tap handler resolve to the
    /// WRONG `ReportGridDestination` case — e.g. a `.streetClosure` tap accidentally computing
    /// `.selectType(...)`, or vice versa — breaks both a test AND the actual button.
    enum ReportGridDestination: Equatable {
        /// An enforcement/sweeper tile tap: `selectedType` becomes `type`.
        /// `showsConfirmStreet`: `true` → the confirm-the-street section renders next, before
        /// the direction picker; `false` → straight to the direction picker (flag-off, or
        /// flag-on with no candidates — OD-1), byte-identical to the pre-Community-2.0 flow.
        case selectType(ReportType, showsConfirmStreet: Bool)
        /// The street-closure tile tap: hands off to the existing block-select flow via
        /// `onRequestStreetClosure` — this sheet dismisses entirely, `selectedType` is never
        /// touched. By construction this case carries no `ReportType` payload, so it can never
        /// be mistaken for a `.selectType` destination at the type level.
        case streetClosureHandoff
        /// Community 2.0 Phase 2b (build 20 S7): the spot-open tile tap — hands off to
        /// `onRequestSpotPlacement` (map-tap placement flow), same shape as
        /// `.streetClosureHandoff`: this sheet dismisses entirely, `selectedType` is never
        /// touched, and by construction this case carries no `ReportType` payload either.
        case spotPlacementHandoff
    }

    /// Resolves the destination for tapping `tile`, given the current flag/candidate state.
    static func destination(
        forTapping tile: ReportGridTile,
        communityEnabled: Bool,
        candidates: [Segment]
    ) -> ReportGridDestination {
        switch tile {
        case .type(let type):
            return .selectType(
                type,
                showsConfirmStreet: showsConfirmStreetStep(
                    communityEnabled: communityEnabled,
                    selectedType: type,
                    candidates: candidates
                )
            )
        case .streetClosure:
            return .streetClosureHandoff
        case .spotOpen:
            return .spotPlacementHandoff
        }
    }

    // MARK: - sideDisplayName (static, for test access)

    /// Human-readable side label for the "confirm the street" rows — "North side" / "South
    /// side" / etc. Falls back to "<code> side" for any unexpected code rather than crashing
    /// or showing a raw single letter.
    static func sideDisplayName(_ code: String) -> String {
        switch code.uppercased() {
        case "N": return "North side"
        case "S": return "South side"
        case "E": return "East side"
        case "W": return "West side"
        default:  return "\(code) side"
        }
    }
}
