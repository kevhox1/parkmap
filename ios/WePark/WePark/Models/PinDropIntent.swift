//
//  PinDropIntent.swift
//  WePark
//
//  W5: Intermediate value type carrying the in-flight park-pin intent
//  between ContentView and ParkConfirmView.
//
//  Not persisted — exists only during the confirmation sheet presentation.
//  Identifiable so SwiftUI .sheet(item:) can detect a fresh intent even
//  when back-to-back intents share the same coordinate.
//
//  No import SwiftUI (QA invariant — pure data layer).
//

import Foundation
import CoreLocation

// MARK: - CandidateSegment

/// A segment that is within the search radius of the pin, plus its distance.
/// Port of the JS { seg, distSq, distM } objects from findCandidateSegments
/// at index.html:5107.
struct CandidateSegment {
    let segment: Segment
    let distanceMeters: Double
}

// MARK: - PinDropIntent

/// Drives the ParkConfirmView sheet.
/// Created fresh on every long-press and every "Park here →" tap (new UUID per event).
struct PinDropIntent: Identifiable {

    /// Fresh UUID on every creation — prevents SwiftUI from suppressing
    /// re-presentation on rapid back-to-back taps.
    let id = UUID()

    /// Exact coordinate of the long-press or segment midpoint (Path B).
    let pinLat: Double
    let pinLng: Double

    /// Closest segment within 35m, or nil if no nearby data.
    var detectedSegment: Segment?

    /// Alternative candidate blocks for "Wrong street?" UI.
    /// Empty for Path B (user explicitly selected this block from BlockDetailView).
    var alternativeCandidates: [CandidateSegment]
}
