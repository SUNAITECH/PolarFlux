import SwiftUI
import Foundation

struct GitHubRelease: Decodable, Identifiable {
    var id: String { tagName }
    let tagName: String
    let htmlUrl: String
    let body: String
    let publishedAt: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case body
        case publishedAt = "published_at"
    }

    /// Release metadata comes from a remote API and must never be trusted
    /// blindly. Only https links to github.com are surfaced to the user.
    var safeURL: URL? {
        guard let url = URL(string: htmlUrl),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }
        return url
    }
}

@MainActor
class UpdateChecker: ObservableObject {
    @Published var isChecking = false
    @Published var updateAvailable: GitHubRelease? = nil
    @Published var error: String? = nil
    @Published var showUpToDateAlert = false

    private let repoOwner = "SUNAITECH"
    private let repoName = "PolarFlux"

    /// Ephemeral, no-cache session: update checks must always hit the network
    /// and never persist release metadata to disk.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
    
    // Normalize version string (remove 'v' prefix, handle CalVer)
    private func normalizeVersion(_ version: String) -> String {
        return version.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
    }
    
    private func isNewer(current: String, remote: String) -> Bool {
        let currentParts = normalizeVersion(current).split(separator: ".").compactMap { Int($0) }
        let remoteParts = normalizeVersion(remote).split(separator: ".").compactMap { Int($0) }
        
        for i in 0..<max(currentParts.count, remoteParts.count) {
            let c = i < currentParts.count ? currentParts[i] : 0
            let r = i < remoteParts.count ? remoteParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }
    
    func checkForUpdates(userInitiated: Bool = false) {
        guard !isChecking else { return }
        
        isChecking = true
        error = nil
        
        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else {
            self.error = "Invalid URL"
            self.isChecking = false
            return
        }
        
        Task {
            do {
                let (data, response) = try await session.data(from: url)
                
                guard let httpResponse = response as? HTTPURLResponse, 
                      (200...299).contains(httpResponse.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                
                if isNewer(current: currentVersion, remote: release.tagName) {
                    self.updateAvailable = release
                } else if userInitiated {
                    self.showUpToDateAlert = true
                }
            } catch {
                if userInitiated {
                    self.error = error.localizedDescription
                }
                print("Update check failed: \(error)")
            }
            
            self.isChecking = false
        }
    }
}
