//
//  ClipBlockInsight.swift
//  Shared/SpotPass/Driver
//
//  "Show me this block" (spec 6.1 beat 2, design 3.5): ONE hosted tile fetch for the coordinate
//  (about 29 KB; the same files the PWA serves) plus a minimal on-device street-cleaning
//  evaluator. No map, no bundled tiles (size), nothing stored, nothing sent but the tile row/col in
//  the request path.
//
//  Scope: street cleaning (alternate side parking) only, which is what design 3.5 shows. It never
//  says "free", "legal" or "safe". ASP holiday suspensions come from the SAME `asp-2026.json` the
//  full app reads (it lives in Shared/, so both bundles carry the one file): a suspended day is
//  skipped, so it is never "Next" and never "cleaning now". The "Always check the posted signs"
//  footer stays (the calendar covers 2026 only).
//

import Foundation
import Observation

// MARK: - Tile model (decoded subset)

nonisolated struct ClipTileRule: Decodable, Equatable, Sendable {
    nonisolated struct Range: Decodable, Equatable, Sendable {
        let start: Int
        let end: Int
    }
    let category: String
    let days: [Int]
    let timeRanges: [Range]
    let anytime: Bool

    init(category: String, days: [Int], timeRanges: [Range], anytime: Bool) {
        self.category = category
        self.days = days
        self.timeRanges = timeRanges
        self.anytime = anytime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        category = try c.decode(String.self, forKey: .category)
        days = try c.decodeIfPresent([Int].self, forKey: .days) ?? []
        timeRanges = try c.decodeIfPresent([Range].self, forKey: .timeRanges) ?? []
        anytime = try c.decodeIfPresent(Bool.self, forKey: .anytime) ?? false
    }

    private enum Keys: String, CodingKey { case category, days, timeRanges, anytime }
}

nonisolated struct ClipTileSegment: Decodable, Equatable, Sendable {
    let street: String
    let fromStreet: String
    let to: String
    let side: String
    /// `[lat, lng]` pairs.
    let line: [[Double]]
    let rules: [ClipTileRule]

    init(street: String, fromStreet: String, to: String, side: String, line: [[Double]], rules: [ClipTileRule]) {
        self.street = street
        self.fromStreet = fromStreet
        self.to = to
        self.side = side
        self.line = line
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case street, to, side, line, rules
        case fromStreet = "from"
    }

    /// Direction-agnostic blockface identity without the side (both curbs of one block share it).
    var blockKey: String {
        let (lo, hi) = fromStreet <= to ? (fromStreet, to) : (to, fromStreet)
        return "\(street)|\(lo)|\(hi)"
    }
}

// MARK: - Tile grid (constants from tiles/index.json)

nonisolated enum ClipTileGrid {
    static let latMin = 40.7
    static let lngMin = -74.02
    static let rowSize = 0.002274999999999938
    static let colSize = 0.0022599999999999907
    static let rows = 80
    static let cols = 50

    /// Hosted tile set (the PWA's GitHub Pages deploy; same files as `tiles/`).
    static let hostedBaseURL = "https://kevhox1.github.io/parkmap/tiles/"

    static func tile(latitude: Double, longitude: Double) -> (row: Int, col: Int)? {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        let r = ((latitude - latMin) / rowSize).rounded(.down)
        let c = ((longitude - lngMin) / colSize).rounded(.down)
        guard r >= 0, c >= 0, r < Double(rows), c < Double(cols) else { return nil }
        return (Int(r), Int(c))
    }

    static func url(row: Int, col: Int) -> URL? {
        URL(string: "\(hostedBaseURL)tile_\(row)_\(col).json")
    }
}

// MARK: - ASP suspension calendar

/// The set of ET calendar days (`yyyy-MM-dd`) when alternate side parking is suspended.
nonisolated struct ClipSuspensions: Equatable, Sendable {
    let dates: Set<String>

    static let empty = ClipSuspensions(dates: [])

    init(dates: Set<String>) { self.dates = dates }

    /// Decodes the app's `asp-2026.json` bytes. Malformed data degrades to "no suspensions".
    init(jsonData: Data) {
        let calendar = try? JSONDecoder().decode(ASPSuspensionCalendar.self, from: jsonData)
        self.dates = Set(calendar?.dates.map(\.date) ?? [])
    }

    /// The calendar bundled with this target (`asp-2026.json`, shared with the full app).
    static func bundled(_ bundle: Bundle = .main) -> ClipSuspensions {
        guard let url = bundle.url(forResource: "asp-2026", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return .empty }
        return ClipSuspensions(jsonData: data)
    }

    /// `day` is any instant; the Eastern calendar day it falls on is what counts.
    func isSuspended(_ day: Date) -> Bool {
        let parts = StreetCleaningEvaluator.calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return false }
        return dates.contains(String(format: "%04d-%02d-%02d", year, month, dayOfMonth))
    }
}

// MARK: - Street cleaning evaluation

