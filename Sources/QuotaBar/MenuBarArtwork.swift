import AppKit
import QuotaCore

struct MenuBarQuota {
    let limit: UsageLimit
    var remaining: Int? { limit.remaining }
    var resetsAt: Date? { limit.window?.resetsAt }
    init(limit: UsageLimit) { self.limit = limit }
    init(remaining: Int?, resetsAt: Date?) {
        limit = remaining.map { .limited(UsageWindow(used: Double(100 - $0), resetsAt: resetsAt)) } ?? .unavailable
    }
    var percentage: String {
        if limit == .noLimit { return "∞" }
        return remaining.map { "\($0)%" } ?? "-"
    }
    var isExhausted: Bool { remaining == 0 }
    /// An exhausted window shows time until its reset instead of 0%.
    func menuValue(at now: Date) -> String {
        guard isExhausted, let resetsAt, resetsAt > now else { return percentage }
        let minutes = max(1, Int(ceil(resetsAt.timeIntervalSince(now) / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)d\((minutes % 1440) / 60)h" }
        if minutes >= 600 { return "\(minutes / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h\(minutes % 60)m" }
        return "\(minutes)m"
    }
    var resetTime: String { resetsAt.map { $0.formatted(.dateTime.weekday(.abbreviated).hour().minute()) } ?? "-" }

    func tooltipLine(_ label: String) -> String {
        if limit == .noLimit { return "\(label): No limit" }
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
        [name, session.tooltipLine("5-hour window"), weekly.tooltipLine("Weekly window")].joined(separator: "; ")
    }
    /// 5h%/weekly%, with a countdown for an exhausted 5h window. An exhausted
    /// weekly window blocks both, so it shows only the weekly countdown.
    /// Each segment carries the percentage that tints it; nil stays uncolored.
    func menuSegments(at now: Date) -> [(text: String, remaining: Int?)] {
        if weekly.isExhausted, weekly.resetsAt.map({ $0 > now }) == true { return [(weekly.menuValue(at: now), nil)] }
        return [(session.menuValue(at: now), session.remaining), ("/", nil), (weekly.menuValue(at: now), weekly.remaining)]
    }
    func menuLabel(at now: Date) -> String { menuSegments(at: now).map(\.text).joined() }
    var tooltipSection: String {
        [name, session.tooltipLine("5h"), weekly.tooltipLine("Weekly")].joined(separator: "\n")
    }
}

@MainActor enum MenuBarArtwork {
    /// Plain label color with plenty left, blending steadily into red from 50%
    /// down to 10%. An exhausted window shows a countdown and stays uncolored.
    static func color(remaining: Int?) -> NSColor {
        guard let remaining, remaining > 0 else { return .labelColor }
        let fraction = max(0, min(1, (50 - CGFloat(remaining)) / 40))
        guard fraction > 0, let base = NSColor.labelColor.usingColorSpace(.sRGB) else { return .labelColor }
        return base.blended(withFraction: fraction, of: .systemRed) ?? .labelColor
    }
    static func image(entries: [MenuBarEntry], segments: [[(text: String, remaining: Int?)]], appearance: NSAppearance) -> NSImage {
        // Keep the bar to one logo and 5h%/weekly% per connected provider.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        // Reserve the widest percentage pair or countdown so 9% → 10%, a reset
        // countdown, no-limit marker or unavailable reading never changes its width.
        let slotWidth = ["100%/100%", "4h59m/99%", "6d23h", "∞/100%"].map {
            ceil(($0 as NSString).size(withAttributes: [.font: font]).width)
        }.max() ?? 0
        let widths: [CGFloat] = entries.map { _ in slotWidth }
        let textWidth = widths.reduce(CGFloat.zero, +)
        let iconSize: CGFloat = 18
        let iconTextGap: CGFloat = 2
        let providerGap: CGFloat = 4
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
                    let label = NSMutableAttributedString()
                    for segment in segments[index] {
                        label.append(NSAttributedString(string: segment.text, attributes: [
                            .font: font, .foregroundColor: color(remaining: segment.remaining)]))
                    }
                    label.draw(at: NSPoint(x: x, y: (22 - label.size().height) / 2))
                    x += widths[index]
                }
            }
            return true
        }
    }
}
