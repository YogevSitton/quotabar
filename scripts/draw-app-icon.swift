#!/usr/bin/env swift
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

// These committed vendor marks use only absolute M/L/H/V/C/Z SVG commands.
// Reject other syntax instead of silently producing incomplete brand artwork.
func vendorPath(_ source: String) -> NSBezierPath {
    let regex = try! NSRegularExpression(pattern: "[A-Za-z]|[-+]?(?:[0-9]*\\.)?[0-9]+(?:[eE][-+]?[0-9]+)?")
    let tokens = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
        String(source[Range($0.range, in: source)!])
    }
    var index = 0
    func number() -> CGFloat {
        guard index < tokens.count, let value = Double(tokens[index]), value.isFinite else {
            fatalError("Malformed vendor SVG coordinates")
        }
        index += 1; return CGFloat(value)
    }
    func point() -> NSPoint { NSPoint(x: number(), y: number()) }
    let path = NSBezierPath()
    var command = ""
    while index < tokens.count {
        if tokens[index].first?.isLetter == true { command = tokens[index]; index += 1 }
        switch command {
        case "M": path.move(to: point()); command = "L"
        case "L": path.line(to: point())
        case "H": path.line(to: NSPoint(x: number(), y: path.currentPoint.y))
        case "V": path.line(to: NSPoint(x: path.currentPoint.x, y: number()))
        case "C":
            let control1 = point(), control2 = point(), end = point()
            path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
        case "Z": path.close(); command = ""
        default: fatalError("Unsupported vendor SVG command: \(command)")
        }
    }
    return path
}

final class VendorSVG: NSObject, XMLParserDelegate {
    var paths: [NSBezierPath] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "path", let value = attributes["d"] { paths.append(vendorPath(value)) }
    }
}

final class ProviderIconDrawing: NSView {
    let paths: [NSBezierPath]
    let claude: Bool
    let menuBar: Bool
    init(root: URL, claude: Bool, menuBar: Bool = false) throws {
        self.claude = claude
        self.menuBar = menuBar
        let source = root.appendingPathComponent("Assets/\(claude ? "Claude" : "ChatGPT")-mark.svg")
        let reader = VendorSVG(), parser = XMLParser(data: try Data(contentsOf: source))
        parser.delegate = reader
        guard parser.parse(), !reader.paths.isEmpty else { fatalError("Cannot read vendor SVG") }
        self.paths = reader.paths
        super.init(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if menuBar {
            // A bare vector mark, with transparent negative space and no tile.
            NSColor.black.setFill()
            var position = AffineTransform(translationByX: 64, byY: 64)
            position.scale(896 / (claude ? 125 : 20))
            for original in paths {
                let path = original.copy() as! NSBezierPath
                path.transform(using: position); path.fill()
            }
            return
        }
        color(claude ? 0xCB5938 : 0xCDD4DE).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 72, width: 896, height: 888), xRadius: 200, yRadius: 200).fill()
        color(claude ? 0xEF6B45 : 0xFFFFFF).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 58, width: 896, height: 888), xRadius: 200, yRadius: 200).fill()
        color(claude ? 0xFFFFFF : 0x20242F).setFill()
        let transform = AffineTransform(translationByX: claude ? 226 : 140, byY: claude ? 220 : 134)
        var position = transform
        position.scale(claude ? 572 / 125 : 744 / 20)
        for original in paths {
            let path = original.copy() as! NSBezierPath
            path.transform(using: position); path.fill()
        }
    }
}

// Original vector artwork. Coordinates use a top-left origin on a 1024pt canvas.
// Keep the two meters and fuel gauge recognizable without tiny text or provider marks.
final class QuotaIconDrawing: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                     _ radius: CGFloat, _ fill: UInt32) {
            color(fill).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                         xRadius: radius, yRadius: radius).fill()
        }
        func line(_ points: [NSPoint], width: CGFloat, fill: UInt32) {
            guard let first = points.first else { return }
            let path = NSBezierPath(); path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
            path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
            color(fill).setStroke(); path.stroke()
        }
        // A quiet macOS tile, then an inset usage dashboard.
        rounded(64, 64, 896, 896, 200, 0xE1E6EC)
        rounded(64, 58, 896, 888, 200, 0xF8FAFC)
        rounded(176, 278, 672, 530, 92, 0xCDD4DE)
        rounded(176, 264, 672, 530, 92, 0x202B3B)
        // The header suggests a small menu-bar popup rather than a chart of growth.
        rounded(224, 316, 140, 24, 12, 0x91A0B4)
        rounded(388, 316, 48, 24, 12, 0x506078)
        // Two independent remaining-quota meters: five-hour and weekly windows.
        rounded(240, 470, 544, 86, 43, 0x425168)
        rounded(240, 470, 402, 86, 43, 0x4DE0B0)
        rounded(240, 632, 544, 86, 43, 0x425168)
        rounded(240, 632, 248, 86, 43, 0xFFBE66)
        // A fuel-style gauge makes remaining capacity visible at small sizes.
        color(0xCFD6E0).setFill()
        NSBezierPath(ovalIn: NSRect(x: 550, y: 176, width: 304, height: 304)).fill()
        color(0xFFFFFF).setFill()
        NSBezierPath(ovalIn: NSRect(x: 550, y: 162, width: 304, height: 304)).fill()
        func dialPoint(_ degrees: CGFloat, radius: CGFloat) -> NSPoint {
            let angle = degrees * .pi / 180
            return NSPoint(x: 702 + cos(angle) * radius, y: 324 + sin(angle) * radius)
        }
        let arc = stride(from: CGFloat(150), through: CGFloat(390), by: 3).map { dialPoint($0, radius: 101) }
        line(arc, width: 16, fill: 0x202B3B)
        for degrees in stride(from: CGFloat(150), through: CGFloat(390), by: 40) {
            line([dialPoint(degrees, radius: 74), dialPoint(degrees, radius: 86)],
                 width: 10, fill: 0x202B3B)
        }
        // One needle, pivot and an open lower dial distinguish this from a clock.
        line([NSPoint(x: 687, y: 342), dialPoint(310, radius: 72)], width: 20, fill: 0x202B3B)
        color(0x202B3B).setFill()
        NSBezierPath(ovalIn: NSRect(x: 688, y: 310, width: 28, height: 28)).fill()
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: draw-app-icon.swift PROJECT_ROOT\n", stderr); exit(1)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func save(_ view: NSView, name: String) throws {
    let pdf = view.dataWithPDF(inside: view.bounds)
    try pdf.write(to: root.appendingPathComponent("Assets/\(name).pdf"), options: .atomic)
    guard let image = NSImage(data: pdf),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fputs("Cannot render the vector app icon.\n", stderr); exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: root.appendingPathComponent("Assets/\(name).png"), options: .atomic)
    try pdf.write(to: root.appendingPathComponent("Sources/QuotaBar/Resources/\(name).pdf"), options: .atomic)
}
try save(QuotaIconDrawing(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024)), name: "QuotaBar")
try save(ProviderIconDrawing(root: root, claude: false), name: "Codex")
try save(ProviderIconDrawing(root: root, claude: true), name: "Claude")
try save(ProviderIconDrawing(root: root, claude: false, menuBar: true), name: "CodexMenu")
try save(ProviderIconDrawing(root: root, claude: true, menuBar: true), name: "ClaudeMenu")
