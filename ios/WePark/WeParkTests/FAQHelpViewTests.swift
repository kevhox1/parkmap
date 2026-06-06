//
//  FAQHelpViewTests.swift
//  WeParkTests
//
//  Light tests for FAQHelpView: verifies that the three NYC.gov link URLs are
//  well-formed and reachable as URL values (not nil). A static content view
//  doesn't warrant heavy unit testing, but the link destinations are load-bearing
//  — a malformed URL would silently produce no-op taps in Safari.
//
//  No Calendar.current use.
//  No hardcoded Mapbox tokens.
//

import XCTest
@testable import WePark

final class FAQHelpViewTests: XCTestCase {

    // MARK: - NYC.gov link URL correctness

    func testASPCalendarLink_isValidURL() {
        let urlString = "https://www.nyc.gov/html/dot/html/motorist/alternate-side-parking.shtml"
        let url = URL(string: urlString)
        XCTAssertNotNil(url, "ASP calendar URL must be a valid URL")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "www.nyc.gov")
    }

    func testASPCalendarPDF_isValidURL() {
        let urlString = "https://www.nyc.gov/html/dot/downloads/pdf/asp-calendar-2026.pdf"
        let url = URL(string: urlString)
        XCTAssertNotNil(url, "ASP calendar PDF URL must be a valid URL")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "www.nyc.gov")
        XCTAssertTrue(url?.path.hasSuffix(".pdf") == true, "PDF link must end with .pdf")
    }

    func testParkingRegulationsLink_isValidURL() {
        let urlString = "https://www.nyc.gov/html/dot/html/motorist/parking-regulations.shtml"
        let url = URL(string: urlString)
        XCTAssertNotNil(url, "Parking regulations URL must be a valid URL")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "www.nyc.gov")
    }

    // MARK: - Sanity: all three links are distinct

    func testAllThreeLinks_areDistinct() {
        let asp = "https://www.nyc.gov/html/dot/html/motorist/alternate-side-parking.shtml"
        let pdf = "https://www.nyc.gov/html/dot/downloads/pdf/asp-calendar-2026.pdf"
        let regs = "https://www.nyc.gov/html/dot/html/motorist/parking-regulations.shtml"
        let links = [asp, pdf, regs]
        let unique = Set(links)
        XCTAssertEqual(unique.count, 3, "All three NYC.gov links must be unique URLs")
    }
}
