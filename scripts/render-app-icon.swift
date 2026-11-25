#!/usr/bin/env swift
//
//  render-app-icon.swift
//
//  Renders the WePark app icon (round-2 proposal A2, "Token on the curb"): the taxi-yellow car
//  token sitting on a curb that turns from solid green into dashed coral, on an ink-violet field.
//  Geometry is taken from docs/design/wepark-round2/screenshots/a2-app-icon-and-logo.png and the
//  A2 section of "WePark Round 2 - 1 Map.dc.html". No dependencies beyond the macOS SDK.
//
//  Usage (from the repo root):
//    swift scripts/render-app-icon.swift ios/WePark/WePark/Assets.xcassets/AppIcon.appiconset
//
//  Writes three 1024 x 1024 opaque PNGs (no alpha, as the App Store requires; iOS applies the
//  corner mask itself):
//    AppIcon.png         light / default  (ink-violet #241F45 field)
//    AppIcon-Dark.png    dark appearance  (deeper #100D24 field)
//    AppIcon-Tinted.png  tinted appearance (grayscale; the system applies the user's tint, so the
//                        solid line is brighter than the dashed one and the pair still reads
//                        park vs don't without colour)
//
//  The car glyph inside the token is a dark rounded block, as in the mock. The final glyph is
//  drawn later; this script is the single place to change it.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024

struct Palette {
    var field: CGColor
    var token: CGColor
    var glyph: CGColor
    var solid: CGColor
    var dashed: CGColor
}

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

func gray(_ value: CGFloat) -> CGColor {
    CGColor(srgbRed: value, green: value, blue: value, alpha: 1)
}

let light = Palette(field: rgb(0x241F45), token: rgb(0xFFD23F), glyph: rgb(0x241F45),
                    solid: rgb(0x3CCF7A), dashed: rgb(0xE39A90))
let dark = Palette(field: rgb(0x100D24), token: rgb(0xFFD23F), glyph: rgb(0x241F45),
                   solid: rgb(0x3CCF7A), dashed: rgb(0xE39A90))
let tinted = Palette(field: gray(0.10), token: gray(0.92), glyph: gray(0.14),
                     solid: gray(0.80), dashed: gray(0.50))

// MARK: Geometry (1024 canvas; measured from the A2.1 mock)

let curbCenterY: CGFloat = 718
let curbThickness: CGFloat = 76
let solidEndX: CGFloat = 580
let dashStartX: CGFloat = 652
let dashLength: CGFloat = 106
let dashPitch: CGFloat = 188

let tokenDiameter: CGFloat = 496
let tokenCenter = CGPoint(x: 392, y: 424)   // top-left origin; converted when drawing

func render(_ palette: Palette) -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Flip to a top-left origin so the numbers above read like the mock.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    // Field.
    ctx.setFillColor(palette.field)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    // Curb: solid, then broken. Butt caps so the dashes are crisp rectangles.
    let curbTop = curbCenterY - curbThickness / 2
    ctx.setFillColor(palette.solid)
    ctx.fill(CGRect(x: 0, y: curbTop, width: solidEndX, height: curbThickness))
    ctx.setFillColor(palette.dashed)
    var x = dashStartX
    while x < size {
        ctx.fill(CGRect(x: x, y: curbTop, width: min(dashLength, size - x), height: curbThickness))
        x += dashPitch
    }

    // Token: taxi disc sitting on the curb.
    let tokenRect = CGRect(
        x: tokenCenter.x - tokenDiameter / 2, y: tokenCenter.y - tokenDiameter / 2,
        width: tokenDiameter, height: tokenDiameter
    )
    ctx.setFillColor(palette.token)
    ctx.fillEllipse(in: tokenRect)

    // Glyph: dark rounded block (26 x 16 on a 61 token in the mock = 0.43 x 0.26).
    let glyphWidth = tokenDiameter * 0.43
    let glyphHeight = tokenDiameter * 0.27
    let glyphRect = CGRect(
        x: tokenCenter.x - glyphWidth / 2, y: tokenCenter.y - glyphHeight / 2,
        width: glyphWidth, height: glyphHeight
    )
    // Top corners rounder than the bottom ones (mock: 6 6 3 3).
    let topRadius = glyphHeight * 0.38
    let bottomRadius = glyphHeight * 0.19
    let path = CGMutablePath()
    path.move(to: CGPoint(x: glyphRect.minX + topRadius, y: glyphRect.minY))
    path.addLine(to: CGPoint(x: glyphRect.maxX - topRadius, y: glyphRect.minY))
    path.addArc(tangent1End: CGPoint(x: glyphRect.maxX, y: glyphRect.minY),
                tangent2End: CGPoint(x: glyphRect.maxX, y: glyphRect.minY + topRadius), radius: topRadius)
    path.addLine(to: CGPoint(x: glyphRect.maxX, y: glyphRect.maxY - bottomRadius))
    path.addArc(tangent1End: CGPoint(x: glyphRect.maxX, y: glyphRect.maxY),
                tangent2End: CGPoint(x: glyphRect.maxX - bottomRadius, y: glyphRect.maxY), radius: bottomRadius)
    path.addLine(to: CGPoint(x: glyphRect.minX + bottomRadius, y: glyphRect.maxY))
    path.addArc(tangent1End: CGPoint(x: glyphRect.minX, y: glyphRect.maxY),
                tangent2End: CGPoint(x: glyphRect.minX, y: glyphRect.maxY - bottomRadius), radius: bottomRadius)
    path.addLine(to: CGPoint(x: glyphRect.minX, y: glyphRect.minY + topRadius))
    path.addArc(tangent1End: CGPoint(x: glyphRect.minX, y: glyphRect.minY),
                tangent2End: CGPoint(x: glyphRect.minX + topRadius, y: glyphRect.minY), radius: topRadius)
    path.closeSubpath()
    ctx.setFillColor(palette.glyph)
    ctx.addPath(path)
    ctx.fillPath()

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "render-app-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "render-app-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
    }
}

// MARK: Main

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/render-app-icon.swift <AppIcon.appiconset dir>\n".utf8))
    exit(64)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let outputs: [(String, Palette)] = [("AppIcon.png", light), ("AppIcon-Dark.png", dark), ("AppIcon-Tinted.png", tinted)]
for (name, palette) in outputs {
    guard let image = render(palette) else {
        FileHandle.standardError.write(Data("render failed for \(name)\n".utf8))
        exit(1)
    }
    try writePNG(image, to: outputDirectory.appendingPathComponent(name))
    print("wrote \(name)")
}
