import AppKit

struct MenuBarQuota {
    let remaining: Int?
    let resetsAt: Date?
    var percentage: String { remaining.map { "\($0)%" } ?? "—" }
    var resetTime: String { resetsAt.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) } ?? "—" }
}

struct MenuBarEntry {
    let name: String
    let session: MenuBarQuota
    let weekly: MenuBarQuota
    var description: String {
        "\(name): 5h: \(session.percentage), automatic reset \(session.resetTime); Weekly: \(weekly.percentage), automatic reset \(weekly.resetTime)"
    }
}

@MainActor enum MenuBarArtwork {
    static func image(entries: [MenuBarEntry], appearance: NSAppearance) -> NSImage {
        // Keep the bar to one logo and 5h%/weekly% per connected provider.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let labels = entries.map { "\($0.session.percentage)/\($0.weekly.percentage)" }
        // Reserve the widest percentage pair so 9% → 10% or an unavailable
        // reading never changes the status item's width beneath an open popup.
        let slotWidth = ceil(("100%/100%" as NSString).size(withAttributes: [.font: font]).width)
        let widths: [CGFloat] = entries.map { _ in slotWidth }
        let textWidth = widths.reduce(CGFloat.zero, +)
        let iconWidth = CGFloat(entries.count) * 23
        let gapWidth = CGFloat(max(0, entries.count - 1)) * 12
        let size = NSSize(width: textWidth + iconWidth + gapWidth, height: 22)
        return NSImage(size: size, flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                var x: CGFloat = 0
                for (index, entry) in entries.enumerated() {
                    if index > 0 { x += 12 }
                    ProviderArtwork.menuImage(for: entry.name, appearance: appearance)
                        .draw(in: NSRect(x: x, y: 2, width: 18, height: 18))
                    x += 23
                    let label = labels[index] as NSString
                    let height = label.size(withAttributes: [.font: font]).height
                    let labelWidth = label.size(withAttributes: [.font: font]).width
                    label.draw(at: NSPoint(x: x + (widths[index] - labelWidth) / 2, y: (22 - height) / 2),
                               withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
                    x += widths[index]
                }
            }
            return true
        }
    }
}
