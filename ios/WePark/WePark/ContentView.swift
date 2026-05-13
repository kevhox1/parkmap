//
//  ContentView.swift
//  WePark
//
//  Rendering architecture: UIKit MKMapView via MapViewRepresentable (UIViewRepresentable).
//  This replaces the SwiftUI Map + MapPolyline approach used in W2–W4.
//
//  Root cause of the replacement (2026-05-11):
//  SwiftUI MapPolyline inside @MapContentBuilder is disqualified at 40,664-segment density.
//  40,664 segments × ~30 Metal resources each = 1.22M GPU resources, 25× over MapKit's
//  50,000-resource VectorKit limit. Process RSS reached 19.92 GB. The VectorKit pruner
//  fired "Exceeded Metal Buffer threshold of 50000 with a count of 1262055 resources".
//
//  Current approach: 6 MKMultiPolyline overlays (5 state groups + 1 selected-block highlight).
//  6 Metal resource groups total. Under the threshold by a factor of 8,000.
//  See: docs/ios-rendering-architecture-decision.md
//
//  What changed vs the W4 + fix-pass-1 branch (f2595f1):
//    - Replaced: Map { polylineContent } + @MapContentBuilder + MapReader
//    - Replaced: SwiftUI onTapGesture → UITapGestureRecognizer in MapViewRepresentable.Coordinator
//    - Kept: ParkingRulesEngine, TileLoader, ASPSuspensionService, all Models
//    - Kept: BlockDetailView, sheet presentation mechanics (.sheet(isPresented:))
//    - Kept: handleMapTap / pointToPolylineDistance / haversine (only gesture source changes)
//    - Kept: 60s timer cadence; now also drives overlay recompute (replaces per-polyline recompute)
//    - Kept: polylineHideSpanThreshold = 0.1 (zoom gating — hides overlays when zoomed out)
//    - Raised: maxCachedTiles from 50 → 200 (see TileLoader.swift; per decision doc §3 rationale)
//
//  W4 fix-pass-1 carry-overs still in effect:
//    - No Annotation overlay (VoiceOver map-navigation of individual blocks is post-MVP)
//    - Sheet dismiss via onDismiss closure (not concurrent with animation)
//    - A11y: safety label is first focusable element, ✕ reads "Close block details"
//
//  W5 additions:
//    - ParkPinService: @State var parkPinService (loaded on appear)
//    - @State var pinDropIntent: PinDropIntent? — drives ParkConfirmView sheet
//    - @State var parkedCarDetailItem: ParkedCar? — drives ParkedCarDetailView sheet
//    - Long-press → handleLongPress(at:) → segment detection → ParkConfirmView
//    - "Park here →" button in BlockDetailView wired via onParkHere closure
//    - Car pin annotation in MapViewRepresentable driven by parkPinService.parkedCar
//    - ParkedCarDetailView sheet on car-pin tap
//    - findCandidateSegments: multi-candidate search for "Wrong street?" alternatives
//
//  W5.1 additions (polish pass):
//    - Recenter buttons overlay (top-right): "Find me" (location.fill) + "Find my car" (car.fill)
//    - LocationService: CLLocationManager wrapper for .whenInUse permission + single-shot fix
//    - MKMapView.showsUserLocation = true (blue dot when permission granted)
//    - QA Fix #1: pinDropped.send() moved inside do-catch block in ParkPinService.save()
//    - QA Fix #2: "Wrong street?" alternatives list rebuilt after selection in ParkConfirmView
//
//  Sheet stacking: SwiftUI allows only one .sheet(item:) to be active at a time.
//  ContentView manages mutually-exclusive presentation:
//    - pinDropIntent → ParkConfirmView (dismisses blockDetailSegment if set)
//    - parkedCarDetailItem → ParkedCarDetailView
//    - selectedSegmentID → BlockDetailView
//  All are separate .sheet(item:) bindings. SwiftUI handles the constraint.
//

import SwiftUI
import MapKit
import Combine

struct ContentView: View {

    // MARK: - State

