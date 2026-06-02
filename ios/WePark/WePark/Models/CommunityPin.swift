//
//  CommunityPin.swift
//  WePark
//
//  Community 1.0 — iOS model layer.
//  Implements the typed pin schema from docs/typed-pin-schema-spec.md §10.
//
//  What lives here:
//   - PinType    — 10-value enum (§10.1) + parked_car (W5 personal pin)
//   - PinSource  — 3-value enum (§10.2)
//   - PinLifespan — 4-value enum (§10.2)
//   - CommunityPin — main struct (§10.3), decoded from pins_with_author view
//   - PinMeta    — associated-value enum (§10.4) + per-type meta structs
//
//  Decoding strategy (§10.4):
//   CommunityPin.init(from:) reads pin_type first via a single-key peek container,
//   then decodes the meta JSONB into the matching PinMeta case. If meta is null the
//   field is nil. An unrecognised pin_type throws DecodingError.dataCorrupted so
//   callers can decide (filter/log) rather than silently discarding; see
//   CommunityPin.gracefulDecode(from:) for the soft-failure variant.
//
//  Invariants:
//   - No Calendar.current — all time math defers to Calendar.easternTime (W3 convention).
//   - No SwiftUI import — pure data model.
//   - No Supabase client — model + decode only (networking is Stream C, §12).
//   - No force-unwraps.
//

import Foundation

// MARK: - PinType

/// The full set of pin types as defined in the `pin_type` SQL enum (§4.1 / §10.1).
/// Raw values MUST match the SQL enum strings exactly — AC-I7.
enum PinType: String, Codable, CaseIterable {
    // Tier 1: open-data-seedable
    case filming           = "filming"
    case aspSuspendedToday = "asp_suspended_today"
    case specialEvent      = "special_event"
    case construction      = "construction"
    // Tier 2: crowd, durable
    case signCorrection    = "sign_correction"
    case blockNote         = "block_note"
    // Tier 3: crowd, ephemeral
    case enforcementActive = "enforcement_active"
    case sweeperPassed     = "sweeper_passed"
    case brokenMeter       = "broken_meter"
    // Personal (W5 local pin; not community-visible by default)
    case parkedCar         = "parked_car"
}

// MARK: - PinSource / PinLifespan

/// Two-axis classification — source axis (§3 / §10.2).
enum PinSource: String, Codable {
    case openData = "open_data"
    case hybrid   = "hybrid"
    case crowd    = "crowd"
}

/// Two-axis classification — lifespan axis (§3 / §10.2).
enum PinLifespan: String, Codable {
    case ephemeral  = "ephemeral"
    case session    = "session"
    case durable    = "durable"
    case correction = "correction"
}

// MARK: - CommunityPin

/// A backend-persisted community pin decoded from the `pins_with_author` view.
/// The W5 `ParkedCar` model is NOT replaced — it continues to own local-only state.
/// See §10.5 for the `ParkedCar → CommunityPin` future promotion seam.
struct CommunityPin: Identifiable {

    // MARK: Identity
    let id: UUID

    // MARK: Type + classification
    let pinType: PinType
    let source: PinSource
    let lifespan: PinLifespan

    // MARK: Geography
    let lat: Double
    let lng: Double
    let segmentId: String?
    let zoneId: String?

    // MARK: Authorship
    let authorId: UUID?
    /// Inline from the `pins_with_author` view (§9).
    let authorUsername: String?

    // MARK: Temporal
    let createdAt: Date
    let updatedAt: Date
    /// nil = does not auto-expire (durable / correction types).
    let expiresAt: Date?
    /// Set when a durable/correction pin is voted resolved or admin-closed.
    let resolvedAt: Date?

    // MARK: Crowd-signal counters
    let confirmCount: Int
    let disputeCount: Int

    // MARK: Per-type metadata (nil when the DB row has meta = null)
    let meta: PinMeta?

    // MARK: Free-text notes
    let notes: String?
}

// MARK: - CommunityPin: Codable

extension CommunityPin: Codable {

