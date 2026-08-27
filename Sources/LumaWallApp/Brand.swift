import AppKit
import SwiftUI

enum Brand {
    static var iconImage: NSImage {
        for bundle in resourceBundles {
            if let url = bundle.url(forResource: "AppIcon", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }
        return NSImage(size: NSSize(width: 128, height: 128))
    }

    private static var resourceBundles: [Bundle] {
        #if SWIFT_PACKAGE
        [Bundle.module, Bundle.main]
        #else
        [Bundle.main]
        #endif
    }
}

struct BrandMark: View {
    var size: CGFloat = 34
    var glowing = true

    var body: some View {
        Image(nsImage: Brand.iconImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.223, style: .continuous))
            .shadow(color: glowing ? Theme.accent.opacity(0.32) : .clear, radius: glowing ? 10 : 0, y: 2)
            .accessibilityHidden(true)
    }
}

enum Theme {
    static let bgTop = Color(red: 0.035, green: 0.05, blue: 0.062)
    static let bgBottom = Color(red: 0.015, green: 0.028, blue: 0.038)
    static let sidebar = Color(red: 0.025, green: 0.036, blue: 0.046)
    static let panel = Color.white.opacity(0.04)
    static let panelStrong = Color.white.opacity(0.07)
    static let line = Color.white.opacity(0.08)
    static let accent = Color(red: 0.20, green: 0.82, blue: 0.76)
    static let warm = Color(red: 0.96, green: 0.80, blue: 0.52)
    static let textDim = Color.white.opacity(0.55)
}
