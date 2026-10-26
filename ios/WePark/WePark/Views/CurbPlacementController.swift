//
//  CurbPlacementController.swift
//  WePark
//
//  Stream A2 (curb-pin placement map layer). Owns EVERYTHING the mode adds to the map, so
//  `MapViewRepresentable.swift` (the repo's highest-regression-risk file: #31, the W8.5c-polish
//  revert, PR #138) carries only a handful of marked one-line hooks:
//    - the needle / ghost / tether reticle view            (`PlacementReticleView`)
//    - the 4-layer snapped-blockface highlight overlay      (`PlacementHighlightOverlay`)
//    - the 30 fps `CADisplayLink` that resolves the snap
//    - the entry camera, zoom window, settle nudge and exit camera
//
//  Lifecycle: `CoordinatorActions.beginPlacement(seed:)` -> a controller is created and stored on
//  the `Coordinator`; `endPlacement(restore:)` tears it down. With no session
//  (`Coordinator.placementController == nil`, i.e. ALWAYS when the feature flag is off) nothing
//  exists: no observer, no overlay, no display link, no subview.
//
//  Invariants this file keeps:
//    - Every camera mutation happens from a `CoordinatorActions` call (ContentView `.onChange`),
//      a `DispatchWorkItem`, or a MapKit delegate callback - NEVER inside `updateUIView` (#31).
//      There is exactly ONE animated camera move per transition (entry, exit) - no silent second
//      "correction" step. Entry uses `setRegion` (not `setCamera`): `MKCoordinateRegion` is the
//      only EXACT MapKit API for "this is the visible extent I want," so the seed lands under the
//      tip with no field-of-view approximation to correct afterwards - see `begin()`'s doc
//      comment and `CurbPlacementMapPolicy.entrySpanDegrees` for the full root-cause writeup of
//      the 2026-10-26 "pin lands mid-building" report this replaced. Exit still uses `setCamera`
//      (pitch/heading restoration needs the camera API).
//    - No SwiftUI state is written per frame. `onPlacementOutcome` fires only on a blockface /
//      outcome-kind change and on settle (`CurbPlacementMapPolicy.shouldFireOutcome`), always
//      hopped through `DispatchQueue.main.async` (same "no state write mid-render" rule as
//      `onRegionChanged`). The ghost / tether / highlight update imperatively.
//    - Placement is a RESTING-posture mode: it never reads or writes `driveModeActive`, never
//      sets `userTrackingMode`, never touches the Cruise camera, puck, compass or heading EMA.
//    - Pin ground point = `convert(tipPoint)` where tip is 40% of the view height (design
//      section 0) - NOT `mapView.centerCoordinate`.
//
//  [COMPILE-UNVERIFIED] Written with no Xcode on this machine - Kevin verifies on his Mac.
//

import MapKit
import UIKit

// MARK: - Hooks

/// Everything the controller needs from the representable, as closures, so the controller never
/// holds the coordinator (the coordinator owns the controller; the closures capture it weakly).
struct CurbPlacementHooks {
    /// The current snap index (`MapViewRepresentable.placementIndex`); nil = nothing to resolve.
    let index: () -> CurbSnapIndex?
    /// The severity a segment is painted with right now (drives the highlight CORE colour).
    let severity: (Segment) -> CurrentState
    /// A finger is down on the map (observer pan / pinch in began or changed).
    let touchDown: () -> Bool
    /// Live Reduce Motion (design: observe, do not cache at launch).
    let reduceMotion: () -> Bool
    /// `onPlacementOutcome` (already main-queue-hopped by the controller).
    let fireOutcome: (CurbSnapOutcome) -> Void
}

/// Margin state captured by the first `setBottomInset` (see its doc comment for the why).
struct PlacementMarginSnapshot {
    let insetsFromSafeArea: Bool
    let rawMargins: UIEdgeInsets
    let effectiveMargins: UIEdgeInsets
}

// MARK: - Display link proxy

/// Weak target so `CADisplayLink` (which retains its target) cannot retain the controller.
final class PlacementDisplayLinkProxy: NSObject {
    weak var controller: CurbPlacementController?

    @objc func tick(_ link: CADisplayLink) {
        controller?.tick()
    }
}

// MARK: - Controller

final class CurbPlacementController {

    // MARK: Inputs

    private weak var mapView: MKMapView?
    private let hooks: CurbPlacementHooks
    private let seed: CLLocationCoordinate2D

    // MARK: Entry snapshot (restored on exit)