    private enum CodingKeys: String, CodingKey {
        case id
        case pinType        = "pin_type"
        case source
        case lifespan
        case lat
        case lng
        case segmentId      = "segment_id"
        case zoneId         = "zone_id"
        case authorId       = "author_id"
        case authorUsername = "author_username"
        case createdAt      = "created_at"
        case updatedAt      = "updated_at"
        case expiresAt      = "expires_at"
        case resolvedAt     = "resolved_at"
        case confirmCount   = "confirm_count"
        case disputeCount   = "dispute_count"
        case meta
        case notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id            = try container.decode(UUID.self,       forKey: .id)
        pinType       = try container.decode(PinType.self,    forKey: .pinType)
        source        = try container.decode(PinSource.self,  forKey: .source)
        lifespan      = try container.decode(PinLifespan.self, forKey: .lifespan)
        lat           = try container.decode(Double.self,     forKey: .lat)
        lng           = try container.decode(Double.self,     forKey: .lng)
        segmentId     = try container.decodeIfPresent(String.self, forKey: .segmentId)
        zoneId        = try container.decodeIfPresent(String.self, forKey: .zoneId)
        authorId      = try container.decodeIfPresent(UUID.self,   forKey: .authorId)
        authorUsername = try container.decodeIfPresent(String.self, forKey: .authorUsername)
        createdAt     = try container.decode(Date.self,       forKey: .createdAt)
        updatedAt     = try container.decode(Date.self,       forKey: .updatedAt)
        expiresAt     = try container.decodeIfPresent(Date.self,   forKey: .expiresAt)
        resolvedAt    = try container.decodeIfPresent(Date.self,   forKey: .resolvedAt)
        confirmCount  = try container.decode(Int.self,        forKey: .confirmCount)
        disputeCount  = try container.decode(Int.self,        forKey: .disputeCount)
        notes         = try container.decodeIfPresent(String.self, forKey: .notes)

        // Decode `meta` JSONB using pin_type as the discriminator (§10.4 strategy).
        // If the meta column is null the field becomes nil without error.
        meta = try PinMeta.decode(pinType: pinType, from: container)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id,            forKey: .id)
        try container.encode(pinType,       forKey: .pinType)
        try container.encode(source,        forKey: .source)
        try container.encode(lifespan,      forKey: .lifespan)
        try container.encode(lat,           forKey: .lat)
        try container.encode(lng,           forKey: .lng)
        try container.encodeIfPresent(segmentId,      forKey: .segmentId)
        try container.encodeIfPresent(zoneId,         forKey: .zoneId)
        try container.encodeIfPresent(authorId,       forKey: .authorId)
        try container.encodeIfPresent(authorUsername, forKey: .authorUsername)
        try container.encode(createdAt,     forKey: .createdAt)
        try container.encode(updatedAt,     forKey: .updatedAt)
        try container.encodeIfPresent(expiresAt,      forKey: .expiresAt)
        try container.encodeIfPresent(resolvedAt,     forKey: .resolvedAt)
        try container.encode(confirmCount,  forKey: .confirmCount)
        try container.encode(disputeCount,  forKey: .disputeCount)
        try container.encodeIfPresent(notes, forKey: .notes)
        // Encode meta as the underlying Codable struct (or null if nil).
        if let meta {
            try container.encode(meta, forKey: .meta)
        } else {
            try container.encodeNil(forKey: .meta)
        }
    }
}

// MARK: - Soft-failure helper

extension CommunityPin {
    /// Attempt to decode a `CommunityPin` from a decoder.
    /// Returns `nil` (and logs) rather than throwing on unknown pin_type or other
    /// shape errors. Used when iterating a list of pins from a server response where
    /// a single bad row should not crash the feed.
    static func gracefulDecode(from decoder: Decoder) -> CommunityPin? {
        do {
            return try CommunityPin(from: decoder)
        } catch {
            // In production, replace with os_log / your logging abstraction.
            return nil
        }
    }
}

// MARK: - PinMeta

