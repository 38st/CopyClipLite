import AppKit
import Carbon
import Foundation

final class GlobalHotkeyController: ObservableObject {
    @Published private(set) var isRegistered = false
    @Published private(set) var errorMessage: String?

    var action: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    var statusText: String {
        if isRegistered {
            return "Option-Command-V"
        }

        return errorMessage ?? "Unavailable"
    }

    init() {
        register()
    }

    deinit {
        unregister()
    }

    private func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleHotKeyEvent,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )

        guard handlerStatus == noErr else {
            errorMessage = "Hotkey handler failed (\(handlerStatus))"
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        var registeredHotKey: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )

        guard registerStatus == noErr else {
            if let installedHandler {
                RemoveEventHandler(installedHandler)
            }
            errorMessage = "Option-Command-V is in use"
            return
        }

        eventHandlerRef = installedHandler
        hotKeyRef = registeredHotKey
        isRegistered = true
        errorMessage = nil
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }

        hotKeyRef = nil
        eventHandlerRef = nil
        isRegistered = false
    }

    private func performAction() {
        action?()
    }

    private static let handleHotKeyEvent: EventHandlerUPP = { _, _, userData in
        guard let userData else {
            return noErr
        }

        let controller = Unmanaged<GlobalHotkeyController>
            .fromOpaque(userData)
            .takeUnretainedValue()

        DispatchQueue.main.async {
            controller.performAction()
        }

        return noErr
    }

    private static let hotKeySignature: OSType = {
        let bytes = Array("CCLT".utf8)
        return OSType(bytes[0]) << 24
            | OSType(bytes[1]) << 16
            | OSType(bytes[2]) << 8
            | OSType(bytes[3])
    }()
}
