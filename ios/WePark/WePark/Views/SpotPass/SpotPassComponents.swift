//
//  SpotPassComponents.swift
//  Views/SpotPass
//
//  Spot Pass C1: the small reusable pieces (design §11 names: `SpotPassQRView`, `KarmaChip`,
//  `AliasGlyphDisc`). No state, no flow logic.
//

import SwiftUI

// MARK: - QR plate

/// The branded QR on its opaque white plate. The plate is a bitmap at integer pixel boundaries,
/// shown with `.interpolation(.none)`: no blur, no material, no scale animation, nothing over it
/// (design §1.5). The 4-module quiet zone is inside the bitmap.
struct SpotPassQRView: View {
    let token: String

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // Screens are 2x or 3x; round so modules stay whole pixels.
        let scale = max(1, displayScale.rounded())
        if let image = SpotPassQRImageCache.image(token: token, scale: scale) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: image.size.width, height: image.size.height)
                .clipShape(RoundedRectangle(cornerRadius: SpotPassTheme.plateCornerRadius, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Spot Pass QR code. Show it to a neighbor who is leaving so they can scan it with their camera.")
                .accessibilityAddTraits(.isImage)
        } else {
            // The token failed validation or the URL exceeded the byte budget: never draw a code
            // that might not decode.
            RoundedRectangle(cornerRadius: SpotPassTheme.plateCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 328, height: 328)
                .overlay {
                    Text("This pass can't be shown. Make a new one.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(24)
                }
        }
    }
}
