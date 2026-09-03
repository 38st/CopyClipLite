import Foundation

final class ClipboardIgnoredApplicationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults, key: String = "ignoredApplications") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [ClipboardSourceApplication] {
        lock.lock()
        defer { lock.unlock() }

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
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? JSONEncoder().encode(applications) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
enum ClipboardDefaultExclusionsSeeder {
    static let applications = [
        ClipboardSourceApplication(
            bundleIdentifier: "com.1password.1password",
            name: "1Password"
        ),
        ClipboardSourceApplication(
            bundleIdentifier: "com.bitwarden.desktop",
            name: "Bitwarden"
        ),
        ClipboardSourceApplication(
            bundleIdentifier: "org.keepassxc.keepassxc",
            name: "KeePassXC"
        ),
        ClipboardSourceApplication(
            bundleIdentifier: "com.callpod.keepermac.KeeperPasswordManager",
            name: "Keeper"
        ),
        ClipboardSourceApplication(
            bundleIdentifier: "com.dashlane.Dashlane",
            name: "Dashlane"
        ),
        ClipboardSourceApplication(
            bundleIdentifier: "com.lastpass.LastPass",
            name: "LastPass"
        ),
        ClipboardSourceApplication(
            bundleIdentifier: "ch.protonmail.pass",
            name: "Proton Pass"
        ),
        ClipboardSourceApplication(
            bundleIdentifier: "com.apple.Passwords",
            name: "Passwords"
        ),
    ]

    private static let defaultsKey = "didSeedDefaultSourceExclusionsV1"

    static func seedIfNeeded(
        defaults: UserDefaults,
        store: ClipboardIgnoredApplicationStore
    ) {
        guard !defaults.bool(forKey: defaultsKey) else { return }

        var applicationsByIdentifier: [String: ClipboardSourceApplication] = [:]
        for application in store.load() {
            applicationsByIdentifier[application.bundleIdentifier] = application
        }
        for application in applications {
            applicationsByIdentifier[application.bundleIdentifier] =
                applicationsByIdentifier[application.bundleIdentifier] ?? application
        }
        store.save(Array(applicationsByIdentifier.values))
        defaults.set(true, forKey: defaultsKey)
    }
}
