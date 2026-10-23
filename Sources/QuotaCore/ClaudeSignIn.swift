import Foundation

public struct ClaudeHelperRelease {
    public let version: String
    public let checksum: String
    public let size: Int
    public let downloadURL: URL
    public static func parse(version: String, platform: String, manifest: Data) throws -> ClaudeHelperRelease {
        guard version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[A-Za-z0-9.-]+)?$", options: .regularExpression) != nil,
              ["darwin-arm64", "darwin-x64"].contains(platform), manifest.count < 1_000_000,
              let root = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let platforms = root["platforms"] as? [String: [String: Any]], let row = platforms[platform],
              row["binary"] as? String == "claude", let checksum = row["checksum"] as? String,
              checksum.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let rawSize = row["size"] as? NSNumber, CFGetTypeID(rawSize) != CFBooleanGetTypeID(),
              rawSize.doubleValue >= 1_000_000, rawSize.doubleValue <= 1_000_000_000,
              rawSize.doubleValue.rounded(.down) == rawSize.doubleValue else {
            throw UsageError.message("Claude Code's download information could not be verified. Try again later.")
        }
        return ClaudeHelperRelease(version: version, checksum: checksum, size: rawSize.intValue,
            downloadURL: URL(string: "https://downloads.claude.ai/claude-code-releases/\(version)/\(platform)/claude")!)
    }
}

public enum ClaudeSignInLink {
    // Only the official authorization page may be opened from helper output.
    // The output itself is never logged or displayed.
    public static func first(in text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "https://[^\\s\\u001B]+") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let range = Range(match.range, in: text) else { continue }
            let raw = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>)]},"))
            guard let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
                ["claude.ai", "console.anthropic.com", "console.claude.ai", "platform.claude.com"].contains(url.host ?? ""),
                ["/oauth/authorize", "/oauth2/authorize"].contains(url.path) else { continue }
            return url
        }
        return nil
    }
}

import CoreFoundation
