import Foundation

// MARK: - GitHub API Models

struct GitHubRelease: Codable {
    let id: Int
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let publishedAt: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }

    /// Extract version string from tag name (removes 'v' prefix if present)
    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

struct GitHubAsset: Codable {
    let id: Int
    let name: String
    let contentType: String
    let size: Int
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case contentType = "content_type"
        case size
        case browserDownloadUrl = "browser_download_url"
    }

    /// Check if this asset is a firmware binary
    var isFirmwareBinary: Bool {
        name.hasSuffix(".bin")
    }
}

// MARK: - GitHub Release Service

class GitHubReleaseService {
    // Repository configuration
    private let owner: String
    private let repo: String
    private let urlSession: URLSession

    init(owner: String = "daltonch", repo: String = "GasTag") {
        self.owner = owner
        self.repo = repo

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300  // 5 minutes for downloads
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Fetch the latest release from GitHub
    /// - Returns: The latest release, or nil if none found
    func fetchLatestRelease() async throws -> GitHubRelease? {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GasTag-iOS", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            return try decoder.decode(GitHubRelease.self, from: data)
        case 404:
            // No releases found
            return nil
        case 403:
            throw GitHubError.rateLimited
        default:
            throw GitHubError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    /// Download a firmware asset to a temporary file
    /// - Parameters:
    ///   - asset: The asset to download
    ///   - progressHandler: Called with progress (0.0 to 1.0)
    /// - Returns: URL to the downloaded file in temp directory
    func downloadAsset(_ asset: GitHubAsset, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        guard let url = URL(string: asset.browserDownloadUrl) else {
            throw GitHubError.invalidUrl
        }

        var request = URLRequest(url: url)
        request.setValue("GasTag-iOS", forHTTPHeaderField: "User-Agent")

        // Use delegate-based download for progress tracking
        let delegate = DownloadProgressDelegate(totalSize: asset.size, progressHandler: progressHandler)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        let (tempUrl, response) = try await session.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GitHubError.downloadFailed
        }

        // Move to a known location in temp directory
        let destinationUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("firmware_\(asset.name)")

        // Remove existing file if present
        try? FileManager.default.removeItem(at: destinationUrl)

        try FileManager.default.moveItem(at: tempUrl, to: destinationUrl)

        return destinationUrl
    }

    /// Compare two semantic version strings
    /// - Returns: true if version1 < version2 (meaning an update is available)
    static func isUpdateAvailable(currentVersion: String, latestVersion: String) -> Bool {
        let v1 = parseVersion(currentVersion)
        let v2 = parseVersion(latestVersion)

        for i in 0..<max(v1.count, v2.count) {
            let part1 = i < v1.count ? v1[i] : 0
            let part2 = i < v2.count ? v2[i] : 0

            if part1 < part2 {
                return true
            } else if part1 > part2 {
                return false
            }
        }

        return false  // Versions are equal
    }

    // MARK: - Private Helpers

    private static func parseVersion(_ version: String) -> [Int] {
        // Remove 'v' prefix if present
        let cleaned = version.hasPrefix("v") ? String(version.dropFirst()) : version

        return cleaned.split(separator: ".").compactMap { Int($0) }
    }
}

// MARK: - Download Progress Delegate

private class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let totalSize: Int
    let progressHandler: (Double) -> Void

    init(totalSize: Int, progressHandler: @escaping (Double) -> Void) {
        self.totalSize = totalSize
        self.progressHandler = progressHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalSize)
        DispatchQueue.main.async {
            self.progressHandler(min(progress, 1.0))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Required delegate method - actual file handling done in downloadAsset
    }
}

// MARK: - Errors

enum GitHubError: LocalizedError {
    case invalidResponse
    case invalidUrl
    case rateLimited
    case httpError(statusCode: Int)
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from GitHub"
        case .invalidUrl:
            return "Invalid download URL"
        case .rateLimited:
            return "GitHub API rate limit exceeded. Please try again later."
        case .httpError(let statusCode):
            return "GitHub API error (HTTP \(statusCode))"
        case .downloadFailed:
            return "Failed to download firmware file"
        }
    }
}
