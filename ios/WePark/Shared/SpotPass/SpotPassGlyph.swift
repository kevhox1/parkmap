//
//  SpotPassGlyph.swift
//  Shared/SpotPass
//
//  Alias glyph slug -> SF Symbol, and the tint index. Moved out of the seeker's models in C3 so
//  the App Clip and the Live Activity extensions resolve the SAME glyph as the seeker's badge
//  (the alias + glyph handshake is the trust device, design section 0).
//

import Foundation

nonisolated enum SpotPassGlyph {

    static let fallbackSymbol = "ticket.fill"

    /// Design §10.2 animal keys to SF Symbols. The server stores `glyph`; if it already stores an
    /// SF Symbol name (contains a dot) it is used as is.
    private static let animalSymbols: [String: String] = [
        // Backend alias slugs (supabase/13-spot-handoffs.sql `create_handoff`, 16 aliases).
        "bodega_cat": "cat.fill",
        "stoop_pigeon": "bird.fill",
        "corner_slice": "fork.knife",
        "subway_rat": "pawprint.fill",
        "fire_escape_fern": "leaf.fill",
        "brownstone_bear": "pawprint.fill",
        "hydrant_hound": "dog.fill",
        "ferry_gull": "bird.fill",
        "rooftop_owl": "moon.stars.fill",
        "egg_cream": "cup.and.saucer.fill",
        "yellow_cab": "car.fill",
        "bagel_bandit": "circle.circle.fill",
        "metrocard_mouse": "creditcard.fill",
        "park_squirrel": "tree.fill",
        "bridge_bat": "moon.haze.fill",
        "cart_pretzel": "star.fill",
        // Design §10.2 animal keys (kept for forward compatibility).
        "cat": "cat.fill",
        "pup": "dog.fill",
        "pigeon": "bird.fill",
        "sparrow": "bird.fill",
        "hare": "hare.fill",
        "turtle": "tortoise.fill",
        "ladybug": "ladybug.fill",
        "gecko": "lizard.fill"
    ]

    static func symbolName(for glyph: String) -> String {
        let trimmed = glyph.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return fallbackSymbol }
        if trimmed.contains(".") { return trimmed }
        return animalSymbols[trimmed] ?? fallbackSymbol
    }

    /// Design §10.2: tint = hash(pass id) mod 4. `hashValue` is randomized per launch, so this uses
    /// the first UUID byte: stable for a given pass on every launch and device.
    /// The driver cannot know the pass id before claiming (peek does not return it), so the clip
    /// derives a stable tint from the alias instead (djb2; `hashValue` is randomized per launch).
    static func tintIndex(forAlias alias: String) -> Int {
        var hash: UInt32 = 5381
        for byte in alias.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return Int(hash % 4)
    }

    static func tintIndex(for id: UUID) -> Int {
        Int(id.uuid.0) % 4
    }
}
