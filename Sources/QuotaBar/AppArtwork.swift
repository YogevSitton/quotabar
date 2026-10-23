import AppKit
import SwiftUI

@MainActor enum AppArtwork {
    static let icon: NSImage = {
        // PDF keeps the original paths sharp at every in-app display size.
        if let url = Bundle.main.url(forResource: "QuotaBar", withExtension: "pdf") ?? Bundle.module.url(forResource: "QuotaBar", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) { return image }
        if let url = Bundle.main.url(forResource: "QuotaBar", withExtension: "icns") ?? Bundle.module.url(forResource: "QuotaBar", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "QuotaBar")!
    }()
}

struct QuotaBarIcon: View {
    var size: CGFloat = 32
    var body: some View {
        Image(nsImage: AppArtwork.icon).resizable().interpolation(.high)
            .frame(width: size, height: size).accessibilityLabel("QuotaBar")
    }
}
