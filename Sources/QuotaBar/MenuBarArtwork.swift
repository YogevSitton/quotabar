import AppKit
import QuotaCore

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
        // Two short rows preserve percentages AND automatic reset times without
        // the width of a single-line label disappearing behind a camera notch.
        let quotaFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let resetFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        func width(_ text: String, font: NSFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let layouts = entries.map { entry in
            [("5h: \(entry.session.percentage)", "↻ \(entry.session.resetTime)"),
             ("Weekly: \(entry.weekly.percentage)", "↻ \(entry.weekly.resetTime)")].map { top, bottom in
                (top: top, bottom: bottom, width: max(width(top, font: quotaFont), width(bottom, font: resetFont)))
            }
        }
        let widths = layouts.map { 23 + $0.reduce(CGFloat.zero) { $0 + $1.width } + 9 }
        let size = NSSize(width: widths.reduce(0, +) + CGFloat(max(0, entries.count - 1)) * 12, height: 24)
        return NSImage(size: size, flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                var x: CGFloat = 0
                for (index, entry) in entries.enumerated() {
                    if index > 0 {
                        NSColor.separatorColor.setFill()
                        NSRect(x: x + 5, y: 4, width: 1, height: 16).fill()
                        x += 12
                    }
                    ProviderArtwork.menuImage(for: entry.name, appearance: appearance)
                        .draw(in: NSRect(x: x, y: 3, width: 18, height: 18))
                    x += 23
                    for (column, layout) in layouts[index].enumerated() {
                        if column > 0 { x += 9 }
                        (layout.top as NSString).draw(at: NSPoint(x: x, y: 12),
                            withAttributes: [.font: quotaFont, .foregroundColor: NSColor.labelColor])
                        (layout.bottom as NSString).draw(at: NSPoint(x: x, y: 1),
                            withAttributes: [.font: resetFont, .foregroundColor: NSColor.labelColor])
                        x += layout.width
                    }
                }
            }
            return true
        }
    }
}