nonisolated struct CleaningWindow: Equatable, Sendable {
    let start: Date
    let end: Date

    func isInEffect(at now: Date) -> Bool { start <= now && now < end }
}

nonisolated enum StreetCleaningEvaluator {

    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return cal
    }()

    /// Mirrors `Category.isASPDay` (0 = Sunday ... 6 = Saturday). A parity test pins the two.
    static func aspDays(category: String) -> Set<Int>? {
        switch category {
        case "ASP_MON_THU": return [1, 4]
        case "ASP_TUE_FRI": return [2, 5]
        case "ASP_OVERNIGHT_MWF": return [1, 3, 5]
        case "ASP_OVERNIGHT_TTHS": return [2, 4, 6]
        case "ASP_DAILY": return [1, 2, 3, 4, 5, 6]
        default: return nil
        }
    }

    /// The window in progress, or the next one, within 14 days. nil if the rules have no cleaning.
    static func nextWindow(rules: [ClipTileRule], now: Date, suspensions: ClipSuspensions = .empty) -> CleaningWindow? {
        var best: CleaningWindow?
        let today = calendar.startOfDay(for: now)
        for rule in rules {
            guard let categoryDays = aspDays(category: rule.category) else { continue }
            let ranges = rule.timeRanges.isEmpty
                ? (rule.anytime ? [ClipTileRule.Range(start: 0, end: 1440)] : [])
                : rule.timeRanges
            for offset in 0...14 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                guard !suspensions.isSuspended(day) else { continue }   // ASP holiday: no cleaning that day
                let weekday = calendar.component(.weekday, from: day) - 1
                guard categoryDays.contains(weekday), rule.days.isEmpty || rule.days.contains(weekday) else { continue }
                for range in ranges {
                    let start = day.addingTimeInterval(Double(range.start) * 60)
                    var end = day.addingTimeInterval(Double(range.end) * 60)
                    if range.end <= range.start { end = end.addingTimeInterval(86_400) }   // crosses midnight
                    guard end > now else { continue }
                    let window = CleaningWindow(start: start, end: end)
                    if best == nil || window.start < best!.start { best = window }
                }
            }
        }
        return best
    }
}

// MARK: - Block lookup

nonisolated struct ClipBlockSide: Equatable, Sendable {
    let side: String
    let window: CleaningWindow?
}

nonisolated struct ClipBlockResult: Equatable, Sendable {
    /// Nearest curb first; the other curb (if the tile has it) second ("Wrong side? Switch").
    let sides: [ClipBlockSide]
}

nonisolated enum ClipBlockLookup {

    /// Farther than this from any curb line and we say we have no rule for this block.
    static let maxSnapMeters = 75.0

    static func decode(_ data: Data) -> [ClipTileSegment]? {
        try? JSONDecoder().decode([ClipTileSegment].self, from: data)
    }

    static func lookup(
        latitude: Double, longitude: Double, segments: [ClipTileSegment], now: Date, suspensions: ClipSuspensions = .empty
    ) -> ClipBlockResult? {
        var nearest: (segment: ClipTileSegment, meters: Double)?
        for segment in segments {
            guard let meters = distanceMeters(latitude: latitude, longitude: longitude, line: segment.line) else { continue }
            if nearest == nil || meters < nearest!.meters { nearest = (segment, meters) }
        }
        guard let nearest, nearest.meters <= maxSnapMeters else { return nil }

        var sides: [ClipBlockSide] = [
            ClipBlockSide(side: nearest.segment.side,
                          window: StreetCleaningEvaluator.nextWindow(rules: nearest.segment.rules, now: now, suspensions: suspensions))
        ]
        // The other curb of the same block: nearest sub-segment on a different side.
        var other: (segment: ClipTileSegment, meters: Double)?
        for segment in segments where segment.blockKey == nearest.segment.blockKey && segment.side != nearest.segment.side {
            guard let meters = distanceMeters(latitude: latitude, longitude: longitude, line: segment.line) else { continue }
            if other == nil || meters < other!.meters { other = (segment, meters) }
        }
        if let other {
            sides.append(ClipBlockSide(side: other.segment.side,
                                       window: StreetCleaningEvaluator.nextWindow(rules: other.segment.rules, now: now, suspensions: suspensions)))
        }
        return ClipBlockResult(sides: sides)
    }

    /// Distance from a point to a `[lat, lng]` polyline, in meters (local planar projection).
    static func distanceMeters(latitude: Double, longitude: Double, line: [[Double]]) -> Double? {
        let points = line.compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil }
        guard !points.isEmpty else { return nil }
        let metersPerDegLat = 111_320.0
        let metersPerDegLng = 111_320.0 * cos(latitude * .pi / 180)
        func xy(_ p: (Double, Double)) -> (Double, Double) {
            ((p.1 - longitude) * metersPerDegLng, (p.0 - latitude) * metersPerDegLat)
        }
        if points.count == 1 {
            let p = xy(points[0])
            return (p.0 * p.0 + p.1 * p.1).squareRoot()
        }
        var best = Double.greatestFiniteMagnitude
        for i in 0..<(points.count - 1) {
            let a = xy(points[i]), b = xy(points[i + 1])
            let dx = b.0 - a.0, dy = b.1 - a.1
            let lengthSquared = dx * dx + dy * dy
            var t = lengthSquared > 0 ? -(a.0 * dx + a.1 * dy) / lengthSquared : 0
            t = min(1, max(0, t))
            let px = a.0 + t * dx, py = a.1 + t * dy
            best = min(best, (px * px + py * py).squareRoot())
        }
        return best
    }
}

