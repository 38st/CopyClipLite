import Foundation

struct ClipboardIgnoredApplicationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String = "ignoredApplications") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [ClipboardSourceApplication] {
        guard let data = defaults.data(forKey: key),
            let applications = try? JSONDecoder().decode(
                [ClipboardSourceApplication].self,
                from: data
            )
        else {
            return []
        }
        return applications.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func save(_ applications: [ClipboardSourceApplication]) {
        guard let data = try? JSONEncoder().encode(applications) else { return }
        defaults.set(data, forKey: key)
    }
}