    private let snapshot: PlacementCameraState
    private let snapshotZoomRange: MKMapView.CameraZoomRange

    /// Layout-margin state, captured lazily by the FIRST `setBottomInset` (a session that never
    /// sets an inset never touches margins). See `setBottomInset` for why this is NOT a plain
    /// read/write of `layoutMargins.bottom`.
    private var marginSnapshot: PlacementMarginSnapshot?

    // MARK: Owned UIKit objects

    private let reticle = PlacementReticleView()
    private let selectionHaptic = UISelectionFeedbackGenerator()
    private var displayLink: CADisplayLink?
    private var highlightOverlay: PlacementHighlightOverlay?

    // MARK: Session state

    private var isEnded = false
    private var entryInProgress = true
    /// The EXACT entry centre (`CurbPlacementMapPolicy.entryCenter`), captured in `begin()` and
    /// compared against in `finishEntry` (`entryArrived`). Centre-based, not altitude-based - see
    /// `entrySpanDegrees`'s doc comment for why: the entry region is exact, so arrival is a
    /// position check, not a percentage-of-approximate-distance check.
    private var entryTargetCenter: CLLocationCoordinate2D?
    private var incumbentKey: String?
    private var lastResolvedPin: CLLocationCoordinate2D?
    private var lastOutcome: CurbSnapOutcome?
    private var lastSnapped: CurbSnapResult?
    private var lastAbsorbedSignature: String?
    private var lastFiredSignature: String?
    private var lastHapticTime: CFTimeInterval?

    /// True from the first non-programmatic region change until the next settle. Gates the
    /// settle nudge (only a user move earns one) and the blockface-change haptic.
    private var moveWasUserInitiated = false

    /// Coordinator-owned guard (spec A.3 "Settle nudge"): set while OUR camera move is in
    /// flight so the region callback it causes cannot trigger a second nudge. Cleared in
    /// `regionDidChange`, on a new touch, or by the safety timer.
    private var isProgrammaticNudge = false

    private var entrySafetyWork: DispatchWorkItem?
    private var dwellWork: DispatchWorkItem?
    private var nudgeSafetyWork: DispatchWorkItem?

    // MARK: Init

