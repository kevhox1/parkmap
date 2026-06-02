//
//  PinMarkerAnnotation.swift
//  WePark
//
//  Tier 1 Pin Display — map annotation types for community pins.
//  Spec: docs/tier1-pin-display-spec.md §7.
//
//  Contents:
//   - CommunityPin display extension — displayTitle / displaySubtitle computed properties.
//   - CommunityPinAnnotation — MKAnnotation conformance wrapping CommunityPin.
//   - PinMarkerAnnotation — MKAnnotationView subclass with SF Symbol circle marker.
//
//  Visual spec (§7.1):
//   - filming:      video.fill symbol, Color.purple circle, 32×32pt image, 44×44pt touch target.
//   - special_event: star.fill symbol,  Color.orange circle, 32×32pt image, 44×44pt touch target.
//
//  Time formatting:
//   - "Until HH:mm" if expires_at is within the current day (ET).
//   - "Until <date>" if expires_at is on a future date.
//   - All time logic uses Calendar.easternTime (W3 convention — zero Calendar.current).
//
//  Invariants:
//   - No Calendar.current (W3 convention / AC-D19).
//   - No force-unwraps.
//   - CommunityPin.swift is NOT modified — display extensions live here (AC-D20).
//

import Foundation
import MapKit
import UIKit

// MARK: - CommunityPin display extensions

extension CommunityPin {

    /// Short display title for the annotation callout and sheet header.
    ///
    /// filming:       `FilmingMeta.productionName` if non-nil, else "Filming".
    /// special_event: `SpecialEventMeta.eventName`.
    /// other types:   fallback label from pinType.displayLabel.
    var displayTitle: String? {
        switch pinType {
        case .filming:
            if case .filming(let m) = meta, let name = m.productionName {
                return name
            }
            return "Filming"
        case .specialEvent:
            if case .specialEvent(let m) = meta {
                return m.eventName
            }
            return "Special Event"
        default:
            return pinType.displayLabel
        }
    }

    /// Short subtitle line shown under the callout title.
    ///
    /// Formatted as "Until HH:mm" (same-day ET) or "Until <date>" (future).
    /// Returns nil if `expiresAt` is nil.
    var displaySubtitle: String? {
        guard let expiresAt else { return nil }
        return CommunityPin.formatExpiry(expiresAt)
    }

    // MARK: - Internal helpers

    /// Formats an expiry Date for the subtitle / detail sheet.
    ///
    /// If `expiresAt` is the same calendar day as now (ET), returns "Until HH:mm".
    /// Otherwise returns "Until <abbreviated date>".
    ///
    /// Uses `Calendar.easternTime` — no `Calendar.current` (AC-D19).
    static func formatExpiry(_ expiresAt: Date) -> String {
        let cal = Calendar.easternTime
        let now = Date()

        if cal.isDate(expiresAt, inSameDayAs: now) {
            // Same ET calendar day — show time only.
            let formatter = DateFormatter()
            formatter.timeZone = .easternTime
            formatter.dateFormat = "HH:mm"
            return "Until \(formatter.string(from: expiresAt))"
        } else {
            // Different day — show abbreviated date + time.
            let formatter = DateFormatter()
            formatter.timeZone = .easternTime
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return "Until \(formatter.string(from: expiresAt))"
        }
    }
}

// MARK: - PinType display helpers

extension PinType {
    /// Human-readable label for display surfaces.
    var displayLabel: String {
        switch self {
        case .filming:           return "Filming"
        case .aspSuspendedToday: return "ASP Suspended"
        case .specialEvent:      return "Special Event"
        case .construction:      return "Construction"
        case .signCorrection:    return "Sign Correction"
        case .blockNote:         return "Block Note"
        case .enforcementActive: return "Enforcement Active"
        case .sweeperPassed:     return "Sweeper Passed"
        case .brokenMeter:       return "Broken Meter"
        case .parkedCar:         return "Parked Car"
        }
    }
}

// MARK: - CommunityPinAnnotation

/// Lightweight `MKAnnotation` wrapper for a `CommunityPin`.
///
/// Conforms to `NSObject` (required by MKAnnotation) and `MKAnnotation`.
/// The annotation's `coordinate`, `title`, and `subtitle` are derived from the pin.
///
/// Tap handling: `Coordinator.mapView(_:didSelect:)` casts to `CommunityPinAnnotation`
/// and fires `activeSheet = .pinDetail(annotation.pin)` (spec §7.4).
final class CommunityPinAnnotation: NSObject, MKAnnotation {

