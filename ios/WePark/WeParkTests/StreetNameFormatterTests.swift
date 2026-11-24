//
//  StreetNameFormatterTests.swift
//  WeParkTests
//
//  Address-anchored parking stream A (docs/specs/address-anchored-parking.md section 6): the
//  display-only ordinal formatter, plus the regression that `StreetNameNormalizer.canonical`
//  (the PWA-parity MATCHING key) is untouched.
//
//  Compile-failure-class notes: `StreetNameFormatter` is `nonisolated`, so it is called directly;
//  no XCTestCase extensions; no bare `Category`.
//

import XCTest
@testable import WePark

final class StreetNameFormatterTests: XCTestCase {

    private func assertDisplay(_ input: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(StreetNameFormatter.display(input), expected, file: file, line: line)
    }

    func testOrdinals_basicStreets() {
        assertDisplay("E 1 St", "E 1st St")
        assertDisplay("W 42 St", "W 42nd St")
    }

    func testOrdinals_leadingAvenueNumbers() {
        assertDisplay("1 Ave", "1st Ave")
        assertDisplay("2 Ave", "2nd Ave")
        assertDisplay("3 Ave", "3rd Ave")
        assertDisplay("4 Ave", "4th Ave")
    }

    func testOrdinals_elevenTwelveThirteenAreTh() {
        assertDisplay("E 11 St", "E 11th St")
        assertDisplay("E 12 St", "E 12th St")
        assertDisplay("E 13 St", "E 13th St")
    }

    func testOrdinals_twentyOneTwoThree() {
        assertDisplay("W 21 St", "W 21st St")
        assertDisplay("W 22 St", "W 22nd St")
        assertDisplay("W 23 St", "W 23rd St")
    }

    func testOrdinals_hundreds() {
        assertDisplay("E 101 St", "E 101st St")
        assertDisplay("E 111 St", "E 111th St")
        assertDisplay("E 112 St", "E 112th St")
        assertDisplay("E 113 St", "E 113th St")
    }

    func testAlreadyOrdinal_keptWithLowercasedSuffix() {
        assertDisplay("E 42ND St", "E 42nd St")
        assertDisplay("1ST AVE", "1st Ave")
    }

    func testNotOrdinalized() {
        assertDisplay("Avenue A", "Avenue A")
        assertDisplay("Ave A", "Ave A")
        assertDisplay("Pier 40", "Pier 40")
        assertDisplay("Route 9", "Route 9")
        assertDisplay("Broadway", "Broadway")
        assertDisplay("Bowery", "Bowery")
        assertDisplay("FDR Dr", "FDR Dr")
        assertDisplay("Houston St", "Houston St")
    }

    func testNotOrdinalized_longNumbersAndZero() {
        assertDisplay("1234 St", "1234 St")
        assertDisplay("0 St", "0 St")
        assertDisplay("05 St", "05 St")
    }

    func testStreetTypeWordsAreCaseInsensitive() {
        assertDisplay("E 1 ST", "E 1st St")
        assertDisplay("E 1 Street", "E 1st Street")
        assertDisplay("5 Avenue", "5th Avenue")
    }

    func testRawUppercaseTileStrings_getTitleCaseAndOrdinals() {
        assertDisplay("E 2 ST", "E 2nd St")
        assertDisplay("E 2ND ST", "E 2nd St")
        assertDisplay("1 AVE", "1st Ave")
        assertDisplay("FDR DR", "FDR Dr")
        assertDisplay("W 11 ST", "W 11th St")
        assertDisplay("AVE A", "Ave A")
        assertDisplay("E HOUSTON ST", "E Houston St")
    }

    func testIdempotent() {
        let inputs = [
            "E 1 St", "W 42 St", "1 Ave", "E 11 St", "W 22 St", "E 113 St", "E 42ND St",
            "Avenue A", "Pier 40", "Broadway", "FDR Dr", "", "E 1st St", "E 2ND ST", "W 11 ST", "FDR DR", "1 AVE"
        ]
        for input in inputs {
            let once = StreetNameFormatter.display(input)
            XCTAssertEqual(StreetNameFormatter.display(once), once, "display must be idempotent for \(input)")
        }
    }

    func testHouseNumberIsNeverPartOfTheFormattedString() {
        // Contract: callers format houseNumber and street separately. The address line therefore
        // never ordinalizes the house number.
        let address = ParkingAddress(
            houseNumber: "123", streetDisplay: "East 1st Street",
            confidence: .verified, source: .mapkit, resolvedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(ParkingAddressCopy.numberAndStreet(address), "123 E 1st St")
    }

    func testDisplayCanonical_matchesTileAndCenterlineSpellings() {
        XCTAssertEqual(StreetNameFormatter.displayCanonical("1ST AVENUE"), "1st Ave")
        XCTAssertEqual(StreetNameFormatter.displayCanonical("EAST 1ST STREET"), "E 1st St")
    }

    // MARK: - canonical (matching key) is unchanged

    func testCanonical_isUnchanged_noOrdinalsRestored() {
        XCTAssertEqual(StreetNameNormalizer.canonical("1ST AVENUE"), "1 AVE")
        XCTAssertEqual(StreetNameNormalizer.canonical("2 AVE"), "2 AVE")
        XCTAssertEqual(StreetNameNormalizer.canonical("EAST 1ST STREET"), "E 1 ST")
        XCTAssertEqual(StreetNameNormalizer.canonical("E 1 St"), "E 1 ST")
        XCTAssertEqual(StreetNameNormalizer.canonical("W 42ND STREET"), "W 42 ST")
        XCTAssertEqual(StreetNameNormalizer.canonical("FIFTH AVENUE"), "5 AVE")
        XCTAssertEqual(StreetNameNormalizer.canonical("AVE OF THE AMERICAS"), "6 AVE")
        XCTAssertEqual(StreetNameNormalizer.canonical("CHRYSTIE STREET"), "CHRYSTIE ST")
        XCTAssertEqual(StreetNameNormalizer.canonical("East 1st Street"), StreetNameNormalizer.canonical("E 1 ST"))
    }

    func testCardDisplayHelpers_useOrdinals_whileTitleCasedItselfIsUnchanged() {
        XCTAssertEqual(CurbPlacementCardModel.titleCased("E 1 ST"), "E 1 St")
        XCTAssertEqual(CurbPlacementCardModel.displayStreetName("E 1 ST"), "E 1st St")
        XCTAssertEqual(CurbPlacementCardModel.displayStreetName("1 AVE"), "1st Ave")
        XCTAssertEqual(CurbPlacementCardModel.spokenStreetName("W 42 ST"), "West 42nd Street")
        XCTAssertEqual(CurbPlacementCardModel.spokenStreetName("1 AVE"), "1st Avenue")
    }
}
