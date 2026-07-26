import SwiftUI

struct RootWindowView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var pasteTargetController: PasteTargetController
    @ObservedObject var hotkeyController: GlobalHotkeyController
    @AppStorage("hasCompletedWelcome") private var hasCompletedWelcome = false

    var body: some View {
        if hasCompletedWelcome {
            ClipboardPanelView(
                store: store,
                pasteTargetController: pasteTargetController,
                presentationContext: .mainWindow
            )
        } else {
            WelcomeView(hotkeyController: hotkeyController) {
                hasCompletedWelcome = true
            }
        }
    }
}
