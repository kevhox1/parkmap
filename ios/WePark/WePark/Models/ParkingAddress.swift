//
//  ParkingAddress.swift
//  WePark
//
//  Address-anchored parking (docs/specs/address-anchored-parking.md section 4): the human anchor
//  for a parked car ("In front of 123 E 1st St"). Stored on `ParkedCar.address`.
//
//  PRIVACY: this lives only on-device and in the user's own iCloud key-value store (same trust
//  as the car's coordinates). It is never sent to Supabase, analytics or a push payload. No
//  `print` of an address anywhere.
//
//  No import SwiftUI: pure data model (QA invariant).
//

import Foundation

nonisolated struct ParkingAddress: Codable, Equatable {

    nonisolated enum Confidence: String, Codable, Equatable {
        /// Street match + number + parity consistent (or no prior) + within the distance bound.
        case verified
        /// Street match + number, but parity conflict, far placemark, or found via offset retry.
        case approximate
    }

    nonisolated enum Source: String, Codable, Equatable {
        case mapkit
    }

    /// "123", "123A".
    var houseNumber: String
    /// As geocoded ("East 1st Street"); passes through `StreetNameFormatter` at display.
    var streetDisplay: String
    var confidence: Confidence
    var source: Source
    var resolvedAt: Date
}

/// Every user-facing string for a `ParkingAddress`. Pure and `nonisolated`.
nonisolated enum ParkingAddressCopy {

    /// "123 E 1st St": the house number plus the compact, ordinal-restored street (the same
    /// abbreviations the placement card title uses). The street and number are formatted
    /// separately (formatter contract: never feed a house number through it).
    static func numberAndStreet(_ address: ParkingAddress) -> String {
        let canonical = StreetNameNormalizer.canonical(address.streetDisplay)
        let street = StreetNameFormatter.display(CurbPlacementCardModel.titleCased(canonical))
        return "\(address.houseNumber) \(street)"
    }

    /// "In front of 123 E 1st St" (verified) / "Near 123 E 1st St" (approximate).
    static func line(_ address: ParkingAddress) -> String {
        switch address.confidence {
        case .verified:    return "In front of \(numberAndStreet(address))"
        case .approximate: return "Near \(numberAndStreet(address))"
        }
    }

    /// VoiceOver form: "Parking in front of 123 East 1st Street" /
    /// "Near 123 East 1st Street, number approximate".
    static func spoken(_ address: ParkingAddress) -> String {
        let canonical = StreetNameNormalizer.canonical(address.streetDisplay)
        let street = CurbPlacementCardModel.expandedStreetName(
            StreetNameFormatter.display(CurbPlacementCardModel.titleCased(canonical))
        )
        let place = "\(address.houseNumber) \(street)"
        switch address.confidence {
        case .verified:    return "Parking in front of \(place)"
        case .approximate: return "Near \(place), number approximate"
        }
    }

    /// "Your car is in front of 123 E 1st St." for a reminder body: VERIFIED addresses only
    /// (nil for approximate or no address, so an unproven number is never pushed to the lock screen).
    static func notificationSentence(_ address: ParkingAddress?) -> String? {
        guard let address, address.confidence == .verified else { return nil }
        return "Your car is in front of \(numberAndStreet(address))."
    }

    /// Share-my-spot text (explicit user tap only): "Parked in front of 123 E 1st St (WePark)".
    /// Approximate addresses say "near" so the text never over-claims.
    static func shareText(_ address: ParkingAddress) -> String {
        switch address.confidence {
        case .verified:    return "Parked in front of \(numberAndStreet(address)) (WePark)"
        case .approximate: return "Parked near \(numberAndStreet(address)) (WePark)"
        }
    }
}
