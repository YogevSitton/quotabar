import AppKit
import SwiftUI

@MainActor enum ProviderArtwork {
    private static let codex = load(resource: "Codex", applications: ["ChatGPT", "Codex"], identifiers: ["com.openai.chat", "com.openai.codex"])
    private static let claude = load(resource: "Claude", applications: ["Claude"], identifiers: ["com.anthropic.claudefordesktop"])
    private static let codexMenu = loadMenu(resource: "CodexMenu", symbol: "terminal")
    private static let claudeMenu = loadMenu(resource: "ClaudeMenu", symbol: "asterisk")

    static func image(for name: String) -> NSImage {
        (name == "Claude" ? claude : codex).copy() as! NSImage
    }
    static func menuImage(for name: String, appearance: NSAppearance) -> NSImage {
        let mark = name == "Claude" ? claudeMenu : codexMenu
        // Text attachments do not reliably apply NSImage template tinting.
        // Resolve the menu button's appearance explicitly, retaining the alpha mask.
        return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { bounds in
            appearance.performAsCurrentDrawingAppearance {
                mark.draw(in: bounds)
                NSColor.labelColor.setFill()
                bounds.fill(using: .sourceIn)
            }
            return true
        }
    }
    private static func loadMenu(resource: String, symbol: String) -> NSImage {
        if let url = Bundle.main.url(forResource: resource, withExtension: "pdf") ?? Bundle.module.url(forResource: resource, withExtension: "pdf"),
           let image = NSImage(contentsOf: url) { return image }
        // Never fall back to an installed app icon: it would reintroduce a tile.
        return NSImage(systemSymbolName: symbol, accessibilityDescription: resource)!
    }
    private static func load(resource: String, applications: [String], identifiers: [String]) -> NSImage {
        // Render committed vector mark paths ourselves; never crop screenshots.
        if let url = Bundle.main.url(forResource: resource, withExtension: "pdf") ?? Bundle.module.url(forResource: resource, withExtension: "pdf"),
           let image = NSImage(contentsOf: url) { image.isTemplate = false; return image }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = applications.flatMap { name in
            [URL(fileURLWithPath: "/Applications/\(name).app"), home.appendingPathComponent("Applications/\(name).app")]
        } + identifiers.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        if let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            let image = NSWorkspace.shared.icon(forFile: app.path)
            image.isTemplate = false
            return image
        }
        if let url = Bundle.main.url(forResource: resource, withExtension: "icns") ?? Bundle.module.url(forResource: resource, withExtension: "icns"),
           let image = NSImage(contentsOf: url) { image.isTemplate = false; return image }
        return NSImage(systemSymbolName: resource == "Claude" ? "asterisk" : "terminal", accessibilityDescription: resource)!
    }
}

struct ProviderIcon: View {
    let name: String
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: ProviderArtwork.image(for: name)).resizable().interpolation(.high)
            .frame(width: size, height: size).accessibilityLabel(name)
    }
}
