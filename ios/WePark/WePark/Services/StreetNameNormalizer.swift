//
//  StreetNameNormalizer.swift
//  WePark
//
//  Pure port of canonicalStreetName() from index.html:1777.
//  Converts both tile-data names ("1ST AVENUE", "CHRYSTIE STREET") and
//  NYC centerline names ("1 AVE", "CHRYSTIE ST") to a single canonical form.
//
//  Entry point for unit tests: StreetNameNormalizer.canonical(_ raw: String) -> String
//
//  PWA source: canonicalStreetName() at index.html:1777
//  Normalization table: STREET_SUFFIX_NORMALIZE at index.html:1764–1776
//

import Foundation

enum StreetNameNormalizer {

    // MARK: - Public API

    /// Returns the canonical form of a street name.
    /// Applies ordinal stripping, suffix normalization, whitespace collapse,
    /// and the "Avenue of the Americas" alias.
    ///
    /// Examples:
    ///   "1ST AVENUE"       → "1 AVE"
    ///   "CHRYSTIE STREET"  → "CHRYSTIE ST"
    ///   "AVE OF THE AMERICAS" → "6 AVE"
    ///   "FIFTH AVENUE"     → "5 AVE"
    ///
    /// PWA equivalent: canonicalStreetName(raw) at index.html:1777
    static func canonical(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var s = raw.uppercased().trimmingCharacters(in: .whitespaces)

        // Strip ordinal suffixes from numeric street names:
        //   "1ST" → "1", "2ND" → "2", "3RD" → "3", "4TH" → "4", etc.
        s = stripOrdinalSuffixes(s)

        // Apply suffix normalization table (matches JS STREET_SUFFIX_NORMALIZE order).
        for (pattern, replacement) in suffixNormalizationTable {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        // Collapse multiple whitespace characters to a single space.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)

        // Named alias: "Avenue of the Americas" / "Ave of Americas" → "6 AVE"
        if s == "AVE OF THE AMERICAS" || s == "AVE OF AMERICAS" {
            return "6 AVE"
        }

        return s
    }

    // MARK: - Private helpers

    /// Strips ordinal suffixes (ST, ND, RD, TH) that immediately follow digits.
    /// Matches the JS regex /(\d+)(ST|ND|RD|TH)\b/g → '$1'
    /// Note: applied before suffix normalization so "FIRST" → "1" before "1ST" → "1".
    private static func stripOrdinalSuffixes(_ s: String) -> String {
        // Pattern: one or more digits followed by ST|ND|RD|TH at a word boundary.
        return s.replacingOccurrences(
            of: "(\\d+)(ST|ND|RD|TH)\\b",
            with: "$1",
            options: .regularExpression
        )
    }

    /// Ordered normalization rules matching JS STREET_SUFFIX_NORMALIZE at index.html:1764–1776.
    /// Order matters: "STREETS" must come before "STREET" to avoid partial replacement.
    /// Each tuple is (NSRegularExpression-compatible pattern, replacement string).
    /// \\b = word boundary, ensuring only whole words are replaced.
    private static let suffixNormalizationTable: [(String, String)] = [
        // Street suffixes — plural before singular
        ("\\bSTREETS\\b", "ST"),
        ("\\bSTREET\\b",  "ST"),
        ("\\bAVENUES\\b", "AVE"),
        ("\\bAVENUE\\b",  "AVE"),
        ("\\bBOULEVARD\\b", "BLVD"),
        ("\\bPLACE\\b",   "PL"),
        ("\\bPLAZA\\b",   "PLZ"),
        ("\\bDRIVE\\b",   "DR"),
        ("\\bROAD\\b",    "RD"),
        ("\\bPARKWAY\\b", "PKWY"),
        ("\\bEXPRESSWAY\\b", "EXPY"),
        ("\\bTERRACE\\b", "TER"),
        ("\\bCOURT\\b",   "CT"),
        ("\\bSQUARE\\b",  "SQ"),
        ("\\bHIGHWAY\\b", "HWY"),
        ("\\bBRIDGE\\b",  "BR"),
        ("\\bTUNNEL\\b",  "TUN"),
        // Directional abbreviations
        ("\\bEAST\\b",  "E"),
        ("\\bWEST\\b",  "W"),
        ("\\bNORTH\\b", "N"),
        ("\\bSOUTH\\b", "S"),
        // Spelled-out ordinals → numbers
        ("\\bFIRST\\b",   "1"),
        ("\\bSECOND\\b",  "2"),
        ("\\bTHIRD\\b",   "3"),
        ("\\bFOURTH\\b",  "4"),
        ("\\bFIFTH\\b",   "5"),
        ("\\bSIXTH\\b",   "6"),
        ("\\bSEVENTH\\b", "7"),
        ("\\bEIGHTH\\b",  "8"),
        ("\\bNINTH\\b",   "9"),
        ("\\bTENTH\\b",   "10"),
        ("\\bELEVENTH\\b", "11"),
        ("\\bTWELFTH\\b",  "12"),
    ]
}
