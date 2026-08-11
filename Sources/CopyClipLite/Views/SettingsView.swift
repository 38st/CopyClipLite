import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var hotkeyController: GlobalHotkeyController
    @ObservedObject var pasteTargetController: PasteTargetController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            GeneralSettingsView(store: store, loginItem: loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }

            PrivacySettingsView(
                store: store,
                addIgnoredApplication: addIgnoredApplication
            )
            .tabItem { Label("Privacy", systemImage: "hand.raised") }

            ShortcutSettingsView(
                store: store,
                hotkeyController: hotkeyController,
                pasteTargetController: pasteTargetController
            )
            .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            DataSettingsView(store: store)
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 560, height: 440)
        .padding(.top, 8)
        .onAppear(perform: refreshSystemState)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshSystemState() }
        }
    }

    private func refreshSystemState() {
        loginItem.refresh()
        pasteTargetController.refreshPermission()
    }

    private func addIgnoredApplication() {
        guard let application = ApplicationPickerPanel.chooseApplication() else { return }
        store.addIgnoredApplication(application)
    }
}
