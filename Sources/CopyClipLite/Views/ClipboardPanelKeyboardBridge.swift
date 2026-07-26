import AppKit
import SwiftUI

enum ClipboardPanelKeyAction: Equatable {
    case moveUp
    case moveDown
    case copySelected
    case deleteSelected
    case togglePinSelected
    case focusSearch
}

struct ClipboardPanelKeyInput {
    let keyCode: UInt16
    let charactersIgnoringModifiers: String?
    let modifierFlags: NSEvent.ModifierFlags
    let isEditingText: Bool
}

enum ClipboardPanelKeyRouting {
    static func action(
        for event: NSEvent,
        firstResponder: NSResponder?
    ) -> ClipboardPanelKeyAction? {
        action(
            for: ClipboardPanelKeyInput(
                keyCode: event.keyCode,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags,
                isEditingText: firstResponder is NSTextView
            )
        )
    }

    static func action(for input: ClipboardPanelKeyInput) -> ClipboardPanelKeyAction? {
        let modifiers = input.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let normalizedModifiers = modifiers.subtracting([.capsLock, .numericPad, .function])
        let commandOnly = normalizedModifiers == .command
        let noModifiers = normalizedModifiers.isEmpty

        if commandOnly, input.charactersIgnoringModifiers?.lowercased() == "f" {
            return .focusSearch
        }

        if commandOnly, input.charactersIgnoringModifiers?.lowercased() == "p" {
            return .togglePinSelected
        }

        if commandOnly, input.keyCode == 51 || input.keyCode == 117 {
            return .deleteSelected
        }

        guard noModifiers else {
            return nil
        }

        switch input.keyCode {
        case 125:
            return .moveDown
        case 126:
            return .moveUp
        case 36, 76:
            return .copySelected
        case 51, 117:
            return input.isEditingText ? nil : .deleteSelected
        default:
            guard !input.isEditingText,
                  input.charactersIgnoringModifiers?.lowercased() == "p" else {
                return nil
            }
            return .togglePinSelected
        }
    }

    static func handle(
        _ input: ClipboardPanelKeyInput,
        using handler: (ClipboardPanelKeyAction) -> Bool
    ) -> Bool {
        guard let action = action(for: input) else {
            return false
        }
        return handler(action)
    }

    static func handle(
        _ event: NSEvent,
        firstResponder: NSResponder?,
        using handler: (ClipboardPanelKeyAction) -> Bool
    ) -> Bool {
        guard let action = action(for: event, firstResponder: firstResponder) else {
            return false
        }
        return handler(action)
    }
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

    @MainActor
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
            ClipboardPanelKeyRouting.handle(
                event,
                firstResponder: view?.window?.firstResponder,
                using: handle
            )
        }

        private func eventBelongsToViewWindow(_ event: NSEvent) -> Bool {
            guard let window = view?.window else {
                return false
            }

            return event.window === window
        }
    }
}
