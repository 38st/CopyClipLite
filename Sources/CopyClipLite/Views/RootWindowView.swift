import SwiftUI

struct RootWindowView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var pasteTargetController: PasteTargetController
    @AppStorage("hasCompletedWelcome") private var hasCompletedWelcome = false

    var body: some View {
        if hasCompletedWelcome {
            ClipboardPanelView(store: store, pasteTargetController: pasteTargetController)
        } else {
            WelcomeView {
                hasCompletedWelcome = true
            }
        }
    }
}