/// Typed metadata keyed by `pin_type`. Decoded by `PinMeta.decode(pinType:from:)`
/// after `CommunityPin` already extracted `pin_type` from the same container.
///
/// The enum itself is `Codable` so round-trip encode→decode works in tests (AC-I7).
/// The encode path emits the underlying struct directly (no type wrapper key),
/// mirroring the JSONB shape in the DB.
enum PinMeta: Codable {
    case filming(FilmingMeta)
    case aspSuspendedToday(ASPSuspendedMeta)
    case specialEvent(SpecialEventMeta)
    case construction(ConstructionMeta)
    case signCorrection(SignCorrectionMeta)
    case blockNote(BlockNoteMeta)
    case enforcementActive(EnforcementActiveMeta)
    case sweeperPassed(SweeperPassedMeta)
    case brokenMeter(BrokenMeterMeta)
    case parkedCar(ParkedCarMeta)

    // MARK: Internal decoding helper

    /// Decodes the `meta` key from an existing `CommunityPin` container.
    /// Returns `nil` when the key is absent or its value is JSON null.
    fileprivate static func decode(
        pinType: PinType,
        from container: KeyedDecodingContainer<CommunityPin.CodingKeys>
    ) throws -> PinMeta? {
        // If the column is absent or null, return nil (no metadata for this pin).
        guard container.contains(.meta),
              !(try container.decodeNil(forKey: .meta))
        else { return nil }

        switch pinType {
        case .filming:
            let m = try container.decode(FilmingMeta.self, forKey: .meta)
            return .filming(m)
        case .aspSuspendedToday:
            let m = try container.decode(ASPSuspendedMeta.self, forKey: .meta)
            return .aspSuspendedToday(m)
        case .specialEvent:
            let m = try container.decode(SpecialEventMeta.self, forKey: .meta)
            return .specialEvent(m)
        case .construction:
            let m = try container.decode(ConstructionMeta.self, forKey: .meta)
            return .construction(m)
        case .signCorrection:
            let m = try container.decode(SignCorrectionMeta.self, forKey: .meta)
            return .signCorrection(m)
        case .blockNote:
            let m = try container.decode(BlockNoteMeta.self, forKey: .meta)
            return .blockNote(m)
        case .enforcementActive:
            let m = try container.decode(EnforcementActiveMeta.self, forKey: .meta)
            return .enforcementActive(m)
        case .sweeperPassed:
            let m = try container.decode(SweeperPassedMeta.self, forKey: .meta)
            return .sweeperPassed(m)
        case .brokenMeter:
            let m = try container.decode(BrokenMeterMeta.self, forKey: .meta)
            return .brokenMeter(m)
        case .parkedCar:
            let m = try container.decode(ParkedCarMeta.self, forKey: .meta)
            return .parkedCar(m)
        }
    }

    // MARK: Codable — encode dispatches to the underlying struct

    init(from decoder: Decoder) throws {
        // PinMeta is never decoded standalone — always via PinMeta.decode(pinType:from:).
        // If someone calls this directly (e.g., JSONDecoder on a PinMeta value), we
        // cannot infer pin_type. Throw a clear error rather than silently failing.
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "PinMeta must be decoded via CommunityPin — " +
                    "call PinMeta.decode(pinType:from:) from within CommunityPin.init(from:)"
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .filming(let m):           try m.encode(to: encoder)
        case .aspSuspendedToday(let m): try m.encode(to: encoder)
        case .specialEvent(let m):      try m.encode(to: encoder)
        case .construction(let m):      try m.encode(to: encoder)
        case .signCorrection(let m):    try m.encode(to: encoder)
        case .blockNote(let m):         try m.encode(to: encoder)
        case .enforcementActive(let m): try m.encode(to: encoder)
        case .sweeperPassed(let m):     try m.encode(to: encoder)
        case .brokenMeter(let m):       try m.encode(to: encoder)
        case .parkedCar(let m):         try m.encode(to: encoder)
        }
    }
}

// MARK: - Per-type meta structs (§4.3)

// MARK: FilmingMeta

/// `pin_type = 'filming'`
/// Required: `permit_id`. Optional: `production_name`, `film_office_url`.
struct FilmingMeta: Codable {
    let permitId: String
    let productionName: String?
    let filmOfficeUrl: String?

    private enum CodingKeys: String, CodingKey {
        case permitId       = "permit_id"
        case productionName = "production_name"
        case filmOfficeUrl  = "film_office_url"
    }
}

// MARK: ASPSuspendedMeta

