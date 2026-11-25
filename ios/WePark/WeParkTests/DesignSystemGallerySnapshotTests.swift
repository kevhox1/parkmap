//
//  DesignSystemGallerySnapshotTests.swift
//  WeParkTests
//
//  Renders every DEBUG gallery section to PNG (light, dark, light AX5) with `ImageRenderer`, for
//  the QA screenshots in docs/qa/assets/ds-phase1/. Does nothing unless the environment variable
//  WEPARK_DS_SNAPSHOT_DIR is set (pass it as TEST_RUNNER_WEPARK_DS_SNAPSHOT_DIR to xcodebuild), so
//  the normal suite just skips it. Asserts only that each render produced an image.
//

#if DEBUG

import XCTest
import SwiftUI
import UIKit
@testable import WePark

@MainActor
final class DesignSystemGallerySnapshotTests: XCTestCase {

    func testRenderGallerySections() throws {
        guard let dir = ProcessInfo.processInfo.environment["WEPARK_DS_SNAPSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("WEPARK_DS_SNAPSHOT_DIR not set")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let variants: [(String, ColorScheme, DynamicTypeSize)] = [
            ("light", .light, .large),
            ("dark", .dark, .large),
            ("light-ax5", .light, .accessibility5),
        ]
        for section in WPGallerySection.allCases {
            for (name, scheme, size) in variants {
                let slug = section.rawValue.lowercased()
                    .replacingOccurrences(of: ", ", with: "-")
                    .replacingOccurrences(of: " ", with: "-")
                let view = WPGallerySectionView(section: section)
                    .padding(WP.Space.screenMargin)
                    .frame(width: 393, alignment: .leading)
                    .background(WP.paper)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, size)
                let renderer = ImageRenderer(content: view)
                renderer.scale = size.isAccessibilitySize ? 0.75 : 2
                let image = try XCTUnwrap(renderer.uiImage, "\(section.rawValue) \(name)")
                let data = try XCTUnwrap(image.pngData())
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(slug)-\(name).png"))
            }
        }
    }
}

#endif