    /// - Parameter replacing: a live session this one supersedes (QA #4). The new session
    ///   INHERITS its entry snapshot (camera, zoom window, margins) so a later Cancel returns to
    ///   the real pre-placement state, not to the street-level camera the old session left.
    init(
        mapView: MKMapView,
        seed: CLLocationCoordinate2D,
        incumbentKey: String?,
        hooks: CurbPlacementHooks,
        replacing previous: CurbPlacementController? = nil
    ) {
        self.mapView = mapView
        self.seed = seed
        self.incumbentKey = incumbentKey
        self.hooks = hooks
        if let previous {
            self.snapshot = previous.snapshot
            self.snapshotZoomRange = previous.snapshotZoomRange
            self.marginSnapshot = previous.marginSnapshot
        } else {
            self.snapshot = PlacementCameraState(
                center: mapView.camera.centerCoordinate,
                distance: mapView.camera.centerCoordinateDistance,
                pitch: mapView.camera.pitch,
                heading: mapView.camera.heading
            )
            self.snapshotZoomRange = mapView.cameraZoomRange
            self.marginSnapshot = nil
        }
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Begin

    func begin(animated: Bool) {
        guard let mapView else { return }
        let reduceMotion = hooks.reduceMotion()
        let animate = animated && !reduceMotion

        reticle.alpha = 0
        reticle.frame = mapView.bounds
        mapView.addSubview(reticle)
        reticle.layoutIfNeeded()
        selectionHaptic.prepare()

        // Entry camera numbers (pure; see CurbPlacementMapPolicy). `targetDistance` only drives
        // the soft pinch-zoom RANGE below (floor/ceiling) - ~5% slop there is harmless.
        let requestedHeightMeters = CurbPlacementMapPolicy.entryVisibleHeightMeters(boundsSize: mapView.bounds.size)
        let requestedDistance = MapViewRepresentable.altitudeForSpan(
            CurbPlacementMapPolicy.latitudeSpan(forVisibleHeightMeters: requestedHeightMeters)
        )
        let targetDistance = CurbPlacementMapPolicy.entryDistance(requested: requestedDistance)
        let clampedHeightMeters = CurbPlacementMapPolicy.clampedVisibleHeightMeters(
            requestedVisibleHeightMeters: requestedHeightMeters,
            requestedDistance: requestedDistance,
            clampedDistance: targetDistance
        )

        // Zoom window FIRST (so the single region move below is not re-clamped afterwards).
        let range = CurbPlacementMapPolicy.zoomRange(entryDistance: targetDistance)
        if let zoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: range.minDistance,
            maxCenterCoordinateDistance: range.maxDistance
        ) {
            mapView.setCameraZoomRange(zoomRange, animated: animate)
        }

        // ONE animated camera move: flat, north-up, street-level, seed EXACTLY under the tip.
        //
        // This is `setRegion`, not `setCamera` - a deliberate change from the original A2 PR
        // (flagged to the orchestrator, not a silent substitution: the "single setCamera on
        // entry" QA invariant becomes "single animated camera move," the literal API differs).
        // Why: `MKCoordinateRegion` is Apple's own EXACT visible-bounding-box contract (centre
        // +/- span/2 IS the rendered edge), whereas the original `MKMapCamera
        // .centerCoordinateDistance` path needed `altitudeForSpan`'s FOV GUESS (documented as
        // "~5% accurate," never verified on a real device) to turn a desired visible height into
        // an altitude. `entryCenter`'s own maths was always exact; only that altitude conversion
        // was approximate, and the one-time correction nudge meant to paper over it
        // (`finishEntry`'s old `performNudge(toward: seed, ...)`) only ran when the entry settled
        // NATURALLY - the entry-safety-timer and touch-interrupt paths shipped the uncorrected
        // position permanently, with no second chance. That is the root cause of the 2026-10-26
        // "pin lands mid-building" report. `setRegion` removes the approximation (and the nudge
        // it required) entirely, so there is no second step left to skip.
        let center = CurbPlacementMapPolicy.entryCenter(seed: seed, visibleHeightMeters: clampedHeightMeters)
        entryTargetCenter = center
        let widthMeters = CurbPlacementMapPolicy.clampedVisibleWidthMeters(
            boundsSize: mapView.bounds.size,
            clampedHeightMeters: clampedHeightMeters
        )
        let spanDegrees = CurbPlacementMapPolicy.entrySpanDegrees(
            seedLatitude: seed.latitude,
            visibleHeightMeters: clampedHeightMeters,
            visibleWidthMeters: widthMeters
        )
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: spanDegrees.latitudeDelta, longitudeDelta: spanDegrees.longitudeDelta)
        )
        // `setRegion` is the 2D/top-down MapKit API: it implies pitch 0 / heading 0, which is
        // exactly `entryPitch`/`entryHeading` - no separate pitch/heading assignment needed.
        // [COMPILE-UNVERIFIED] Mac smoke: confirm a session started from a tilted camera (ambient
        // driving look, or any prior 3D state) lands fully flat, not merely re-centred.
        mapView.setRegion(region, animated: animate)

        installDisplayLink()

        // Resolve at the SEED now so the card has an answer immediately (the camera is still
        // flying). Scale is the entry estimate; the first settle re-resolves with the real one.
        let estimatedMetersPerPoint = mapView.bounds.height > 0
            ? clampedHeightMeters / Double(mapView.bounds.height)
            : 0.28
        resolve(
            pin: seed,
            metersPerPoint: estimatedMetersPerPoint,
            fireOnChange: true,
            userMove: false
        )
        refreshReticle()

        // If MapKit never reports a region change (camera already there), still finish.
        let safety = DispatchWorkItem { [weak self] in
            self?.finishEntry(force: true)
        }
        entrySafetyWork = safety
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CurbPlacementMapPolicy.entrySafetySeconds,
            execute: safety
        )
    }

    private func installDisplayLink() {
        let proxy = PlacementDisplayLinkProxy()
        proxy.controller = self
        let link = CADisplayLink(target: proxy, selector: #selector(PlacementDisplayLinkProxy.tick(_:)))
        link.preferredFramesPerSecond = CurbPlacementMapPolicy.displayLinkFramesPerSecond
        link.isPaused = true
        // .common so it keeps firing while a finger is down (UITrackingRunLoopMode).
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    // MARK: - Display-link tick

    func tick() {
        guard !isEnded, !entryInProgress, let mapView else { return }
        let tip = CurbPlacementMapPolicy.tipPoint(in: mapView.bounds)
        let pin = mapView.convert(tip, toCoordinateFrom: mapView)

        var moved: Double?
        if let last = lastResolvedPin {
            moved = CurbPlacementMapPolicy.approxMeters(from: last, to: pin)
        }
        if CurbPlacementMapPolicy.shouldResolve(movedMeters: moved) {
            resolve(
                pin: pin,
                metersPerPoint: measuredMetersPerPoint(in: mapView, tip: tip, pin: pin),
                fireOnChange: true,
                userMove: moveWasUserInitiated && !isProgrammaticNudge
            )
        }
        // Every tick, resolve or not: the map moved under a geo-fixed snapped point.
        refreshReticle()
    }

    private func setLinkRunning(_ running: Bool) {
        displayLink?.isPaused = !CurbPlacementMapPolicy.displayLinkShouldRun(
            placementActive: !isEnded,
            entryInProgress: entryInProgress,
            mapMoving: running
        )
    }

    // MARK: - Resolve

    @discardableResult
    private func resolve(
        pin: CLLocationCoordinate2D,
        metersPerPoint: Double,
        fireOnChange: Bool,
        userMove: Bool
    ) -> CurbSnapOutcome? {
        guard let index = hooks.index() else { return nil }
        lastResolvedPin = pin
        let outcome = index.resolve(
            pin,
            incumbent: incumbentKey,
            metersPerPoint: metersPerPoint,
            config: CurbSnapConfig.standard
        )
        absorb(outcome, fireOnChange: fireOnChange, userMove: userMove)
        return outcome
    }

    private func absorb(_ outcome: CurbSnapOutcome, fireOnChange: Bool, userMove: Bool) {
        let signature = CurbPlacementMapPolicy.outcomeSignature(for: outcome)
        let isFirst = lastAbsorbedSignature == nil
        let changed = lastAbsorbedSignature != signature
        lastAbsorbedSignature = signature

        switch outcome {
        case .snapped(let result):
            incumbentKey = result.blockfaceKey
            lastSnapped = result
            updateHighlight(for: result)
        case .noCurbInRange:
            incumbentKey = nil
            lastSnapped = nil
            updateHighlight(for: nil)
        }
        lastOutcome = outcome

        if changed {
            let now = CACurrentMediaTime()
            var since: TimeInterval?
            if let last = lastHapticTime {
                since = now - last
            }
            if CurbPlacementMapPolicy.shouldFireSelectionHaptic(
                isFirstOutcome: isFirst,
                userMoveInFlight: userMove,
                secondsSinceLastHaptic: since
            ) {
                selectionHaptic.selectionChanged()
                lastHapticTime = now
            }
        }

        if fireOnChange,
           CurbPlacementMapPolicy.shouldFireOutcome(
               lastSignature: lastFiredSignature,
               newSignature: signature,
               isSettle: false
           ) {
            emit(outcome, signature: signature)
        }
    }

    private func emit(_ outcome: CurbSnapOutcome, signature: String) {
        lastFiredSignature = signature
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isEnded else { return }
            self.hooks.fireOutcome(outcome)
        }
    }

    /// The settle callback: always fires (spec: "blockface change + settle").
    private func fireSettle() {
        guard let outcome = lastOutcome else { return }
        emit(outcome, signature: CurbPlacementMapPolicy.outcomeSignature(for: outcome))
    }

    private func measuredMetersPerPoint(in mapView: MKMapView, tip: CGPoint, pin: CLLocationCoordinate2D) -> Double {
        let probeDistancePoints: CGFloat = 10
        let probe = mapView.convert(
            CGPoint(x: tip.x + probeDistancePoints, y: tip.y),
            toCoordinateFrom: mapView
        )
        let metres = CurbPlacementMapPolicy.approxMeters(from: pin, to: probe) / Double(probeDistancePoints)
        return (metres.isFinite && metres > 0) ? metres : 0.28
    }

    // MARK: - Reticle / highlight (imperative)

    /// Re-projects the geo-fixed snapped point to screen and moves ghost + tether. CALayers only.
    private func refreshReticle() {
        guard let mapView else { return }
        if let snapped = lastSnapped {
            reticle.update(ghost: mapView.convert(snapped.snappedCoordinate, toPointTo: mapView))
        } else {
            reticle.update(ghost: nil)
        }
    }

    private func updateHighlight(for result: CurbSnapResult?) {
        guard let mapView else { return }
        guard let result else {
            removeHighlight()
            return
        }
        if let current = highlightOverlay, current.blockfaceKey == result.blockfaceKey { return }
        removeHighlight()
        let state = hooks.severity(result.segment)
        let color = PlacementHighlightStyle.coreColor(for: state, traits: mapView.traitCollection)
        guard let overlay = PlacementHighlightOverlay(segment: result.segment, coreColor: color) else { return }
        highlightOverlay = overlay
        mapView.addOverlay(overlay, level: .aboveRoads)
    }

    private func removeHighlight() {
        guard let overlay = highlightOverlay else { return }
        mapView?.removeOverlay(overlay)
        highlightOverlay = nil
    }

    /// `applyOverlayPayload` removes and re-adds the curb-line overlays (every 60 s tick), which
    /// would bury the highlight underneath them - same S-1 re-insertion as the route and
    /// block-select overlays.
    func reinsertHighlight() {
        guard let mapView, let overlay = highlightOverlay else { return }
        mapView.removeOverlay(overlay)
        mapView.addOverlay(overlay, level: .aboveRoads)
    }

    // MARK: - Camera delegate hooks (called first thing from the MKMapViewDelegate callbacks)

    func regionWillChange() {
        guard !isEnded else { return }
        dwellWork?.cancel()
        dwellWork = nil

        let touch = hooks.touchDown()
        if touch {
            // A finger landed: abandon any nudge in flight; the gesture's own settle follows.
            isProgrammaticNudge = false
            nudgeSafetyWork?.cancel()
            nudgeSafetyWork = nil
            reticle.setLifted(true, reduceMotion: hooks.reduceMotion())
            if entryInProgress { finishEntry(force: true) }
        }
        // Entry flight: keep the link paused and the user-move flag clear.
        if entryInProgress { return }
        if !isProgrammaticNudge { moveWasUserInitiated = true }
        setLinkRunning(true)
    }

    func regionDidChange() {
        guard !isEnded else { return }
        if entryInProgress {
            finishEntry(force: false)
            return
        }
        // MapKit reported "settled" while a finger is still down (unverified on some OS
        // versions): not a settle. Keep running.
        if hooks.touchDown() { return }

        settle()
    }

    // MARK: - Settle

    /// The map has stopped: final resolve, drop the needle, then nudge (user move only) or fire.
    private func settle() {
        guard let mapView else { return }
        setLinkRunning(false)
        reticle.setLifted(false, reduceMotion: hooks.reduceMotion())

        let userInitiated = moveWasUserInitiated
        moveWasUserInitiated = false
        nudgeSafetyWork?.cancel()
        nudgeSafetyWork = nil

        let tip = CurbPlacementMapPolicy.tipPoint(in: mapView.bounds)
        let pin = mapView.convert(tip, toCoordinateFrom: mapView)
        // Final resolve; the settle callback (below / after the nudge) carries the result.
        resolve(
            pin: pin,
            metersPerPoint: measuredMetersPerPoint(in: mapView, tip: tip, pin: pin),
            fireOnChange: false,
            userMove: userInitiated
        )
        refreshReticle()

        if isProgrammaticNudge {
            // This region callback is the end of OUR nudge: no second nudge (spec A.3).
            isProgrammaticNudge = false
            fireSettle()
            return
        }

        if userInitiated, let snapped = lastSnapped {
            let ghost = mapView.convert(snapped.snappedCoordinate, toPointTo: mapView)
            let offset = Double(hypot(ghost.x - tip.x, ghost.y - tip.y))
            if let nudge = CurbPlacementMapPolicy.settleNudge(
                ghostOffsetPoints: offset,
                reduceMotion: hooks.reduceMotion()
            ) {
                scheduleNudge(toward: snapped.snappedCoordinate, nudge: nudge)
                return
            }
        }
        fireSettle()
    }

    /// Settle with no nudge consideration (entry correction done, or the nudge safety fired).
    private func settleWithoutNudge() {
        guard let mapView else { return }
        setLinkRunning(false)
        isProgrammaticNudge = false
        let tip = CurbPlacementMapPolicy.tipPoint(in: mapView.bounds)
        let pin = mapView.convert(tip, toCoordinateFrom: mapView)
        resolve(
            pin: pin,
            metersPerPoint: measuredMetersPerPoint(in: mapView, tip: tip, pin: pin),
            fireOnChange: false,
            userMove: false
        )
        refreshReticle()
        fireSettle()
    }

    private func scheduleNudge(toward coordinate: CLLocationCoordinate2D, nudge: PlacementNudge) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isEnded else { return }
            // A touch during the dwell abandons the nudge (design Finding 9). If that touch
            // never moves the map no region callback follows, so emit the settle now (QA #7);
            // a touch that does move the map settles again, which is harmless.
            if self.hooks.touchDown() {
                self.fireSettle()
                return
            }
            self.performNudge(toward: coordinate, nudge: nudge)
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CurbPlacementMapPolicy.nudgeDwellSeconds,
            execute: work
        )
    }

    /// Moves the map so `coordinate` ends up under the pin tip. Duration is distance-scaled via
    /// a UIView animation wrapped around a non-animated `setCenter` (MKMapView's own animated
    /// `setCenter` has no duration parameter); if MapKit ever declines to animate inside the
    /// block it degrades to an instant, still-correct jump.
    private func performNudge(toward coordinate: CLLocationCoordinate2D, nudge: PlacementNudge) {
        guard let mapView else { return }
        let bounds = mapView.bounds
        let tip = CurbPlacementMapPolicy.tipPoint(in: bounds)
        let ghost = mapView.convert(coordinate, toPointTo: mapView)
        let target = CurbPlacementMapPolicy.nudgeTargetScreenPoint(
            ghost: ghost,
            tip: tip,
            boundsCenter: CGPoint(x: bounds.midX, y: bounds.midY)
        )
        let newCenter = mapView.convert(target, toCoordinateFrom: mapView)

        isProgrammaticNudge = true
        if nudge.animated {
            UIView.animate(
                withDuration: nudge.duration,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
            ) {
                mapView.setCenter(newCenter, animated: false)
            }
        } else {
            mapView.setCenter(newCenter, animated: false)
        }

        // The flag must never stay stuck: if no region callback arrives (nothing actually
        // moved), finish the settle anyway.
        nudgeSafetyWork?.cancel()
        let safety = DispatchWorkItem { [weak self] in
            guard let self, !self.isEnded, self.isProgrammaticNudge else { return }
            self.settleWithoutNudge()
        }
        nudgeSafetyWork = safety
        DispatchQueue.main.asyncAfter(deadline: .now() + nudge.duration + 0.5, execute: safety)
    }

    // MARK: - Entry completion

    private func finishEntry(force: Bool) {
        guard entryInProgress, let mapView else { return }
        if !force {
            let arrived = CurbPlacementMapPolicy.entryArrived(
                currentCenter: mapView.camera.centerCoordinate,
                targetCenter: entryTargetCenter ?? seed,
                currentPitch: mapView.camera.pitch
            )
            // A stale callback from an interrupted animation: wait for the real landing (the
            // safety timer completes the entry regardless).
            guard arrived else { return }
        }
        entrySafetyWork?.cancel()
        entrySafetyWork = nil
        entryInProgress = false
        reticle.reveal(animated: true)

        // The entry region is EXACT (`MKCoordinateRegion`'s own centre +/- span/2 contract - see
        // `CurbPlacementMapPolicy.entrySpanDegrees`), so there is nothing left to correct: no
        // post-entry nudge, whether this finished naturally or via `force` (the old asymmetry -
        // correct only when `force == false` - was the root cause of the "pin lands mid-building"
        // report; see `begin()`'s doc comment). One resolve at the settled pin.
        settleWithoutNudge()
    }

    // MARK: - Refresh / accessibility cycle / insets

    /// The index changed underneath the mode (tiles loaded): re-resolve once at the current pin,
    /// firing only if the blockface / outcome kind changed (spec A13 "Loading curbs...").
    func refresh() {
        guard !isEnded, !entryInProgress, let mapView else { return }
        let tip = CurbPlacementMapPolicy.tipPoint(in: mapView.bounds)
        let pin = mapView.convert(tip, toCoordinateFrom: mapView)
        resolve(
            pin: pin,
            metersPerPoint: measuredMetersPerPoint(in: mapView, tip: tip, pin: pin),
            fireOnChange: true,
            userMove: false
        )
        refreshReticle()
    }

    /// VoiceOver adjustable hook (design section 4): move the pin to the nearest OTHER curb, or
    /// to the nearest curb within 100 m when none is acquired. Moves the camera instantly (same
    /// path as the settle nudge); the resulting settle fires `onPlacementOutcome`.
    ///
    /// LIMITATION (reported to the orchestrator as an A1 API request): `CurbSnapIndex` has no
    /// "list nearby blockfaces", so this reaches the nearest OTHER blockface by forcing a
    /// challenger win through a negative hysteresis band. That cycles correctly between the two
    /// curbs of a street but cannot walk a longer, distance-ordered list at a corner.
    func cycleNearbyCurb() {
        guard !isEnded, !entryInProgress, let mapView, let index = hooks.index() else { return }
        let tip = CurbPlacementMapPolicy.tipPoint(in: mapView.bounds)
        let pin = mapView.convert(tip, toCoordinateFrom: mapView)
        let metersPerPoint = measuredMetersPerPoint(in: mapView, tip: tip, pin: pin)

        let outcome: CurbSnapOutcome
        if let current = incumbentKey {
            let standard = CurbSnapConfig.standard
            let forcingChallenger = CurbSnapConfig(
                acquireRadius: standard.acquireRadius,
                releaseRadius: standard.releaseRadius,
                hysteresisPoints: 0,
                hysteresisMinMeters: -1000,
                hysteresisMaxMeters: -1000
            )
            outcome = index.resolve(pin, incumbent: current, metersPerPoint: metersPerPoint, config: forcingChallenger)
        } else {
            let wide = CurbSnapConfig(acquireRadius: 100, releaseRadius: 100)
            outcome = index.resolve(pin, incumbent: nil, metersPerPoint: metersPerPoint, config: wide)
        }
        guard case .snapped(let result) = outcome, result.blockfaceKey != incumbentKey else { return }

        incumbentKey = result.blockfaceKey  // commit to the choice so the settle resolve keeps it
        moveWasUserInitiated = false
        performNudge(toward: result.snappedCoordinate, nudge: PlacementNudge(animated: false, duration: 0))
    }

    /// Animates the camera so `coordinate` lands under the pin tip (the design's tappable
    /// "Nearest curb" chip). Same path as the settle nudge, so the normal settle / snap follows
    /// and fires `onPlacementOutcome`. No-op during the entry flight or when already there.
    func focus(on coordinate: CLLocationCoordinate2D) {
        guard !isEnded, !entryInProgress, let mapView else { return }
        let tip = CurbPlacementMapPolicy.tipPoint(in: mapView.bounds)
        let point = mapView.convert(coordinate, toPointTo: mapView)
        let offset = Double(hypot(point.x - tip.x, point.y - tip.y))
        guard let nudge = CurbPlacementMapPolicy.settleNudge(
            ghostOffsetPoints: offset,
            reduceMotion: hooks.reduceMotion()
        ) else { return }
        moveWasUserInitiated = false
        performNudge(toward: coordinate, nudge: nudge)
    }

    /// Lifts the Apple logo / Legal link above the card (design Finding 7). Called when the
    /// card's measured height changes - never per frame; `cardHeight <= 0` clears it.
    ///
    /// WHY NOT `layoutMargins.bottom = ...` round-tripped (PR #140 QA #3): with
    /// `insetsLayoutMarginsFromSafeArea == true` (the default) the `layoutMargins` GETTER can
    /// include the safe-area contribution, while the SETTER stores a raw value. Reading the
    /// getter and writing it back on exit could therefore bake the home-indicator inset into the
    /// stored margin and permanently lift the Apple logo (a double count). Instead:
    ///   1. Remember the original flag and the RAW margins (read with the flag temporarily
    ///      false, where the getter returns exactly what was stored), plus the EFFECTIVE margins
    ///      (read under the original flag - what the user currently sees).
    ///   2. While the session is live, run with the flag FALSE and explicit raw margins equal
    ///      to the effective ones except the bottom, so what is set is exactly what is drawn.
    ///   3. On exit, restore the flag and the RAW margins - never the effective ones.
    /// UNVERIFIED on device (no Xcode here): the Mac smoke checks the Apple logo / Legal link
    /// position on a notch phone before and after a session, and that the ghost stays under
    /// the tip when the inset changes (MapKit may re-centre on a margin change).
    func setBottomInset(_ cardHeight: CGFloat) {
        guard !isEnded, let mapView else { return }
        let snap: PlacementMarginSnapshot
        if let existing = marginSnapshot {
            snap = existing
        } else {
            let effective = mapView.layoutMargins
            let originalFlag = mapView.insetsLayoutMarginsFromSafeArea
            mapView.insetsLayoutMarginsFromSafeArea = false
            let raw = mapView.layoutMargins
            mapView.insetsLayoutMarginsFromSafeArea = originalFlag
            snap = PlacementMarginSnapshot(insetsFromSafeArea: originalFlag, rawMargins: raw, effectiveMargins: effective)
            marginSnapshot = snap
        }
        var applied = snap.effectiveMargins
        applied.bottom = CurbPlacementMapPolicy.bottomMargin(
            cardHeight: cardHeight,
            snapshotEffectiveBottom: snap.effectiveMargins.bottom
        )
        mapView.insetsLayoutMarginsFromSafeArea = false
        mapView.layoutMargins = applied
    }

    private func restoreMargins() {
        guard let snap = marginSnapshot, let mapView else { return }
        mapView.insetsLayoutMarginsFromSafeArea = snap.insetsFromSafeArea
        mapView.layoutMargins = snap.rawMargins
        marginSnapshot = nil
    }

    /// Stops this session WITHOUT touching the camera, zoom window or margins, because a
    /// replacement session has inherited them (`init(... replacing:)`).
    func endForReplacement() {
        guard !isEnded else { return }
        teardownTimersAndLink()
        reticle.removeFromSuperview()
        removeHighlight()
    }

    // MARK: - End

    /// - Parameter restore: true = Cancel (back to the entry camera); false = commit (keep the
    ///   street-level zoom, centre on the placed point; pitch / heading restored either way).
    func end(restore: Bool) {
        guard !isEnded else { return }
        guard let mapView else {
            teardownTimersAndLink()
            return
        }
        // Read what the exit camera needs BEFORE tearing anything down.
        let tip = CurbPlacementMapPolicy.tipPoint(in: mapView.bounds)
        let pin = mapView.convert(tip, toCoordinateFrom: mapView)
        let currentDistance = mapView.camera.centerCoordinateDistance

        teardownTimersAndLink()
        reticle.removeFromSuperview()
        removeHighlight()
        restoreMargins()
        // Widen the window BEFORE the camera move so the target is not clamped.
        mapView.setCameraZoomRange(snapshotZoomRange, animated: false)

        // Placement is a resting-posture mode (entry guard excludes drive), so the ambient look
        // is in effect exactly when its flag is on. `driveModeActive` is deliberately NOT read.
        let ambientInEffect = AmbientDrivingLook.isInEffect(
            driveModeDefaultEnabled: AppConstants.driveModeDefaultEnabled,
            driveModeActive: false
        )
        let exit = CurbPlacementMapPolicy.exitCamera(
            restoreSnapshot: restore,
            snapshot: snapshot,
            pinCoordinate: pin,
            currentDistance: currentDistance,
            ambientLookInEffect: ambientInEffect,
            ambientPitch: MapViewRepresentable.driveModePitch,
            ambientHeading: AmbientDrivingLook.heading
        )
        if let camera = mapView.camera.copy() as? MKMapCamera {
            camera.centerCoordinate = exit.center
            camera.centerCoordinateDistance = exit.distance
            camera.pitch = exit.pitch
            camera.heading = exit.heading
            // ONE animated setCamera for the whole exit transition.
            mapView.setCamera(camera, animated: !hooks.reduceMotion())
        }
    }

    private func teardownTimersAndLink() {
        isEnded = true
        entrySafetyWork?.cancel()
        dwellWork?.cancel()
        nudgeSafetyWork?.cancel()
        entrySafetyWork = nil
        dwellWork = nil
        nudgeSafetyWork = nil
        displayLink?.invalidate()
        displayLink = nil
    }
}

