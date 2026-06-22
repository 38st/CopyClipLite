import SwiftUI

struct RootWindowView: View {
    @ObservedObject var store: ClipboardStore
    @AppStorage("hasCompletedWelcome") private var hasCompletedWelcome = false

    var body: some View {
        if hasCompletedWelcome {
            ClipboardPanelView(store: store)
        } else {
            WelcomeView {
                hasCompletedWelcome = true
            }
        }
    }
}
