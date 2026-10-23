import AppKit

struct MenuBarQuota {
    let remaining: Int?
    let resetsAt: Date?
    var percentage: String { remaining.map { "\($0)%" } ?? "—" }
    var resetTime: String { resetsAt.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) } ?? "—" }

    func tooltipLine(_ label: String) -> String {
        guard remaining != nil || resetsAt != nil else { return "\(label): Unavailable" }
        let value = remaining.map { "\($0)% left" } ?? "Unavailable"
        let reset = resetsAt.map {
            $0.formatted(.dateTime.weekday(.abbreviated).hour().minute().timeZone(.specificName(.short)))
        } ?? "not reported"
        return "\(label): \(value) · resets \(reset)"
    }
}

struct MenuBarEntry {
    let name: String
    let session: MenuBarQuota
    let weekly: MenuBarQuota
    var description: String {
        "\(name): 5h: \(session.percentage), automatic reset \(session.resetTime); Weekly: \(weekly.percentage), automatic reset \(weekly.resetTime)"
    }
    var tooltipSection: String {
        [name, session.tooltipLine("5h"), weekly.tooltipLine("Weekly")].joined(separator: "\n")
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
        let iconSize: CGFloat = 18
        let iconTextGap: CGFloat = 2
        let providerGap: CGFloat = 8
        let iconWidth = CGFloat(entries.count) * (iconSize + iconTextGap)
        let gapWidth = CGFloat(max(0, entries.count - 1)) * providerGap
        let size = NSSize(width: textWidth + iconWidth + gapWidth, height: 22)
        return NSImage(size: size, flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                var x: CGFloat = 0
                for (index, entry) in entries.enumerated() {
                    if index > 0 { x += providerGap }
                    ProviderArtwork.menuImage(for: entry.name, appearance: appearance)
                        .draw(in: NSRect(x: x, y: 2, width: iconSize, height: iconSize))
                    x += iconSize + iconTextGap
                    let label = labels[index] as NSString
                    let height = label.size(withAttributes: [.font: font]).height
                    label.draw(at: NSPoint(x: x, y: (22 - height) / 2),
                               withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
                    x += widths[index]
                }
            }
            return true
        }
    }
}
