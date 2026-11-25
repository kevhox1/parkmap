//
//  BlockDetailRuleDedupeTests.swift
//  WeParkTests
//
//  A multi-clause sign ships as one tile rule per clause, each carrying the full sign text, so the
//  block detail list showed the same description twice. `BlockDetailView.dedupedForDisplay` shows
//  each distinct (category, description) once, keeping order. Display only; the engine still sees
//  every rule.
//

import XCTest
@testable import WePark

final class BlockDetailRuleDedupeTests: XCTestCase {

    private func rule(_ category: WePark.Category, _ description: String, days: [Int]) -> ParkingRule {
        let dict: [String: Any] = [
            "category": category.rawValue,
            "description": description,
            "days": days,
            "timeRanges": [],
            "anytime": false,
            "arrow": "both",
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(ParkingRule.self, from: data)
    }

    func testSplitSignClausesShowOnce() {
        let text = "2 HMP MONDAY-FRIDAY 7PM-10PM SATURDAY 9AM-10PM <->"
        let rules = [rule(.metered, text, days: [1, 2, 3, 4, 5]), rule(.metered, text, days: [6])]
        let shown = BlockDetailView.dedupedForDisplay(rules)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.description, text)
    }

    func testDistinctSignsAreAllKeptInOrder() {
        let rules = [
            rule(.noParking, "COMMERCIAL VEHICLES ONLY MONDAY-FRIDAY 7AM-7PM", days: [1, 2, 3, 4, 5]),
            rule(.metered, "2 HMP MONDAY-FRIDAY 7PM-10PM", days: [1, 2, 3, 4, 5]),
            rule(.noParking, "COMMERCIAL VEHICLES ONLY MONDAY-FRIDAY 7AM-7PM", days: [1, 2, 3, 4, 5]),
        ]
        let shown = BlockDetailView.dedupedForDisplay(rules)
        XCTAssertEqual(shown.map { $0.description }, [
            "COMMERCIAL VEHICLES ONLY MONDAY-FRIDAY 7AM-7PM",
            "2 HMP MONDAY-FRIDAY 7PM-10PM",
        ])
    }

    func testSameTextDifferentCategoryIsNotMerged() {
        let rules = [rule(.noParking, "SAME TEXT", days: [1]), rule(.metered, "SAME TEXT", days: [1])]
        XCTAssertEqual(BlockDetailView.dedupedForDisplay(rules).count, 2)
    }

    func testEmptyStaysEmpty() {
        XCTAssertTrue(BlockDetailView.dedupedForDisplay([]).isEmpty)
    }
}
