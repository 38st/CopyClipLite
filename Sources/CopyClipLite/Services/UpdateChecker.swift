import AppKit
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, url: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func check() {
        guard state != .checking else { return }
        state = .checking
        Task {
            do {
                var request = URLRequest(
                    url: URL(string: "https://api.github.com/repos/38st/CopyClipLite/releases/latest")!
                )
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("CopyClipLite/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    throw UpdateError.invalidResponse
                }
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if Self.compareVersions(latestVersion, currentVersion) == .orderedDescending {
                    state = .updateAvailable(version: latestVersion, url: release.htmlURL)
                } else {
                    state = .upToDate
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func openAvailableUpdate() {
        guard case let .updateAvailable(_, url) = state else { return }
        NSWorkspace.shared.open(url)
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private enum UpdateError: LocalizedError {
        case invalidResponse

        var errorDescription: String? {
            "GitHub did not return a valid release. Try again later."
        }
    }
}
