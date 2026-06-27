import AppKit
import SwiftUI

enum ClipboardPanelKeyAction {
    case moveUp
    case moveDown
    case copySelected
    case deleteSelected
    case togglePinSelected
    case focusSearch
}

struct ClipboardPanelKeyboardBridge: NSViewRepresentable {
    let handle: (ClipboardPanelKeyAction) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: handle)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var view: NSView?
        var handle: (ClipboardPanelKeyAction) -> Bool
        private var monitor: Any?

        init(handle: @escaping (ClipboardPanelKeyAction) -> Bool) {
            self.handle = handle
        }

        func installMonitor() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.eventBelongsToViewWindow(event) else {
                    return event
                }

                return self.handle(event) ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let commandOnly = modifiers == .command
            let noModifiers = modifiers.subtracting([.capsLock, .numericPad, .function]).isEmpty

            if commandOnly, event.charactersIgnoringModifiers?.lowercased() == "f" {
                return handle(.focusSearch)
            }

            guard noModifiers else {
                return false
            }

            switch event.keyCode {
            case 125:
                return handle(.moveDown)
            case 126:
                return handle(.moveUp)
            case 36, 76:
                return handle(.copySelected)
            case 51, 117:
                guard !isEditingText else { return false }
                return handle(.deleteSelected)
            default:
                guard !isEditingText,
                      event.charactersIgnoringModifiers?.lowercased() == "p" else {
                    return false
                }
                return handle(.togglePinSelected)
            }
        }

        private func eventBelongsToViewWindow(_ event: NSEvent) -> Bool {
            guard let window = view?.window else {
                return false
            }

            return event.window === window
        }

        private var isEditingText: Bool {
            guard let firstResponder = view?.window?.firstResponder else {
                return false
            }

            return firstResponder is NSTextView
        }
    }
}
