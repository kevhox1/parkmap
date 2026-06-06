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

    /// Callout subtitle.
    ///
    /// Tier 3 sub-PR #2: For `enforcement_active` and `sweeper_passed` pins, the subtitle
    /// shows the time-since badge ("Just now", "5m ago") rather than the expiry time.
    /// This matches the T3-3 decision: ephemeral pins show age, not expiry countdown.
    /// The badge is computed lazily at callout-open time (no timer loop).
    var subtitle: String? {
        switch pin.pinType {
        case .enforcementActive, .sweeperPassed:
            return PinMarkerAnnotation.timeSinceBadge(pin: pin, now: Date())
        default:
            return pin.displaySubtitle
        }
    }

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
    /// Tier 3 sub-PR #2: For `enforcement_active` and `sweeper_passed` pins,
    /// the callout subtitle shows the time-since badge ("Just now", "5m ago", etc.)
    /// computed by `PinMarkerAnnotation.timeSinceBadge(pin:now:)`.
    ///
    /// - Parameter pin: The `CommunityPin` this marker represents.
    func configure(for pin: CommunityPin) {
        // Fix 3: markerImage(for:) always returns a non-nil UIImage (filled circle fallback).
        image = Self.markerImage(for: pin.pinType)
        // Center the 32×32 image within the 44×44 touch target.
        centerOffset = .zero

        // Tier 3 sub-PR #2: Time-since badge in callout subtitle for ephemeral crowd pins.
        // Pure function — no timer loop; computed lazily at callout-open time (T3-3 decision).
        //
        // Accessibility labels for Tier 3 pins use the format from docs/design/tier3-marker-icons.md §2–3:
        //   enforcement_active: "Enforcement active" (+ "— <SubTag>" if sub_tag present)
        //   sweeper_passed:     "Sweeper passed" or "Sweeper approaching" per direction field
        // These are set here rather than falling through to displayLabel to avoid the
        // redundant "<Label>: <Label>" pattern and to match the spec's label strings exactly.
        switch pin.pinType {
        case .enforcementActive:
            // Design note §2: label = "Enforcement active" (+ sub_tag suffix if present).
            // Sub_tag display strings per design note §2: "Parking agent", "Cleaning truck", "Tow truck".
            if case .enforcementActive(let m) = pin.meta, let subTag = m.subTag {
                let subTagLabel: String
                switch subTag {
                case .parkingAgent:  subTagLabel = "Parking agent"
                case .cleaningTruck: subTagLabel = "Cleaning truck"
                case .towTruck:      subTagLabel = "Tow truck"
                }
                accessibilityLabel = "Enforcement active — \(subTagLabel)"
            } else {
                accessibilityLabel = "Enforcement active"
            }
            let badge = Self.timeSinceBadge(pin: pin, now: Date())
            accessibilityValue = badge
            // The callout subtitle is driven by CommunityPinAnnotation.subtitle.
        case .sweeperPassed:
            // Design note §3: label reflects direction field (.comingSoon → "Sweeper approaching";
            // .passed or nil → "Sweeper passed").
            if case .sweeperPassed(let m) = pin.meta {
                accessibilityLabel = m.direction == .comingSoon ? "Sweeper approaching" : "Sweeper passed"
            } else {
                accessibilityLabel = "Sweeper passed"
            }
            let badge = Self.timeSinceBadge(pin: pin, now: Date())
            accessibilityValue = badge
        default:
            accessibilityLabel = "\(pin.pinType.displayLabel): \(pin.displayTitle ?? "")"
            if let subtitle = pin.displaySubtitle {
                accessibilityValue = subtitle
            }
        }
    }

    // MARK: - Time-since badge (T3-3, AC-R25–R28)

    /// Returns a human-readable "age since creation" string for a community pin.
    ///
    /// Pure function — `now: Date` is injected for testability.
    /// In the live app, callers pass `Date()`. Tests pass a fixed fixture.
    ///
    /// Rules (spec §5):
    ///   - age < 60s  → "Just now"
    ///   - 1–59 min   → "Xm ago"
    ///   - 60–119 min → "1h ago"
    ///   - ≥120 min   → "Xh ago"
    ///
    /// No `Calendar.current` or `Calendar.easternTime` usage — pure `timeIntervalSince`
    /// arithmetic only (W3 convention / AC-R28).
    static func timeSinceBadge(pin: CommunityPin, now: Date) -> String {
        let ageSeconds = now.timeIntervalSince(pin.createdAt)
        let minutes = Int(ageSeconds / 60)
        switch minutes {
        case ..<1:       return "Just now"
        case 1..<60:     return "\(minutes)m ago"
        case 60..<120:   return "1h ago"
        default:         return "\(minutes / 60)h ago"
        }
    }

    // MARK: - Marker image rendering

    /// Renders a 32×32pt circular marker with the appropriate SF Symbol.
    ///
    /// Uses `UIGraphicsImageRenderer` for crisp rendering at any display scale.
    /// Colors (spec §7.1):
    ///   - filming:       `UIColor.systemPurple`
    ///   - special_event: `UIColor.systemOrange`
    ///
    /// Fix 3 — Marker safety net: if `UIImage(systemName:)` fails to resolve (e.g. the
    /// symbol name is bad or the SF Symbol isn't available on this OS version), the SF
    /// Symbol drawing step is skipped and the method returns the plain filled circle.
    /// A pin NEVER silently disappears — at minimum a solid-color disc renders.
    private static func markerImage(for pinType: PinType) -> UIImage {
        let (symbolName, circleColor) = markerStyle(for: pinType)
        let size = CGSize(width: imageSize, height: imageSize)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { _ in
            // Draw filled circle background.
            // Fix 3: the circle is always drawn — even if the SF Symbol is unavailable,
            // the caller gets a non-nil solid-color disc instead of nil (no marker).
            circleColor.setFill()
            let circleRect = CGRect(origin: .zero, size: size)
            UIBezierPath(ovalIn: circleRect).fill()

            // Draw SF Symbol centered in the circle.
            // If UIImage(systemName:) returns nil (bad symbol name, OS version mismatch, etc.)
            // we skip the symbol step and return just the filled circle (Fix 3 safety net).
            let symbolSize = imageSize * 0.55  // 55% of circle diameter for visual balance.
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
            guard let symbol = UIImage(systemName: symbolName, withConfiguration: symbolConfig)?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            else {
                // Safety net (Fix 3): SF Symbol unavailable — the filled circle is the marker.
                // This path is never reached for the four known-good symbols at iOS 17+
                // (video.fill, star.fill, person.badge.clock.fill, truck.box.fill are all
                // SF Symbols 5 / iOS 17+), but protects against future regressions.
                return
            }

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
    ///
    /// Icon/color assignments per docs/design/tier3-marker-icons.md:
    ///   - filming:            video.fill (purple)      — Tier 1 / authoritative
    ///   - special_event:      star.fill (orange)       — Tier 1 / authoritative
    ///   - enforcement_active: person.badge.clock.fill (teal)  — Tier 3 / ephemeral crowd (§2)
    ///   - sweeper_passed:     truck.box.fill (cyan)    — Tier 3 / ephemeral crowd (§3)
    ///
    /// Teal/cyan are intentionally cooler/recessive so crowd pins don't compete with the
    /// Tier 1 orange/purple authoritative pins (design note §1).
    ///
    /// Both SF Symbols (person.badge.clock.fill, truck.box.fill) are SF Symbols 5 / iOS 17+.
    /// Do NOT fall back to shield.fill for enforcement_active (design note §2).
    private static func markerStyle(for pinType: PinType) -> (symbolName: String, color: UIColor) {
        switch pinType {
        case .filming:
            return ("video.fill", UIColor.systemPurple)
        case .specialEvent:
            return ("star.fill", UIColor.systemOrange)
        case .enforcementActive:
            // Design note §2: person.badge.clock.fill = "civic worker on duty". systemTeal.
            // Recessive color keeps Tier 3 crowd pins subordinate to Tier 1 (orange/purple).
            return ("person.badge.clock.fill", UIColor.systemTeal)
        case .sweeperPassed:
            // Design note §3: truck.box.fill = service vehicle. systemCyan.
            // Distinct from teal (enforcement) at glance; no alarm connotation (sweeper passed = good news).
            return ("truck.box.fill", UIColor.systemCyan)
        default:
            // Fallback for any type that reaches this path unexpectedly.
            return ("mappin.fill", UIColor.systemGray)
        }
    }
}
