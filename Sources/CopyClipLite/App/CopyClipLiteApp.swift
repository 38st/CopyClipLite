import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: ClipboardStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if !UserDefaults.standard.bool(forKey: "hasCompletedWelcome") {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let store {
            store.clearUnpinnedHistoryOnQuitIfNeeded()
        } else {
            ClipboardStore.clearUnpinnedHistoryOnQuitIfNeeded()
        }
    }
}

@main
struct CopyClipLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ClipboardStore()
    @StateObject private var loginItemController = LoginItemController()

    var body: some Scene {
        WindowGroup("CopyClip Lite", id: "main") {
            RootWindowView(store: store)
                .frame(minWidth: 390, idealWidth: 420, minHeight: 560, idealHeight: 620)
                .onAppear { appDelegate.store = store }
        }
        .defaultSize(width: 420, height: 620)

        MenuBarExtra("CopyClip Lite", systemImage: "clipboard") {
            ClipboardPanelView(store: store)
                .frame(width: 380, height: 520)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store, loginItem: loginItemController)
        }
    }
}
