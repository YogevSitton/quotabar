import AppKit
import SwiftUI

@MainActor enum ProviderArtwork {
    private static let codex = load(resource: "Codex", applications: ["ChatGPT", "Codex"], identifiers: ["com.openai.chat", "com.openai.codex"])
    private static let claude = load(resource: "Claude", applications: ["Claude"], identifiers: ["com.anthropic.claudefordesktop"])

    static func image(for name: String) -> NSImage {
        (name == "Claude" ? claude : codex).copy() as! NSImage
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