    let pin: CommunityPin

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng)
    }

    var title: String? { pin.displayTitle }
    var subtitle: String? { pin.displaySubtitle }

    init(pin: CommunityPin) {
        self.pin = pin
    }
}

// MARK: - PinMarkerAnnotation (MKAnnotationView subclass)

/// Custom `MKAnnotationView` for `filming` and `special_event` community pins.
///
/// Renders a filled circle with an SF Symbol inside:
///   - filming:       purple circle, video.fill symbol (32×32pt image, 44×44pt touch target)
///   - special_event: orange circle, star.fill symbol
///
/// Not used for `asp_suspended_today` — that pin type drives the ASP banner, not a map marker.
///
/// Reuse: registered in `MapViewRepresentable.makeUIView` and dequeued in
/// `mapView(_:viewFor:)` via `reuseIdentifier`.
final class PinMarkerAnnotation: MKAnnotationView {

    // MARK: - Constants

    static let reuseIdentifier = "CommunityPinMarker"

    /// Rendered image size in points (spec §7.1: 32×32pt).
    private static let imageSize: CGFloat = 32

    /// Touch target frame (spec §7.1: HIG minimum 44×44pt).
    private static let touchTargetSize: CGFloat = 44

    // MARK: - Init

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }

    private func setup() {
        // Touch target: 44×44pt as required by HIG.
        frame = CGRect(x: 0, y: 0, width: Self.touchTargetSize, height: Self.touchTargetSize)
        centerOffset = .zero

        // Callout: tapping the callout disclosure button triggers the detail sheet.
        // The right detail button is wired via `mapView(_:annotationView:calloutAccessoryControlTapped:)`
        // in MapViewRepresentable.Coordinator.
        canShowCallout = true
        rightCalloutAccessoryView = UIButton(type: .detailDisclosure)

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    // MARK: - Configure

    /// Configures the annotation view for the given `CommunityPin`.
    ///
    /// Called from `mapView(_:viewFor:)` after dequeue.
    /// Updates the image and accessibility label to match the pin type.
    ///
    /// - Parameter pin: The `CommunityPin` this marker represents.
    func configure(for pin: CommunityPin) {
        image = Self.markerImage(for: pin.pinType)
        // Center the 32×32 image within the 44×44 touch target.
        centerOffset = .zero
        accessibilityLabel = "\(pin.pinType.displayLabel): \(pin.displayTitle ?? "")"
        if let subtitle = pin.displaySubtitle {
            accessibilityValue = subtitle
        }
    }

    // MARK: - Marker image rendering

    /// Renders a 32×32pt circular marker with the appropriate SF Symbol.
    ///
    /// Uses `UIGraphicsImageRenderer` for crisp rendering at any display scale.
    /// Colors (spec §7.1):
    ///   - filming:       `UIColor.systemPurple`
    ///   - special_event: `UIColor.systemOrange`
    private static func markerImage(for pinType: PinType) -> UIImage? {
        let (symbolName, circleColor) = markerStyle(for: pinType)
        let size = CGSize(width: imageSize, height: imageSize)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            // Draw filled circle background.
            circleColor.setFill()
            let circleRect = CGRect(origin: .zero, size: size)
            UIBezierPath(ovalIn: circleRect).fill()

            // Draw SF Symbol centered in the circle.
            let symbolSize = imageSize * 0.55  // 55% of circle diameter for visual balance.
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
            guard let symbol = UIImage(systemName: symbolName, withConfiguration: symbolConfig)?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            else { return }

            let symbolRect = CGRect(
                x: (imageSize - symbol.size.width) / 2,
                y: (imageSize - symbol.size.height) / 2,
                width: symbol.size.width,
                height: symbol.size.height
            )
            symbol.draw(in: symbolRect)
        }
    }

    /// Returns the SF Symbol name and circle fill color for the given pin type.
    private static func markerStyle(for pinType: PinType) -> (symbolName: String, color: UIColor) {
        switch pinType {
        case .filming:
            return ("video.fill", UIColor.systemPurple)
        case .specialEvent:
            return ("star.fill", UIColor.systemOrange)
        default:
            // Fallback for any type that reaches this path unexpectedly.
            return ("mappin.fill", UIColor.systemGray)
        }
    }
}
