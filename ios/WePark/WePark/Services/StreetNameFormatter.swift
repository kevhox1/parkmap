//
//  StreetNameFormatter.swift
//  WePark
//
//  DISPLAY-ONLY street-name formatter (docs/specs/address-anchored-parking.md section 6).
//
//  Normalized names lose ordinals ("E 1 St", "W 42 St", "1 Ave"). This restores them for
//  anything a person reads: "E 1st St", "W 42nd St", "1st Ave".
//
//  It is deliberately NOT part of `StreetNameNormalizer.canonical`, which is a MATCHING key that
//  mirrors the PWA's `canonicalStreetName` (index.html:1777). Never feed this output back into
//  matching, and never feed a house number through it: the address path formats `houseNumber`
//  and the street separately ("123" + "E 1 St"), never "123 E 1 St" as one string.
//
//  Pure value logic, `nonisolated` so tests and non-main contexts can call it (the module
//  defaults to MainActor isolation).
//

import Foundation

nonisolated enum StreetNameFormatter {

    /// Words (lower-case, no trailing period) that make a preceding 1-3 digit token a street
    /// number: "E 1 St", "1 Ave". Abbreviations and full words both appear in tile data.
    private static let streetTypeWords: Set<String> = [
        "st", "street", "ave", "avenue", "pl", "place", "rd", "road", "blvd", "dr", "drive",
        "ln", "way", "ct", "sq", "pkwy", "ter", "terrace"
    ]

    /// Returns `name` with ordinal suffixes restored on street-number tokens. Idempotent.
    ///
    /// - A 1-3 digit token (value >= 1, no leading zero) followed by a street-type word gets
    ///   its ordinal suffix.
    /// - An already-ordinal token ("42ND") is kept with a lower-cased suffix ("42nd").
    /// - Everything else is untouched: "Pier 40", "Route 9", "Avenue A", tokens longer than
    ///   three digits, directionals, abbreviations.
    static func display(_ name: String) -> String {
        let tokens = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return name }
        var out: [String] = []
        out.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() {
            if let lowered = loweredOrdinal(token) {
                out.append(lowered)
                continue
            }
            if let number = streetNumber(token), index + 1 < tokens.count,
               isStreetTypeWord(tokens[index + 1]) {
                out.append("\(number)\(ordinalSuffix(for: number))")
                continue
            }
            out.append(token)
        }
        return out.joined(separator: " ")
    }

    /// Convenience for views that show a raw tile street: canonical form first (so "FIRST AVENUE"
    /// and "1 AVE" agree), then ordinals restored. Display only; never a matching key.
    static func displayCanonical(_ raw: String) -> String {
        display(StreetNameNormalizer.canonical(raw))
    }

    /// "st" / "nd" / "rd" / "th" for a positive integer (11-13 are "th").
    static func ordinalSuffix(for number: Int) -> String {
        let mod100 = number % 100
        if (11...13).contains(mod100) { return "th" }
        switch number % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    // MARK: - Private

    /// 1-3 ASCII digits, value >= 1, no leading zero.
    private static func streetNumber(_ token: String) -> Int? {
        guard (1...3).contains(token.count),
              token.allSatisfy({ $0.isASCII && $0.isNumber }),
              token.first != "0",
              let value = Int(token) else { return nil }
        return value
    }

    /// "42ND" -> "42nd" for an already-ordinal token with 1-3 leading digits; nil otherwise.
    private static func loweredOrdinal(_ token: String) -> String? {
        let digits = token.prefix(while: { $0.isASCII && $0.isNumber })
        guard (1...3).contains(digits.count), digits.first != "0" else { return nil }
        let suffix = token.dropFirst(digits.count).lowercased()
        guard ["st", "nd", "rd", "th"].contains(suffix) else { return nil }
        return String(digits) + suffix
    }

    private static func isStreetTypeWord(_ token: String) -> Bool {
        var word = token.lowercased()
        if word.hasSuffix(".") { word.removeLast() }
        return streetTypeWords.contains(word)
    }
}