/// `pin_type = 'asp_suspended_today'`
/// Required: `suspension_date` (YYYY-MM-DD). Optional: `reason`.
struct ASPSuspendedMeta: Codable {
    /// ISO date string, e.g. "2026-05-25". The view layer formats for display.
    let suspensionDate: String
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case suspensionDate = "suspension_date"
        case reason
    }
}

// MARK: SpecialEventMeta

/// `pin_type = 'special_event'`
/// Required: `event_name`, `event_type`.
struct SpecialEventMeta: Codable {
    let eventName: String
    let eventType: EventType

    enum EventType: String, Codable {
        case parade         = "parade"
        case marathon       = "marathon"
        case snowEmergency  = "snow_emergency"
        case fair           = "fair"
        case other          = "other"
    }

    private enum CodingKeys: String, CodingKey {
        case eventName = "event_name"
        case eventType = "event_type"
    }
}

// MARK: ConstructionMeta

/// `pin_type = 'construction'`
/// All fields optional (partial open data, §4.3).
struct ConstructionMeta: Codable {
    let permitId: String?
    let agency: String?
    let startDate: String?
    let endDate: String?

    private enum CodingKeys: String, CodingKey {
        case permitId  = "permit_id"
        case agency
        case startDate = "start_date"
        case endDate   = "end_date"
    }
}

// MARK: SignCorrectionMeta

/// `pin_type = 'sign_correction'`
/// Required: `segment_id`, `reported_issue`. Optional: `existing_rule_text`.
struct SignCorrectionMeta: Codable {
    let segmentId: String
    let reportedIssue: String
    let existingRuleText: String?

    private enum CodingKeys: String, CodingKey {
        case segmentId       = "segment_id"
        case reportedIssue   = "reported_issue"
        case existingRuleText = "existing_rule_text"
    }
}

// MARK: BlockNoteMeta

/// `pin_type = 'block_note'`
/// Required: `category`, `headline`.
struct BlockNoteMeta: Codable {
    let category: Category
    let headline: String

    enum Category: String, Codable {
        case safety      = "safety"
        case flooding    = "flooding"
        case parkingNorm = "parking_norm"
        case other       = "other"
    }
}

// MARK: EnforcementActiveMeta

/// `pin_type = 'enforcement_active'`
/// `sub_tag` is optional — nil = not specified ("Enforcement active" generic copy).
/// See §4.1 note on the framing decision: this schema is neutral; UI copy is the lever.
struct EnforcementActiveMeta: Codable {

    enum SubTag: String, Codable {
        case parkingAgent  = "parking_agent"
        case cleaningTruck = "cleaning_truck"
        case towTruck      = "tow_truck"
    }

    /// nil = not specified; UI shows generic "Enforcement active" copy.
    let subTag: SubTag?

    private enum CodingKeys: String, CodingKey {
        case subTag = "sub_tag"
    }
}

// MARK: SweeperPassedMeta

/// `pin_type = 'sweeper_passed'`
/// `direction` is optional.
struct SweeperPassedMeta: Codable {

    enum Direction: String, Codable {
        case passed      = "passed"
        case comingSoon  = "coming_soon"
    }

    let direction: Direction?
}

// MARK: BrokenMeterMeta

/// `pin_type = 'broken_meter'`
/// `meter_id` is optional.
struct BrokenMeterMeta: Codable {
    let meterId: String?

    private enum CodingKeys: String, CodingKey {
        case meterId = "meter_id"
    }
}

// MARK: ParkedCarMeta

/// `pin_type = 'parked_car'`
/// Mirrors W5 `ParkedCar` fields (§10.5 seam). All fields optional.
/// This is NOT used by the W5 local-only `ParkedCar` model — it only applies
/// when a personal parked-car pin is stored as a `CommunityPin` row in the DB.
struct ParkedCarMeta: Codable {
    let detectedSegmentId: String?
    let detectedSide: String?
    let street: String?
    let fromStreet: String?
    let toStreet: String?

    private enum CodingKeys: String, CodingKey {
        case detectedSegmentId = "detected_segment_id"
        case detectedSide      = "detected_side"
        case street
        case fromStreet        = "from_street"
        case toStreet          = "to_street"
    }
}
