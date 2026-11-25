//
//  NoSignData.swift
//  WePark
//
//  The "no usable sign data" state for a curb segment, and its user-facing copy.
//
//  The tile pipeline (PR #192) encodes a segment with no usable sign as ONE always-on rule:
//  category NO_PARKING, description starting "NO DATA - ...". That keeps it not-free (the
//  engine treated empty rules as free, historically) but would read as a real posted
//  "No parking" sign if shown verbatim. Every user-facing surface routes through
//  `Segment.hasNoSignData` / `NoSignData` so the state reads as "we don't know", never as a
//  posted sign. It is still NOT free everywhere (red on the map, never green in a goal).
//
//  Signal choice: the description prefix. `dominantCategory == UNKNOWN` is NOT reliable on its
//  own: 104 other segments are UNKNOWN for other reasons and carry real sign text.
//

import Foundation

enum NoSignData {
    /// Prefix the tile build writes on the synthetic rule's description.
    nonisolated static let descriptionPrefix = "NO DATA"

    nonisolated static let overline = "We don't know"
    nonisolated static let headline = "No sign data"
    nonisolated static let subline = "Read the posted signs on this curb before you park."
    /// Plain-words reason, shown when the encoded reason is a superseded sign.
    nonisolated static let supersededReason = "The only sign on file here was replaced, and we don't have the new one."

    /// True for the synthetic "NO DATA" rule (not a real posted sign).
    nonisolated static func isNoDataRule(_ rule: ParkingRule) -> Bool {
        rule.description.hasPrefix(descriptionPrefix)
    }
}

extension Segment {
    /// True when there is no usable sign data: empty rules, or the synthetic "NO DATA" rule.
    nonisolated var hasNoSignData: Bool {
        rules.isEmpty || rules.contains(where: NoSignData.isNoDataRule)
    }

    /// Reason line for the no-sign-data state, or nil when the reason isn't a known one.
    nonisolated var noSignDataReason: String? {
        let text = rules.first(where: NoSignData.isNoDataRule)?.description.uppercased() ?? ""
        return text.contains("SUPERSEDED") ? NoSignData.supersededReason : nil
    }
}
