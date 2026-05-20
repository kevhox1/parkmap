//
//  RouteServiceTests.swift
//  WeParkTests
//
//  W8.5a unit tests for the Mapbox Directions HTTP wrapper.
//
//  Tests use URLProtocol-mocked sessions — no live network calls.
//
//  Cases:
//    - testFetchRoute_singleRoute_decodesPrimary
//    - testFetchRoute_alternatives_decodesAllThree
//    - testFetchRoute_networkError_throwsNetwork
//    - testFetchRoute_http4xx_throwsHTTP
//    - testFetchRoute_http5xx_throwsHTTP
//    - testFetchRoute_emptyRoutes_throwsNoRoutes
//    - testFetchRoute_missingToken_throwsMissingToken
//    - testFetchRoute_emptyTokenString_throwsMissingToken
//    - testBuildURL_includesExpectedQueryParams
//    - testFetchRoute_geoJSONLngLatOrder_convertsToLatLng
//

import XCTest
import CoreLocation
@testable import WePark

// MARK: - URLProtocol mock

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// Handler invoked for each intercepted request. Returns the response
    /// and body data, or throws to simulate a network failure.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Captures the most recent intercepted URL so tests can assert on it.
    nonisolated(unsafe) static var lastURL: URL?

    static func reset() {
        handler = nil
        lastURL = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

// MARK: - Tests

@MainActor
final class RouteServiceTests: XCTestCase {

    private let origin = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
    private let destination = CLLocationCoordinate2D(latitude: 40.7484, longitude: -73.9857)

    private func makeService(
        token: String? = "test_token_pk.xxx",
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data) = { _ in
            (HTTPURLResponse(url: URL(string: "https://api.mapbox.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
    ) -> RouteService {
        MockURLProtocol.reset()
        MockURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return RouteService(session: session, tokenProvider: { token })
    }

    private func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.mapbox.com/directions/v5/mapbox/driving/")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    // MARK: Single-route parse

    func testFetchRoute_singleRoute_decodesPrimary() async throws {
        let body = Self.singleRouteJSON.data(using: .utf8)!
        let service = makeService { _ in (self.httpResponse(status: 200), body) }

        let routes = try await service.fetchRoute(from: origin, to: destination)

        XCTAssertEqual(routes.count, 1)
        let route = routes[0]
        XCTAssertEqual(route.distance, 1234.5, accuracy: 0.001)
        XCTAssertEqual(route.duration, 234.7, accuracy: 0.001)
        XCTAssertEqual(route.geometry.count, 3)
        XCTAssertEqual(route.geometry[0].latitude, 40.7128, accuracy: 1e-6)
        XCTAssertEqual(route.geometry[0].longitude, -74.0060, accuracy: 1e-6)
        XCTAssertEqual(route.steps.count, 2)
        XCTAssertEqual(route.steps[0].maneuverType, "depart")
        XCTAssertNil(route.steps[0].maneuverModifier)
        XCTAssertEqual(route.steps[1].maneuverType, "turn")
        XCTAssertEqual(route.steps[1].maneuverModifier, "left")
        XCTAssertEqual(route.steps[1].instruction, "Turn left onto Broadway")
    }

    // MARK: Alternatives parse

    func testFetchRoute_alternatives_decodesAllThree() async throws {
        let body = Self.threeRoutesJSON.data(using: .utf8)!
        let service = makeService { _ in (self.httpResponse(status: 200), body) }

        let routes = try await service.fetchRoute(from: origin, to: destination, alternatives: true)

        XCTAssertEqual(routes.count, 3)
        XCTAssertEqual(routes[0].distance, 1000.0, accuracy: 0.001)
        XCTAssertEqual(routes[1].distance, 1500.0, accuracy: 0.001)
        XCTAssertEqual(routes[2].distance, 2000.0, accuracy: 0.001)
        // Sanity: alternatives flag made it into the URL
        let urlString = MockURLProtocol.lastURL?.absoluteString ?? ""
        XCTAssertTrue(urlString.contains("alternatives=true"), "alternatives flag missing in URL: \(urlString)")
    }

    // MARK: Network error

    func testFetchRoute_networkError_throwsNetwork() async {
        let service = makeService { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await service.fetchRoute(from: origin, to: destination)
            XCTFail("expected MapboxRouteError.network")
        } catch let MapboxRouteError.network(message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("expected .network, got \(error)")
        }
    }

    // MARK: HTTP error responses

    func testFetchRoute_http4xx_throwsHTTP() async {
        let service = makeService { _ in
            (self.httpResponse(status: 401), Data("{\"message\":\"unauthorized\"}".utf8))
        }
        do {
            _ = try await service.fetchRoute(from: origin, to: destination)
            XCTFail("expected MapboxRouteError.http(401)")
        } catch let MapboxRouteError.http(status) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("expected .http(401), got \(error)")
        }
    }

    func testFetchRoute_http5xx_throwsHTTP() async {
        let service = makeService { _ in
            (self.httpResponse(status: 503), Data("{\"message\":\"service unavailable\"}".utf8))
        }
        do {
            _ = try await service.fetchRoute(from: origin, to: destination)
            XCTFail("expected MapboxRouteError.http(503)")
        } catch let MapboxRouteError.http(status) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("expected .http(503), got \(error)")
        }
    }

    // MARK: Empty routes

    func testFetchRoute_emptyRoutes_throwsNoRoutes() async {
        let body = "{\"routes\":[]}".data(using: .utf8)!
        let service = makeService { _ in (self.httpResponse(status: 200), body) }
        do {
            _ = try await service.fetchRoute(from: origin, to: destination)
            XCTFail("expected MapboxRouteError.noRoutes")
        } catch MapboxRouteError.noRoutes {
            // expected
        } catch {
            XCTFail("expected .noRoutes, got \(error)")
        }
    }

    // MARK: Missing token

    func testFetchRoute_missingToken_throwsMissingToken() async {
        let service = makeService(token: nil) { _ in
            XCTFail("URLSession should not be called when token is missing")
            return (self.httpResponse(status: 200), Data())
        }
        do {
            _ = try await service.fetchRoute(from: origin, to: destination)
            XCTFail("expected MapboxRouteError.missingToken")
        } catch MapboxRouteError.missingToken {
            // expected
        } catch {
            XCTFail("expected .missingToken, got \(error)")
        }
    }

    func testFetchRoute_emptyTokenString_throwsMissingToken() async {
        let service = makeService(token: "   ") { _ in
            XCTFail("URLSession should not be called when token is whitespace")
            return (self.httpResponse(status: 200), Data())
        }
        do {
            _ = try await service.fetchRoute(from: origin, to: destination)
            XCTFail("expected MapboxRouteError.missingToken")
        } catch MapboxRouteError.missingToken {
            // expected
        } catch {
            XCTFail("expected .missingToken, got \(error)")
        }
    }

    // MARK: URL building

    func testBuildURL_includesExpectedQueryParams() throws {
        let url = try RouteService.buildURL(
            from: origin,
            to: destination,
            alternatives: true,
            token: "pk.test_TOKEN"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.scheme, "https")
        XCTAssertEqual(components?.host, "api.mapbox.com")
        // Coordinates use lng,lat;lng,lat order per Mapbox spec
        XCTAssertTrue(url.path.hasSuffix("/-74.006,40.7128;-73.9857,40.7484"),
                      "path coords wrong: \(url.path)")
        let items = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["access_token"], "pk.test_TOKEN")
        XCTAssertEqual(items["geometries"], "geojson")
        XCTAssertEqual(items["steps"], "true")
        XCTAssertEqual(items["overview"], "full")
        XCTAssertEqual(items["alternatives"], "true")
    }

    // MARK: Coordinate ordering (GeoJSON [lng,lat] → CLLocationCoordinate2D)

    func testFetchRoute_geoJSONLngLatOrder_convertsToLatLng() async throws {
        // Body geometry has clearly distinguishable lat/lng so a swapped
        // conversion would be obvious.
        let body = Self.coordOrderJSON.data(using: .utf8)!
        let service = makeService { _ in (self.httpResponse(status: 200), body) }
        let routes = try await service.fetchRoute(from: origin, to: destination)
        XCTAssertEqual(routes.count, 1)
        let coords = routes[0].geometry
        XCTAssertEqual(coords.count, 2)
        // GeoJSON pair was [-74.0, 40.7] — expect lat=40.7, lng=-74.0
        XCTAssertEqual(coords[0].latitude, 40.7, accuracy: 1e-9)
        XCTAssertEqual(coords[0].longitude, -74.0, accuracy: 1e-9)
        // GeoJSON pair was [-73.9, 40.8] — expect lat=40.8, lng=-73.9
        XCTAssertEqual(coords[1].latitude, 40.8, accuracy: 1e-9)
        XCTAssertEqual(coords[1].longitude, -73.9, accuracy: 1e-9)
        // Maneuver location was [-74.0, 40.7]
        let maneuverCoord = try XCTUnwrap(routes[0].steps.first?.maneuverLocation)
        XCTAssertEqual(maneuverCoord.latitude, 40.7, accuracy: 1e-9)
        XCTAssertEqual(maneuverCoord.longitude, -74.0, accuracy: 1e-9)
    }

    // MARK: - JSON fixtures

    private static let singleRouteJSON = """
    {
      "routes": [
        {
          "distance": 1234.5,
          "duration": 234.7,
          "geometry": {
            "type": "LineString",
            "coordinates": [
              [-74.0060, 40.7128],
              [-73.9950, 40.7300],
              [-73.9857, 40.7484]
            ]
          },
          "legs": [
            {
              "steps": [
                {
                  "distance": 50.0,
                  "duration": 10.0,
                  "geometry": { "type": "LineString", "coordinates": [[-74.0060, 40.7128], [-74.0050, 40.7140]] },
                  "maneuver": {
                    "location": [-74.0060, 40.7128],
                    "type": "depart",
                    "instruction": "Head north on Broadway"
                  }
                },
                {
                  "distance": 1184.5,
                  "duration": 224.7,
                  "geometry": { "type": "LineString", "coordinates": [[-74.0050, 40.7140], [-73.9857, 40.7484]] },
                  "maneuver": {
                    "location": [-74.0050, 40.7140],
                    "type": "turn",
                    "modifier": "left",
                    "instruction": "Turn left onto Broadway"
                  }
                }
              ]
            }
          ]
        }
      ]
    }
    """

    private static let threeRoutesJSON = """
    {
      "routes": [
        {
          "distance": 1000.0, "duration": 200.0,
          "geometry": { "type": "LineString", "coordinates": [[-74.0,40.7],[-73.9,40.8]] },
          "legs": [{"steps":[{"distance":1000.0,"duration":200.0,
            "geometry":{"type":"LineString","coordinates":[[-74.0,40.7],[-73.9,40.8]]},
            "maneuver":{"location":[-74.0,40.7],"type":"depart","instruction":"Head north"}}]}]
        },
        {
          "distance": 1500.0, "duration": 300.0,
          "geometry": { "type": "LineString", "coordinates": [[-74.0,40.7],[-73.9,40.8]] },
          "legs": [{"steps":[{"distance":1500.0,"duration":300.0,
            "geometry":{"type":"LineString","coordinates":[[-74.0,40.7],[-73.9,40.8]]},
            "maneuver":{"location":[-74.0,40.7],"type":"depart","instruction":"Head north"}}]}]
        },
        {
          "distance": 2000.0, "duration": 400.0,
          "geometry": { "type": "LineString", "coordinates": [[-74.0,40.7],[-73.9,40.8]] },
          "legs": [{"steps":[{"distance":2000.0,"duration":400.0,
            "geometry":{"type":"LineString","coordinates":[[-74.0,40.7],[-73.9,40.8]]},
            "maneuver":{"location":[-74.0,40.7],"type":"depart","instruction":"Head north"}}]}]
        }
      ]
    }
    """

    private static let coordOrderJSON = """
    {
      "routes": [
        {
          "distance": 100.0, "duration": 20.0,
          "geometry": {
            "type": "LineString",
            "coordinates": [ [-74.0, 40.7], [-73.9, 40.8] ]
          },
          "legs": [
            {
              "steps": [
                {
                  "distance": 100.0, "duration": 20.0,
                  "geometry": { "type": "LineString", "coordinates": [ [-74.0, 40.7], [-73.9, 40.8] ] },
                  "maneuver": {
                    "location": [-74.0, 40.7],
                    "type": "depart",
                    "instruction": "Head east"
                  }
                }
              ]
            }
          ]
        }
      ]
    }
    """
}
