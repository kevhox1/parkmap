//
//  CarPinSyncPolicyTests.swift
//  WeParkTests
//
//  Build 27 smoke finding 13: parked-car icon missing after the car was re-placed.
//  `syncCarPin` used to key on the car id only; these tests pin the rebuild rule that now
//  also covers a same-id position change and an annotation removed from the map.
//

import XCTest
@testable import WePark

final class CarPinSyncPolicyTests: XCTestCase {

    private let a = CarPinKey(id: UUID(), latitude: 40.7260, longitude: -73.9840)

    func testNoCarNoAnnotation_none() {
        XCTAssertEqual(CarPinSyncPolicy.action(rendered: nil, desired: nil, annotationOnMap: false), .none)
    }

    func testSameCarStillOnMap_none() {
        XCTAssertEqual(CarPinSyncPolicy.action(rendered: a, desired: a, annotationOnMap: true), .none)
    }

    func testNewCarId_rebuild() {
        let b = CarPinKey(id: UUID(), latitude: a.latitude, longitude: a.longitude)
        XCTAssertEqual(CarPinSyncPolicy.action(rendered: a, desired: b, annotationOnMap: true), .rebuild)
    }

    func testSameIdMovedPosition_rebuild() {
        let moved = CarPinKey(id: a.id, latitude: a.latitude + 0.001, longitude: a.longitude)
        XCTAssertEqual(CarPinSyncPolicy.action(rendered: a, desired: moved, annotationOnMap: true), .rebuild)
    }

    func testAnnotationMissingFromMap_selfHeals() {
        XCTAssertEqual(CarPinSyncPolicy.action(rendered: a, desired: a, annotationOnMap: false), .rebuild)
    }

    func testCarCleared_rebuildRemoves() {
        XCTAssertEqual(CarPinSyncPolicy.action(rendered: a, desired: nil, annotationOnMap: true), .rebuild)
    }

    func testFirstCar_rebuildAdds() {
        XCTAssertEqual(CarPinSyncPolicy.action(rendered: nil, desired: a, annotationOnMap: false), .rebuild)
    }
}