    /// Current map region — kept in @State so ContentView owns the camera.
    /// Passed to MapViewRepresentable as a Binding; updated by the regionChanged callback.
    @State private var region: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(
            latitude: AppConstants.manhattanCenter.latitude,
            longitude: AppConstants.manhattanCenter.longitude
        ),
        span: MKCoordinateSpan(latitudeDelta: 0.07, longitudeDelta: 0.05)
    )

    @State private var tileLoader = TileLoader()
    @State private var engine = ParkingRulesEngine()

    /// Flipped every 60 seconds to drive overlay recompute.
    @State private var lastEvaluatedAt: Date = .now

    /// W4: Selected segment ID. Drives highlight overlay + BlockDetailView sheet.
    @State private var selectedSegmentID: String? = nil

    /// W4: BlockDetailView sheet presentation (driven by selectedSegmentID).
    @State private var isSheetPresented: Bool = false

    /// W5: In-flight pin-drop intent. Non-nil → ParkConfirmView is presented.
    @State private var pinDropIntent: PinDropIntent? = nil

    /// W5: Parked-car detail item. Non-nil → ParkedCarDetailView is presented.
    @State private var parkedCarDetailItem: ParkedCar? = nil

    /// W5: Single-pin persistence service. Loaded once at app launch.
    @State private var parkPinService = ParkPinService()

    /// W5.1: User location service for the recenter button.
    @State private var locationService = LocationService()

    /// W5.1: Set to true when the user taps "Recenter on my location".
    /// Cleared after the next userLocation update triggers the recenter.
    @State private var recenterOnUserRequested: Bool = false

    /// Overlay payload passed into MapViewRepresentable.
    /// Rebuilt on every tick or when selectedSegmentID changes.
    @State private var overlayPayload = MapViewRepresentable.OverlayPayload()

    /// Generation counter: incremented each time we rebuild overlays.
    /// MapViewRepresentable.OverlayPayload.== compares only generation,
    /// so the UIView update path fires exactly when we want it to.
    @State private var overlayGeneration: Int = 0

    // MARK: - Constants

    /// Hide all overlays when zoomed out beyond this span (same as W2/W3 behavior).
    private let polylineHideSpanThreshold: Double = 0.1

    /// Tap hit threshold in meters (matches W4 behavior).
    private let tapHitThresholdMeters: Double = 20.0

    /// W5: Radius for candidate-segment search (matches PWA findCandidateSegments).
    private let pinDropRadiusMeters: Double = 35.0

    // MARK: - Derived

    private var selectedSegment: Segment? {
        guard let id = selectedSegmentID else { return nil }
        return tileLoader.segments.first { $0.id == id }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MapViewRepresentable(
                region: $region,
                selectedSegmentID: $selectedSegmentID,
                onTap: { coordinate in
                    handleMapTap(at: coordinate)
                },
                onLongPress: { coordinate in
                    handleLongPress(at: coordinate)
                },
                onRegionChanged: { newRegion in
                    region = newRegion
                    tileLoader.loadTiles(forRegion: newRegion)
                },
                onCarPinTapped: {
                    openParkedCarDetail()
                },
                carPin: parkPinService.parkedCar,
                overlayPayload: overlayPayload
            )
            // Map fills the full screen including safe area.
            .ignoresSafeArea()

            // W5.1: Recenter buttons — top-right, below status bar and compass rose.
            // Using padding(.top, 60) positions them below the ~44pt status bar
            // plus the MapKit compass rose (which lives at the top-right by default).
            recenterButtonStack
                .padding(.top, 60)
                .padding(.trailing, 12)
        }
        .task {
            // W5: Load persisted car pin on app launch.
            parkPinService.load()

            tileLoader.loadTiles(forRegion: region)
            lastEvaluatedAt = .now
            rebuildOverlays(at: lastEvaluatedAt)
        }
        .onAppear {
            lastEvaluatedAt = .now
        }
        .onReceive(
            Timer.publish(every: 60, on: .main, in: .common).autoconnect()
        ) { _ in
            lastEvaluatedAt = .now
            rebuildOverlays(at: lastEvaluatedAt)
        }
        // Rebuild overlays when segments change (tile load completes).
        .onChange(of: tileLoader.segments.count) { _, _ in
            rebuildOverlays(at: lastEvaluatedAt)
        }
        // Rebuild selected-block highlight when selection changes.
        .onChange(of: selectedSegmentID) { _, _ in
            rebuildOverlays(at: lastEvaluatedAt)
        }
        // W5.1: Recenter on user when a new location fix arrives after a recenter request.
        // CLLocationCoordinate2D is not Equatable, so we observe a counter instead.
        .onChange(of: locationService.locationUpdateCount) { _, _ in
            guard recenterOnUserRequested, let loc = locationService.userLocation else { return }
            recenterOnUserRequested = false
            recenterMap(on: loc)
        }
        // W4: BlockDetailView sheet.
        .sheet(isPresented: $isSheetPresented, onDismiss: {
            selectedSegmentID = nil
        }) {
            if let segment = selectedSegment {
                BlockDetailView(
                    segment: segment,
                    engine: engine,
                    onDismiss: { dismissBlockDetail() },
                    onParkHere: {
                        // W5: Path B — segment already known; use midpoint as coordinate.
                        initiatePathBPinDrop(from: segment)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(20)
            }
        }
        // W5: ParkConfirmView sheet.
        .sheet(item: $pinDropIntent) { intent in
            ParkConfirmView(
                intent: intent,
                engine: engine,
                onConfirm: { confirmedIntent in
                    pinDropIntent = nil
                    confirmPinDrop(intent: confirmedIntent)
                },
                onCancel: {
                    pinDropIntent = nil
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)
        }
        // W5: ParkedCarDetailView sheet.
        .sheet(item: $parkedCarDetailItem) { car in
            ParkedCarDetailView(
                parkedCar: car,
                engine: engine,
                loadedSegments: tileLoader.segments,
                onDismiss: {
                    parkedCarDetailItem = nil
                },
                onClearPin: {
                    parkedCarDetailItem = nil
                    parkPinService.clearPin()
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationCornerRadius(20)
        }
    }

    // MARK: - Overlay rebuild

    /// Partitions loaded segments by current state → 5 MKMultiPolyline coordinate groups
    /// + selected-block highlight coordinates, then bumps the generation to trigger
    /// a MapViewRepresentable update.
    ///
    /// This is O(n) over loaded segments (~500–2,000 at street-level zoom).
    /// Called on:
    ///   - 60s timer tick
    ///   - Segment array change (tile load complete)
    ///   - Selection change
    private func rebuildOverlays(at now: Date) {
        // Zoom-threshold gating: if zoomed out, clear all overlays.
        guard region.span.latitudeDelta <= polylineHideSpanThreshold else {
            overlayGeneration += 1
            overlayPayload = MapViewRepresentable.OverlayPayload(generation: overlayGeneration)
            return
        }

        var freeComfortably:        [[CLLocationCoordinate2D]] = []
        var freeButRestrictionSoon: [[CLLocationCoordinate2D]] = []
        var meteredActive:          [[CLLocationCoordinate2D]] = []
        var restrictedNow:          [[CLLocationCoordinate2D]] = []
        var unknown:                [[CLLocationCoordinate2D]] = []

        for segment in tileLoader.segments {
            let coords = segment.coordinates
            guard coords.count >= 2 else { continue }
            // Skip the selected segment from group overlays — it will be rendered
            // by the selectedBlock overlay at lineWidth:6 instead.
            if segment.id == selectedSegmentID { continue }
            let state = engine.currentState(for: segment, at: now)
            switch state {
            case .freeComfortably:        freeComfortably.append(coords)
            case .freeButRestrictionSoon: freeButRestrictionSoon.append(coords)
            case .meteredActive:          meteredActive.append(coords)
            case .restrictedNow:          restrictedNow.append(coords)
            case .unknown:                unknown.append(coords)
            }
        }

        // Selected-block highlight.
        var selectedCoords: [CLLocationCoordinate2D]? = nil
        var selectedState: CurrentState = .unknown
        if let seg = selectedSegment {
            let coords = seg.coordinates
            if coords.count >= 2 {
                selectedCoords = coords
                selectedState = engine.currentState(for: seg, at: now)
            }
        }

        overlayGeneration += 1
        overlayPayload = MapViewRepresentable.OverlayPayload(
            freeComfortably:        freeComfortably,
            freeButRestrictionSoon: freeButRestrictionSoon,
            meteredActive:          meteredActive,
            restrictedNow:          restrictedNow,
            unknown:                unknown,
            selectedCoords:         selectedCoords,
            selectedState:          selectedState,
            generation:             overlayGeneration
        )
    }

    // MARK: - W5.1: Recenter button stack

    /// Two vertically-stacked recenter buttons, shown in the top-right of the map.
    /// "Find me" is always shown. "Find my car" is shown only when a pin exists.
    @ViewBuilder
    private var recenterButtonStack: some View {
        VStack(spacing: 8) {
            // "Find me" — recenter on user's current GPS location.
            Button {
                recenterOnUser()
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel("Recenter on my location")
            .accessibilityHint("Moves the map to show your current GPS position.")

            // "Find my car" — shown only when a parked-car pin exists.
            if parkPinService.parkedCar != nil {
                Button {
                    recenterOnCar()
                } label: {
                    Image(systemName: "car.fill")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel("Recenter on my parked car")
                .accessibilityHint("Moves the map to show where you parked.")
            }
        }
    }

    // MARK: - W5.1: Recenter actions

    /// Requests user location and recenters when the fix arrives.
    /// If a cached location is available, recenters immediately and also refreshes
    /// the fix so the next tap will have an up-to-date position.
    private func recenterOnUser() {
        if let loc = locationService.userLocation {
            // We have a cached fix — recenter immediately.
            recenterMap(on: loc)
            // Also request a fresh fix in the background for next use.
            locationService.requestAndFetchLocation()
        } else {
            // No fix yet — request one; .onChange(of: locationService.userLocation)
            // will fire when the fix arrives and complete the recenter.
            recenterOnUserRequested = true
            locationService.requestAndFetchLocation()
        }
    }

    /// Recenters the map on the parked car pin.
    private func recenterOnCar() {
        guard let car = parkPinService.parkedCar else { return }
        let coord = CLLocationCoordinate2D(latitude: car.latitude, longitude: car.longitude)
        recenterMap(on: coord)
    }

    /// Animates the map region to center on the given coordinate at street-level zoom.
    /// ~400m span shows the target block plus a few surrounding blocks.
    private func recenterMap(on coordinate: CLLocationCoordinate2D) {
        region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 400,
            longitudinalMeters: 400
        )
    }

    // MARK: - Dismiss helpers

    /// Triggers the BlockDetailView dismiss animation.
    private func dismissBlockDetail() {
        isSheetPresented = false
    }

    // MARK: - Tap handling (unchanged from W4 — only gesture source changed)

    private func handleMapTap(at coordinate: CLLocationCoordinate2D) {
        guard !tileLoader.segments.isEmpty else {
            dismissBlockDetail()
            return
        }

        var closestID: String? = nil
        var closestDistance: Double = .infinity

        for segment in tileLoader.segments {
            let coords = segment.coordinates
            guard coords.count >= 2 else { continue }
            let dist = pointToPolylineDistance(from: coordinate, polyline: coords)
            if dist < closestDistance {
                closestDistance = dist
                closestID = segment.id
            }
        }

        if closestDistance <= tapHitThresholdMeters, let id = closestID {
            selectedSegmentID = id
            isSheetPresented = true
        } else {
            dismissBlockDetail()
        }
    }

    // MARK: - W5: Long-press handling

    private func handleLongPress(at coordinate: CLLocationCoordinate2D) {
        // Dismiss any open BlockDetailView — only one sheet at a time.
        isSheetPresented = false
        selectedSegmentID = nil

        // Run candidate-segment detection (Path A).
        let candidates = findCandidateSegments(
            lat: coordinate.latitude,
            lng: coordinate.longitude,
            radius: pinDropRadiusMeters,
            max: 4
        )

        let detected = candidates.first?.segment
        let detectedDistance = candidates.first?.distanceMeters
        let alternatives = Array(candidates.dropFirst())

        pinDropIntent = PinDropIntent(
            pinLat: coordinate.latitude,
            pinLng: coordinate.longitude,
            detectedSegment: detected,
            detectedSegmentDistance: detectedDistance,
            alternativeCandidates: alternatives
        )
    }

    // MARK: - W5: "Park here →" Path B (from BlockDetailView)

    private func initiatePathBPinDrop(from segment: Segment) {
        // Dismiss BlockDetailView first.
        isSheetPresented = false
        selectedSegmentID = nil

        // Path B: segment already known; coordinate is midpoint (spec §3.2).
        // If midpoint is nil (malformed segment), fall back to first coordinate.
        let midpoint = segment.midpoint ?? segment.coordinates.first
        guard let coord = midpoint else { return }

        // No alternative candidates for Path B (user already picked this block).
        // detectedSegmentDistance is nil for Path B — no "Wrong street?" alternatives.
        pinDropIntent = PinDropIntent(
            pinLat: coord.latitude,
            pinLng: coord.longitude,
            detectedSegment: segment,
            detectedSegmentDistance: nil,
            alternativeCandidates: []
        )
    }

    // MARK: - W5: Confirm pin drop (from ParkConfirmView)

    private func confirmPinDrop(intent: PinDropIntent) {
        let car = ParkedCar(
            id: UUID(),
            latitude: intent.pinLat,
            longitude: intent.pinLng,
            detectedSegmentID: intent.detectedSegment?.id,
            detectedSide: intent.detectedSegment?.side,
            street: intent.detectedSegment?.street,
            fromStreet: intent.detectedSegment?.fromStreet,
            toStreet: intent.detectedSegment?.to,
            parkedAt: .nowET
        )
        parkPinService.save(car)
    }

    // MARK: - W5: Open ParkedCarDetailView

    private func openParkedCarDetail() {
        guard let car = parkPinService.parkedCar else { return }
        parkedCarDetailItem = car
    }

    // MARK: - W5: findCandidateSegments

    /// Finds segments within `radius` meters of the given coordinate, sorted by distance.
    /// Port of findCandidateSegments() at index.html:5096-5111.
    ///
    /// Deduplication: groups by block key (street|from|to) — the same block face may
    /// span multiple segments. Returns the closest segment per unique block key.
    /// Returns up to `max` results.
    ///
    /// This is the multi-candidate version of the haversine point-to-segment search
    /// already used in handleMapTap. W5 spec §4.2 path A.
    private func findCandidateSegments(
        lat: Double,
        lng: Double,
        radius: Double,
        max maxResults: Int
    ) -> [CandidateSegment] {

        let tapCoord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        // Track closest segment per block key (street|from|to) to deduplicate.
        var bestByBlockKey: [String: (segment: Segment, distance: Double)] = [:]

        for segment in tileLoader.segments {
            let coords = segment.coordinates
            guard coords.count >= 2 else { continue }
            let dist = pointToPolylineDistance(from: tapCoord, polyline: coords)
            guard dist <= radius else { continue }

            // Block key: same as the PWA's dedup key — street|from|to (case-insensitive).
            // We keep all-caps (as stored in tile data) for consistency.
            let key = "\(segment.street)|\(segment.fromStreet)|\(segment.to)"
            if let existing = bestByBlockKey[key] {
                if dist < existing.distance {
                    bestByBlockKey[key] = (segment, dist)
                }
            } else {
                bestByBlockKey[key] = (segment, dist)
            }
        }

        // Sort by distance, take top `maxResults`.
        return bestByBlockKey.values
            .sorted { $0.distance < $1.distance }
            .prefix(maxResults)
            .map { CandidateSegment(segment: $0.segment, distanceMeters: $0.distance) }
    }

    // MARK: - Geometry helpers (unchanged from W4)

    private func pointToPolylineDistance(from point: CLLocationCoordinate2D,
                                          polyline: [CLLocationCoordinate2D]) -> Double {
        var minDist = Double.infinity
        for i in 0..<(polyline.count - 1) {
            let d = pointToSegmentDistance(point: point, a: polyline[i], b: polyline[i + 1])
            if d < minDist { minDist = d }
        }
        return minDist
    }

    private func pointToSegmentDistance(point: CLLocationCoordinate2D,
                                        a: CLLocationCoordinate2D,
                                        b: CLLocationCoordinate2D) -> Double {
        let metersPerDegLat = 111_320.0
        let cosLat = cos(a.latitude * .pi / 180.0)
        let metersPerDegLng = metersPerDegLat * cosLat

        let px = (point.longitude - a.longitude) * metersPerDegLng
        let py = (point.latitude  - a.latitude)  * metersPerDegLat
        let bx = (b.longitude - a.longitude) * metersPerDegLng
        let by = (b.latitude  - a.latitude)  * metersPerDegLat

        let abLenSq = bx * bx + by * by
        if abLenSq == 0 {
            return haversine(from: point, to: a)
        }

        let t = max(0, min(1, (px * bx + py * by) / abLenSq))
        let closestX = t * bx
        let closestY = t * by
        let closestLat = a.latitude  + closestY / metersPerDegLat
        let closestLng = a.longitude + closestX / metersPerDegLng
        let closest = CLLocationCoordinate2D(latitude: closestLat, longitude: closestLng)
        return haversine(from: point, to: closest)
    }

    private func haversine(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let sinHalfLat = sin(dLat / 2)
        let sinHalfLng = sin(dLng / 2)
        let h = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLng * sinHalfLng
        return 2 * R * asin(sqrt(h))
    }

}

#Preview {
    ContentView()
}
