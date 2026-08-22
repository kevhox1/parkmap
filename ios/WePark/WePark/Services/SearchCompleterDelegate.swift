//
//  SearchCompleterDelegate.swift
//  WePark
//
//  FT-20 Stream C: relocated out of `Views/DriveModeDestinationView.swift` when that file
//  was deleted (docs/ft20-bottom-sheet-navigation-spec.md §0c). Both types are shared,
//  UIKit-adjacent plumbing with zero SwiftUI-view-specific logic — they belong in
//  `Services/`, matching `RecentDestinationsStore.swift`'s own N-1 lift (W8.5c) out of the
//  same file for the same reason. `Views/BrowseSearchAreaView.swift` (the sole remaining
//  consumer, now that `DriveModeDestinationView` is gone) references both by name with no
//  other change required.
//

import MapKit

// MARK: - SearchCompleterDelegate

/// `@Observable` bridge between `MKLocalSearchCompleter` (UIKit NSObject delegate)
/// and SwiftUI. Owned by `BrowseSearchAreaView` as a `@State` object.
///
/// Pattern from the original W8.5b spec §7 Risk 1: the completer must live in a reference
/// type, not directly in a SwiftUI View struct, or it will be re-created on every render.
@Observable
final class SearchCompleterDelegate: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

// MARK: - SearchTimeoutError

/// Sentinel error thrown by `BrowseSearchAreaView.selectCompletion`'s timeout race (M-1,
/// originally `DriveModeDestinationView`). Internal visibility (not private) so the M-1
/// unit test can reference it via `@testable import WePark`.
struct SearchTimeoutError: Error {}
