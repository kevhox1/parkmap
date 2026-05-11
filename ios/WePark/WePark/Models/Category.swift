//
//  Category.swift
//  WePark
//
//  Parking category enum whose raw values must match the CATEGORIES keys in
//  index.html:1558 character-for-character. Do not rename cases without
//  auditing every tile JSON file — the string values are stored in tile data.
//
//  W3 change: removed `swiftUIColor` (the static interim added in W2).
//  Dynamic color is now produced by ParkingRulesEngine.currentStateColor(for:at:),
//  which reflects the block's CURRENT parking state rather than its static category.
//  Callers that used `category.swiftUIColor` should migrate to the engine.
//

import Foundation

enum Category: String, Codable, CaseIterable {
    // ASP variants
    case aspMonThu       = "ASP_MON_THU"
    case aspTueFri       = "ASP_TUE_FRI"
    case aspOvernightMWF = "ASP_OVERNIGHT_MWF"
    case aspOvernightTTHS = "ASP_OVERNIGHT_TTHS"
    case aspDaily        = "ASP_DAILY"

    // Paid parking
    case metered         = "METERED"

    // Restricted
    case truckLoading    = "TRUCK_LOADING"
    case noParking       = "NO_PARKING"
    case noStanding      = "NO_STANDING"
    case special         = "SPECIAL"

    // Unrestricted / unknown
    case free            = "FREE"
    case unknown         = "UNKNOWN"

    // MARK: - Display label
    /// Human-readable label matching the JS CATEGORIES.label values.
    var label: String {
        switch self {
        case .aspMonThu:        return "ASP Mon/Thu"
        case .aspTueFri:        return "ASP Tue/Fri"
        case .aspOvernightMWF:  return "ASP Night MWF"
        case .aspOvernightTTHS: return "ASP Night TThS"
        case .aspDaily:         return "ASP Daily"
        case .metered:          return "Metered"
        case .truckLoading:     return "Truck Loading"
        case .noParking:        return "No Parking"
        case .noStanding:       return "No Standing/Stop"
        case .special:          return "Special"
        case .free:             return "Free"
        case .unknown:          return "Unknown"
        }
    }

    // MARK: - Priority (mirrors JS CATEGORIES.priority; lower = more restrictive)
    /// Used by ParkingRulesEngine when computing dominantCategory.
    var priority: Int {
        switch self {
        case .noStanding:       return 1
        case .noParking:        return 2
        case .special:          return 3
        case .truckLoading:     return 4
        case .metered:          return 5
        case .aspDaily:         return 6
        case .aspMonThu:        return 7
        case .aspTueFri:        return 8
        case .aspOvernightMWF:  return 9
        case .aspOvernightTTHS: return 10
        case .unknown:          return 11
        case .free:             return 99
        }
    }

    // MARK: - ASP helpers
    /// True for any alternate-side-parking street-cleaning category.
    var isASP: Bool {
        switch self {
        case .aspMonThu, .aspTueFri, .aspOvernightMWF, .aspOvernightTTHS, .aspDaily:
            return true
        default:
            return false
        }
    }

    /// True if this ASP category applies on the given day-of-week (0 = Sunday ... 6 = Saturday),
    /// mirroring JS isASPDayForCategory(cat, dayOfWeek) at index.html:1689.
    func isASPDay(_ dayOfWeek: Int) -> Bool {
        switch self {
        case .aspMonThu:
            return dayOfWeek == 1 || dayOfWeek == 4   // Mon, Thu
        case .aspTueFri:
            return dayOfWeek == 2 || dayOfWeek == 5   // Tue, Fri
        case .aspOvernightMWF:
            return dayOfWeek == 1 || dayOfWeek == 3 || dayOfWeek == 5 // Mon, Wed, Fri
        case .aspOvernightTTHS:
            return dayOfWeek == 2 || dayOfWeek == 4 || dayOfWeek == 6 // Tue, Thu, Sat
        case .aspDaily:
            // ASP_DAILY applies Mon–Sat; Sunday is never an ASP day.
            return dayOfWeek >= 1 && dayOfWeek <= 6
        default:
            return false
        }
    }
}