// MARK: - Coordinator wiring

/// Kept in this file (not in `MapViewRepresentable.swift`) so the representable's diff is only
/// the stored `placementController` property, the marked delegate hooks, and the closures that
/// call these.
extension MapViewRepresentable.Coordinator {

    func beginPlacement(seed: CLLocationCoordinate2D, incumbentKey: String?, animated: Bool) {
        guard let mapView else { return }
        let previous = placementController
        let hooks = CurbPlacementHooks(
            index: { [weak self] in
                self?.parent.placementIndex
            },
            severity: { [weak self] segment in
                self?.parent.placementSeverity?(segment) ?? CurrentState.unknown
            },
            touchDown: { [weak self] in
                guard let self else { return false }
                return CurbPlacementMapPolicy.isTouchDown(
                    panState: self.panGesture?.state,
                    pinchState: self.pinchGesture?.state
                )
            },
            reduceMotion: {
                UIAccessibility.isReduceMotionEnabled
            },
            fireOutcome: { [weak self] outcome in
                self?.parent.onPlacementOutcome?(outcome)
            }
        )
        let controller = CurbPlacementController(
            mapView: mapView,
            seed: seed,
            incumbentKey: incumbentKey,
            hooks: hooks,
            replacing: previous
        )
        // QA #4: begin-while-live REPLACES the session (the old one ends WITHOUT restoring its
        // camera; the new one inherited the original snapshot). Never silently ignored.
        previous?.endForReplacement()
        placementController = controller
        controller.begin(animated: animated)
    }

    func endPlacement(restore: Bool) {
        guard let controller = placementController else { return }
        controller.end(restore: restore)
        placementController = nil
    }
}
