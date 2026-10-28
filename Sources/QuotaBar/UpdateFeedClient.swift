import Foundation
import QuotaCore
import QuotaUpdateSupport

/// Anonymous HTTPS reads of the public channel feeds and release downloads.
/// There is intentionally no token, cookie, credential, GitHub CLI or sign-in
/// path: a missing feed simply means nothing is published for that channel.
struct UpdateFeedClient: Sendable {
    static let allowedHosts: Set<String> = ["yogevsitton.github.io", "github.com",
                                            "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    enum FeedFetch: Equatable, Sendable {
        case bytes(Data)
        case absent
        case failed(UpdateFetchFailure)
    }

    struct DownloadFailure: Error { let failure: UpdateFetchFailure }

    func feed(_ channel: UpdateChannel) async -> FeedFetch {
        switch await get(channel.feedURL, maximumBytes: UpdateEnvelope.maximumBytes, output: nil) {
        case .success(let data): return .bytes(data)
        case .failure(let failure) where failure.failure == .unavailable: return .absent
        case .failure(let failure): return .failed(failure.failure)
        }
    }

    /// Streams the archive into a new private file, never past its signed size.
    func download(_ manifest: UpdateManifest, to file: URL) async throws {
        let output = try UpdateFiles.create(file)
        var complete = false
        defer { try? output.close(); if !complete { try? FileManager.default.removeItem(at: file) } }
        switch await get(manifest.archiveURL, maximumBytes: manifest.archiveBytes, output: output) {
        case .success: break
        case .failure(let failure): throw failure
        }
        try output.synchronize(); try output.close()
        try UpdateSignature.verifyArchive(file, manifest: manifest)
        complete = true
    }

    private func get(_ url: URL, maximumBytes: Int, output: FileHandle?) async -> Result<Data, DownloadFailure> {
        guard url.scheme == "https", let host = url.host, Self.allowedHosts.contains(host) else {
            return .failure(DownloadFailure(failure: .invalid))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.httpMethod = "GET"
        request.setValue(output == nil ? "application/json" : "application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("QuotaBar-Updater", forHTTPHeaderField: "User-Agent")
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { return .failure(DownloadFailure(failure: .invalid)) }
            let headers = Dictionary(response.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) },
                                     uniquingKeysWith: { first, _ in first })
            if let failure = UpdateFetchFailure.classify(status: response.statusCode, headers: headers, now: Date()) {
                return .failure(DownloadFailure(failure: failure))
            }
            guard response.expectedContentLength <= Int64(maximumBytes) else { return .failure(DownloadFailure(failure: .invalid)) }
            var count = 0; var data = Data(); var chunk = Data()
            for try await byte in stream {
                count += 1
                guard count <= maximumBytes else { return .failure(DownloadFailure(failure: .invalid)) }
                if let output {
                    chunk.append(byte)
                    if chunk.count >= 65_536 { try output.write(contentsOf: chunk); chunk.removeAll(keepingCapacity: true) }
                } else { data.append(byte) }
            }
            if let output, !chunk.isEmpty { try output.write(contentsOf: chunk) }
            return .success(data)
        } catch {
            return .failure(DownloadFailure(failure: .transient))
        }
    }
}

/// Follows only HTTPS redirects to the public GitHub hosts, before any body
/// bytes, and never forwards credentials or cookies.
private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", let host = url.host, UpdateFeedClient.allowedHosts.contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              task.countOfBytesReceived == 0 else { completionHandler(nil); return }
        var safe = request
        safe.setValue(nil, forHTTPHeaderField: "Authorization"); safe.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(safe)
    }
}
