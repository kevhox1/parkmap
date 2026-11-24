//
//  SpotPassQR.swift
//  Services/SpotPass
//
//  Spot Pass C1: the badge's one non-negotiable job is to decode (`docs/design/spot-pass-design.md`
//  §1.5, the engineering contract). This file owns the three pieces:
//
//    1. `SpotPassQR.urlString(token:)`  `https://getwepark.com/p#t=<22 chars>`, at most 62 bytes
//       (the v4-M budget). 48 bytes for the registered domain.
//    2. `SpotPassQR.matrix(for:)`        CoreImage `CIQRCodeGenerator` at error-correction M, read
//       back into a module matrix (so we can draw it ourselves).
//    3. `SpotPassQRRenderer.image(...)` the branded render: dark-on-white only, 8 pt modules at
//       integer pixel boundaries (24 px at 3x), a 4-module white quiet zone INSIDE the bitmap
//       (nothing drawn in it), slightly rounded data modules, finder eyes with rounded OUTER corners
//       and an indigo 3x3 pupil, and a 5x5-module center mark (about 2.3% of the symbol). No blur,
//       no gradient, no translucency, no resampling: the plate is a bitmap shown with
//       `.interpolation(.none)`.
//
//  Reliability beats brand (design §1.5 fallback): `centerMark: false` drops the mark entirely.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - Matrix

nonisolated struct SpotPassQRMatrix: Equatable, Sendable {
    /// Modules per side (33 for version 4).
    let size: Int
    /// Row-major, `true` = dark module. Quiet zone not included.
    let modules: [Bool]

    func isDark(row: Int, col: Int) -> Bool {
        guard row >= 0, col >= 0, row < size, col < size else { return false }
        return modules[row * size + col]
    }
}

// MARK: - Payload and generation

nonisolated enum SpotPassQR {

    /// Design §1.5: fits version 4 at ECC M. A longer URL is refused rather than silently
    /// generating a denser, harder-to-scan code.
    static let urlByteBudget = 62

    /// Version 4 = 33 x 33 modules (the design's default for a 48-byte URL at ECC M).
    static let expectedModuleCount = 33

    /// 8 pt module = 24 px at 3x, an integer pixel multiple (blur-free).
    static let moduleSizePoints: CGFloat = 8

    /// QR spec minimum. The white plate IS the quiet zone: (33 + 8) x 8 = 328 pt.
    static let quietZoneModules = 4

    /// `https://getwepark.com/p#t=<token>`, or nil if the token is malformed or the URL would
    /// exceed the byte budget.
    static func urlString(token: String) -> String? {
        guard SpotPassLink.isValidToken(token) else { return nil }
        let string = "https://\(SpotPassShared.universalLinkHost)\(SpotPassShared.landingPath)#t=\(token)"
        guard string.utf8.count <= urlByteBudget else { return nil }
        return string
    }

    static func url(token: String) -> URL? {
        urlString(token: token).flatMap(URL.init(string:))
    }

    /// Generates the QR at error-correction level M and reads the module grid back out.
    /// CoreImage's output carries no guaranteed border, so the grid is cropped to the bounding
    /// box of dark pixels (a QR's finder patterns touch all four extremes), then validated as a
    /// legal QR size (17 + 4 x version).
    static func matrix(for string: String) -> SpotPassQRMatrix? {
        guard let data = string.data(using: .utf8), !data.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, width == height else { return nil }

        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(output, from: extent) else { return nil }

        var pixels = [UInt8](repeating: 255, count: width * height)
        let drew: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let bitmap = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            bitmap.interpolationQuality = .none
            bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        var minRow = height, maxRow = -1, minCol = width, maxCol = -1
        for row in 0..<height {
            for col in 0..<width where pixels[row * width + col] < 128 {
                minRow = min(minRow, row); maxRow = max(maxRow, row)
                minCol = min(minCol, col); maxCol = max(maxCol, col)
            }
        }
        guard maxRow >= minRow, maxCol >= minCol else { return nil }
        let size = maxCol - minCol + 1
        guard size == maxRow - minRow + 1, size >= 21, (size - 17) % 4 == 0 else { return nil }

        var modules = [Bool](repeating: false, count: size * size)
        for row in 0..<size {
            for col in 0..<size {
                modules[row * size + col] = pixels[(minRow + row) * width + (minCol + col)] < 128
            }
        }
        return SpotPassQRMatrix(size: size, modules: modules)
    }

    /// Convenience: token to matrix.
    static func matrix(forToken token: String) -> SpotPassQRMatrix? {
        urlString(token: token).flatMap(matrix(for:))
    }
}

// MARK: - Renderer

@MainActor
enum SpotPassQRRenderer {

    /// Design §1.1: `qrInk` modules, `qrEye` pupils.
    static let ink = UIColor(red: 0x0B / 255, green: 0x0B / 255, blue: 0x1E / 255, alpha: 1)
    static let eye = UIColor(red: 0x3F / 255, green: 0x3D / 255, blue: 0xB5 / 255, alpha: 1)

