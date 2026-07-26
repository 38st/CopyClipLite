import XCTest
@testable import CopyClipLite

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var defaultsSuites: [String] = []

    override func tearDownWithError() throws {
        for suiteName in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        defaultsSuites.removeAll()

        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()

        try super.tearDownWithError()
    }

    func testFirstRunShowsWelcomeWindowAndActivatesApplication() {
        let policy = CopyClipAppLaunchPolicy(hasCompletedWelcome: false)

        XCTAssertFalse(policy.suppressesInitialMainWindow)
        XCTAssertTrue(policy.activatesApplicationAfterLaunch)
    }

    func testReturningLaunchSuppressesInitialWindowAndStaysAccessoryOnly() {
        let policy = CopyClipAppLaunchPolicy(hasCompletedWelcome: true)

        XCTAssertTrue(policy.suppressesInitialMainWindow)
        XCTAssertFalse(policy.activatesApplicationAfterLaunch)
    }

    func testInitialWindowSuppressionIsConsumedOnlyOnce() {
        let delegate = makeDelegate(hasCompletedWelcome: true)

        XCTAssertTrue(delegate.consumeInitialWindowSuppression())
        XCTAssertFalse(delegate.consumeInitialWindowSuppression())
    }

    func testResigningActiveFlushesPendingStoreMutation() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeDefaults()
        defaults.set(false, forKey: "monitoringEnabled")
        storage.save([ClipboardItem(text: "pending deletion")])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults,
            sourceApplicationProvider: { nil }
        )
        let item = try XCTUnwrap(store.items.first)
        store.delete(item)
        let delegate = makeDelegate(hasCompletedWelcome: true)
        delegate.store = store

        delegate.applicationWillResignActive(
            Notification(name: NSApplication.didResignActiveNotification)
        )

        XCTAssertTrue(storage.load().isEmpty)
    }

    func testTerminatingKeepsPinnedItemsAndRemovesUnpinnedHistory() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeDefaults()
        defaults.set(false, forKey: "monitoringEnabled")
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        storage.save([
            ClipboardItem(text: "pinned", isPinned: true),
            ClipboardItem(text: "unpinned"),
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults,
            sourceApplicationProvider: { nil }
        )
        let delegate = makeDelegate(hasCompletedWelcome: true)
        delegate.store = store

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertEqual(store.items.map(\.text), ["pinned"])
        XCTAssertEqual(storage.load().map(\.text), ["pinned"])
    }

    private func makeDelegate(hasCompletedWelcome: Bool) -> AppDelegate {
        AppDelegate(
            hasCompletedWelcome: { hasCompletedWelcome },
            applyAccessoryActivationPolicy: {},
            activateApplication: {},
            cleanupWithoutStore: {}
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLiteLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        tempDirectories.append(directory)
        return directory
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CopyClipLiteLifecycleTests-\(UUID().uuidString)"
        defaultsSuites.append(suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(
            name: NSPasteboard.Name("CopyClipLiteLifecycleTests-\(UUID().uuidString)")
        )
    }
}
