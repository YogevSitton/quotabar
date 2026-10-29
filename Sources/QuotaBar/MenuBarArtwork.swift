import AppKit
import QuotaCore

struct MenuBarResetChip: Equatable {
    let text: String
    let spoken: String
    let redFraction: Double
}

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

    func tooltipLine(_ label: String, at now: Date) -> String {
        if limit == .noLimit { return "\(label): No limit" }
        guard remaining != nil || resetsAt != nil else { return "\(label): Unavailable" }
        let value = remaining.map { "\($0)% left" } ?? "Unavailable"
        // Rounded up like the menu bar and popup countdowns for the same reset.
        let reset = resetsAt.map {
            $0 > now ? "resets in \(countdown($0, now: now, style: .totalHours))" : "reset due"
        } ?? "reset not reported"
        return "\(label): \(value) · \(reset)"
    }
}

struct MenuBarEntry {
    let provider: Provider
    var name: String { provider.rawValue }
    let session: MenuBarQuota
    let weekly: MenuBarQuota
    var nextResetExpiry: Date? = nil
    var quotaGroup: String? = nil
    func description(at now: Date) -> String {
        ([name] + [quotaGroup].compactMap { $0 } + [session.tooltipLine("5-hour window", at: now),
                                                     weekly.tooltipLine("Weekly window", at: now)]).joined(separator: "; ")
    }
    /// 5h%/weekly%, with a countdown for an exhausted 5h window. An exhausted
    /// weekly window blocks both, so it shows only the weekly countdown.
    /// Each segment carries the percentage that tints it; nil stays uncolored.
    func menuSegments(at now: Date) -> [(text: String, remaining: Int?)] {
        if weekly.isExhausted, weekly.resetsAt.map({ $0 > now }) == true { return [(weekly.menuValue(at: now), nil)] }
        return [(session.menuValue(at: now), session.remaining), ("/", nil), (weekly.menuValue(at: now), weekly.remaining)]
    }
    func menuLabel(at now: Date) -> String {
        menuSegments(at: now).map(\.text).joined() + (resetChip(at: now).map { " " + $0.text } ?? "")
    }
    /// Time left on the soonest reset expiring within 3 days, rounded down so
    /// it never overstates the time left: "2d", then "18h" and "45m".
    func resetChip(at now: Date) -> MenuBarResetChip? {
        guard let nextResetExpiry else { return nil }
        let timeLeft = nextResetExpiry.timeIntervalSince(now)
        let urgency = ResetExpiryUrgency(timeLeft: timeLeft)
        guard urgency != .normal else { return nil }
        let minutes = max(1, Int(timeLeft / 60))
        let redFraction = ResetExpiryUrgency.redBlendFraction(timeLeft: timeLeft)
        // Keep the day-to-hour boundary at 24 hours as the tint starts blending.
        if timeLeft > 86400 { return MenuBarResetChip(text: "\(minutes / 1440)d", spoken: plural(minutes / 1440, "day"), redFraction: redFraction) }
        if minutes >= 60 { return MenuBarResetChip(text: "\(minutes / 60)h", spoken: plural(minutes / 60, "hour"), redFraction: redFraction) }
        return MenuBarResetChip(text: "\(minutes)m", spoken: plural(minutes, "minute"), redFraction: redFraction)
    }
    private func plural(_ count: Int, _ unit: String) -> String { "\(count) \(unit)\(count == 1 ? "" : "s")" }
    func tooltipSection(at now: Date) -> String {
        let expiry = nextResetExpiry.map {
            // Rounded down like the chip, so it never overstates the time left.
            $0 > now ? "Next reset expires in \(countdown($0, now: now, style: .totalHours, roundingDown: true))" : "Next reset expired"
        }
        return ([name] + [quotaGroup].compactMap { $0 } + [session.tooltipLine("5h", at: now), weekly.tooltipLine("Weekly", at: now)]
                + [expiry].compactMap { $0 }).joined(separator: "\n")
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
    private static let chipFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
    private static let chipGap: CGFloat = 3
    private static let chipPadding: CGFloat = 3.5
    static func image(entries: [MenuBarEntry], segments: [[(text: String, remaining: Int?)]], chips: [MenuBarResetChip?],
                      appearance: NSAppearance) -> NSImage {
        // Keep the bar to one logo and 5h%/weekly% per connected provider.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        // Fit the content with no reserved space. Digits are monospaced, so
        // ordinary percentage changes keep the width; a different digit count,
        // countdown, no-limit marker, unavailable reading or chip changes it.
        let labelWidths = segments.map {
            ceil(($0.map(\.text).joined() as NSString).size(withAttributes: [.font: font]).width)
        }
        let widths: [CGFloat] = zip(labelWidths, chips).map { label, chip in
            label + (chip.map { chipGap + chipWidth($0) } ?? 0)
        }
        let textWidth = widths.reduce(CGFloat.zero, +)
        let iconSize: CGFloat = 18
        let iconTextGap: CGFloat = 2
        // Providers are as far apart as neighboring menu bar items: 18pt
        // plus the logo's 1pt inset matches their visible 19-20pt gap.
        let providerGap: CGFloat = 18
        let iconWidth = CGFloat(entries.count) * (iconSize + iconTextGap)
        let gapWidth = CGFloat(max(0, entries.count - 1)) * providerGap
        let size = NSSize(width: textWidth + iconWidth + gapWidth, height: 22)
        return NSImage(size: size, flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                var x: CGFloat = 0
                for (index, entry) in entries.enumerated() {
                    if index > 0 { x += providerGap }
                    ProviderArtwork.menuImage(for: entry.provider, appearance: appearance)
                        .draw(in: NSRect(x: x, y: 2, width: iconSize, height: iconSize))
                    x += iconSize + iconTextGap
                    let label = NSMutableAttributedString()
                    for segment in segments[index] {
                        label.append(NSAttributedString(string: segment.text, attributes: [
                            .font: font, .foregroundColor: color(remaining: segment.remaining)]))
                    }
                    label.draw(at: NSPoint(x: x, y: (22 - label.size().height) / 2))
                    if let chip = chips[index] { drawChip(chip, at: x + labelWidths[index] + chipGap) }
                    x += widths[index]
                }
            }
            return true
        }
    }
    // Fixed sRGB endpoints keep the fill consistent in both appearances.
    // Black or white text keeps at least 4.58:1 contrast throughout the blend.
    private static func chipColors(redFraction: Double) -> (fill: NSColor, text: NSColor) {
        let fraction = CGFloat(redFraction)
        let fill = NSColor(srgbRed: 1 + (0.843 - 1) * fraction,
                           green: 0.624 * (1 - fraction),
                           blue: 0.039 + (0.082 - 0.039) * fraction, alpha: 1)
        let luminance = relativeLuminance(fill)
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return (fill, whiteContrast > blackContrast ? .white : .black)
    }
    private static func relativeLuminance(_ color: NSColor) -> Double {
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }
    private static func chipWidth(_ chip: MenuBarResetChip) -> CGFloat {
        ceil((chip.text as NSString).size(withAttributes: [.font: chipFont]).width + 2 * chipPadding)
    }
    private static func drawChip(_ chip: MenuBarResetChip, at x: CGFloat) {
        let colors = chipColors(redFraction: chip.redFraction)
        let text = NSAttributedString(string: chip.text, attributes: [.font: chipFont, .foregroundColor: colors.text])
        let textSize = text.size()
        let height = ceil(textSize.height + 3)
        let rect = NSRect(x: x, y: ((22 - height) / 2).rounded(), width: chipWidth(chip), height: height)
        colors.fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: rect.minX + chipPadding, y: rect.minY + (height - textSize.height) / 2))
    }
}