    /// Center mark: exactly 5 x 5 modules centered on module (16, 16) of the 33-module symbol.
    static let centerMarkModules = 14...18

    /// Plate side in points: (modules + 2 x quiet zone) x module size (328 pt for version 4).
    static func plateSide(moduleCount: Int) -> CGFloat {
        CGFloat(moduleCount + 2 * SpotPassQR.quietZoneModules) * SpotPassQR.moduleSizePoints
    }

    /// Finder-pattern squares (7 x 7 at three corners) are drawn separately.
    nonisolated static func isFinderZone(row: Int, col: Int, size: Int) -> Bool {
        (row < 7 && col < 7) || (row < 7 && col >= size - 7) || (row >= size - 7 && col < 7)
    }

    /// Renders the full plate: opaque white, quiet zone included. `scale` should be an integer
    /// (the screen scale) so every module lands on whole pixels.
    static func image(for matrix: SpotPassQRMatrix, scale: CGFloat, centerMark: Bool = true) -> UIImage {
        let n = matrix.size
        let q = SpotPassQR.quietZoneModules
        let unit = SpotPassQR.moduleSizePoints
        let side = plateSide(moduleCount: n)
        // The mark is specified against version 4's geometry (clear of its alignment pattern).
        let drawsMark = centerMark && n == SpotPassQR.expectedModuleCount

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)

        return renderer.image { rendererContext in
            let cg = rendererContext.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: side, height: side))

            func cell(col: Int, row: Int, cols: Int = 1, rows: Int = 1) -> CGRect {
                CGRect(
                    x: CGFloat(q + col) * unit,
                    y: CGFloat(q + row) * unit,
                    width: CGFloat(cols) * unit,
                    height: CGFloat(rows) * unit
                )
            }

            // Data modules: rounded (radius 0.25 module), 96% fill.
            ink.setFill()
            let inset = unit * 0.02
            for row in 0..<n {
                for col in 0..<n where matrix.isDark(row: row, col: col) {
                    if isFinderZone(row: row, col: col, size: n) { continue }
                    if drawsMark, centerMarkModules.contains(row), centerMarkModules.contains(col) { continue }
                    let rect = cell(col: col, row: row).insetBy(dx: inset, dy: inset)
                    UIBezierPath(roundedRect: rect, cornerRadius: unit * 0.25).fill()
                }
            }

            // Finder eyes: 1:1:3:1:1 kept exactly; only the OUTER corners are rounded (radius
            // 1 module); the inner hole is square; the 3x3 pupil is `qrEye`.
            for (row, col) in [(0, 0), (0, n - 7), (n - 7, 0)] {
                let ring = UIBezierPath(roundedRect: cell(col: col, row: row, cols: 7, rows: 7), cornerRadius: unit)
                ring.append(UIBezierPath(rect: cell(col: col + 1, row: row + 1, cols: 5, rows: 5)))
                ring.usesEvenOddFillRule = true
                ink.setFill()
                ring.fill()
                eye.setFill()
                UIBezierPath(rect: cell(col: col + 2, row: row + 2, cols: 3, rows: 3)).fill()
            }

            // Center mark: the 5x5 clearing is already white; draw the pin glyph in `qrInk`.
            if drawsMark {
                let box = cell(col: centerMarkModules.lowerBound, row: centerMarkModules.lowerBound, cols: 5, rows: 5)
                let configuration = UIImage.SymbolConfiguration(pointSize: unit * 3.2, weight: .bold)
                if let symbol = UIImage(systemName: "mappin", withConfiguration: configuration)?
                    .withTintColor(ink, renderingMode: .alwaysOriginal) {
                    let glyphSize = symbol.size
                    symbol.draw(in: CGRect(
                        x: box.midX - glyphSize.width / 2,
                        y: box.midY - glyphSize.height / 2,
                        width: glyphSize.width,
                        height: glyphSize.height
                    ))
                }
            }
        }
    }
}

// MARK: - Cache

/// One-entry cache so a SwiftUI re-render never re-rasterizes the plate (and the plate is ready,
/// at final size, before the card animates in: design §2.9).
@MainActor
enum SpotPassQRImageCache {
    private static var cachedKey: String?
    private static var cachedImage: UIImage?

    static func image(token: String, scale: CGFloat, centerMark: Bool = true) -> UIImage? {
        let key = "\(token)|\(scale)|\(centerMark)"
        if cachedKey == key, let cachedImage { return cachedImage }
        guard let matrix = SpotPassQR.matrix(forToken: token) else { return nil }
        let image = SpotPassQRRenderer.image(for: matrix, scale: scale, centerMark: centerMark)
        cachedKey = key
        cachedImage = image
        return image
    }

    static func clear() {
        cachedKey = nil
        cachedImage = nil
    }
}