// MARK: - Formatting (Eastern Time: the rules are NYC's)

nonisolated enum ClipBlockFormat {

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = StreetCleaningEvaluator.calendar.timeZone
        f.dateFormat = format
        return f
    }

    /// "Tuesday, 8:00 - 9:30 AM"
    static func windowLine(_ window: CleaningWindow) -> String {
        let day = formatter("EEEE").string(from: window.start)
        let start = formatter("h:mm").string(from: window.start)
        let end = formatter("h:mm a").string(from: window.end)
        return "\(day), \(start) - \(end)"
    }

    /// "Next: Tue, Dec 2"
    static func nextLine(_ window: CleaningWindow) -> String {
        "Next: \(formatter("EEE, MMM d").string(from: window.start))"
    }

    /// One VoiceOver sentence for the whole result card (design 3.10).
    static func accessibilitySummary(_ window: CleaningWindow?, now: Date) -> String {
        guard let window else { return "This block. \(ClipCopy.blockNoRule)" }
        let day = formatter("EEEE").string(from: window.start)
        let start = formatter("h:mm").string(from: window.start)
        let end = formatter("h:mm a").string(from: window.end)
        let date = formatter("EEEE, MMMM d").string(from: window.start)
        let lead = window.isInEffect(at: now) ? "\(ClipCopy.blockHappeningNow) " : ""
        return "This block. \(lead)Street cleaning on this side: \(day), \(start) to \(end). Next: \(date)."
    }
}

// MARK: - Collaborators

nonisolated struct ClipCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

nonisolated enum ClipLocationError: Error, Equatable, Sendable {
    case denied
    case unavailable
}

@MainActor
protocol ClipLocationProviding: AnyObject {
    /// One When-In-Use fix. Prompts once if undetermined. Throws `.denied` / `.unavailable`.
    func requestCoordinate() async throws -> ClipCoordinate
}

@MainActor
protocol ClipTileFetching: AnyObject {
    /// The tile's JSON bytes, or nil when the grid cell has no tile (404).
    func tile(row: Int, col: Int) async throws -> Data?
}

@MainActor
final class URLSessionClipTileFetcher: ClipTileFetching {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    func tile(row: Int, col: Int) async throws -> Data? {
        guard let url = ClipTileGrid.url(row: row, col: col) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HandoffAPIError.malformedResponse }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw HandoffAPIError.server(statusCode: http.statusCode) }
        return data
    }
}

// MARK: - Controller

nonisolated enum ClipBlockState: Equatable, Sendable {
    case idle
    case locating
    case loading
    case result(ClipBlockResult, sideIndex: Int)
    case noRule
    case denied
    case failed
}

@Observable
@MainActor
final class ClipBlockController {
    private(set) var state: ClipBlockState = .idle

    @ObservationIgnored private let location: any ClipLocationProviding
    @ObservationIgnored private let tiles: any ClipTileFetching
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let suspensions: ClipSuspensions

    init(
        location: any ClipLocationProviding, tiles: any ClipTileFetching,
        suspensions: ClipSuspensions = .bundled(), now: @escaping () -> Date = { Date() }
    ) {
        self.location = location
        self.tiles = tiles
        self.suspensions = suspensions
        self.now = now
    }

    /// The single, explained tap (the only place the clip asks for location).
    func show() async {
        guard state == .idle || state == .failed else { return }
        state = .locating
        let coordinate: ClipCoordinate
        do {
            coordinate = try await location.requestCoordinate()
        } catch ClipLocationError.denied {
            state = .denied
            return
        } catch {
            state = .failed
            return
        }
        guard let cell = ClipTileGrid.tile(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            state = .noRule
            return
        }
        state = .loading
        do {
            guard let data = try await tiles.tile(row: cell.row, col: cell.col) else {
                state = .noRule          // no tile for this grid cell
                return
            }
            guard let segments = ClipBlockLookup.decode(data) else {
                state = .failed
                return
            }
            if let result = ClipBlockLookup.lookup(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                                   segments: segments, now: now(), suspensions: suspensions) {
                state = .result(result, sideIndex: 0)
            } else {
                state = .noRule
            }
        } catch {
            state = .failed
        }
    }

    func switchSide() {
        guard case .result(let result, let index) = state, result.sides.count > 1 else { return }
        state = .result(result, sideIndex: (index + 1) % result.sides.count)
    }
}
