//
//  NoSignDataBlock.swift
//  WePark
//
//  Shared "we have no usable sign data for this curb" header: over-line, headline, sub-line
//  and an optional plain-words reason. Used by the block detail, parked-car detail, etc.
//  Copy lives in `NoSignData`. Deliberately has NO "No Parking" badge and NO sign row: the
//  tile's synthetic NO DATA rule is not a posted sign.
//

import SwiftUI

struct NoSignDataBlock: View {
    /// Optional reason in plain words (e.g. `Segment.noSignDataReason`).
    var reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NoSignData.overline)
                .font(.caption.weight(.heavy))
                .foregroundStyle(.secondary)
            Text(NoSignData.headline)
                .font(.title.bold())
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(NoSignData.subline)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
