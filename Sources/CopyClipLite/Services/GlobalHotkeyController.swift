import AppKit
import Carbon
import Foundation

@MainActor
final class GlobalHotkeyController: ObservableObject {
    @Published private(set) var isRegistered = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var config: HotkeyConfig

    var action: (() -> Void)?

    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
    private var eventHandlerInstalled = false
    nonisolated(unsafe) private var weakBox: Unmanaged<AnyObject>?

    var statusText: String {
        if isRegistered {
            return config.displayString
        }

        return errorMessage ?? "Unavailable"
    }

    init(config: HotkeyConfig = HotkeyConfig.load()) {
        self.config = config
        installEventHandlerIfNeeded()
        registerHotKey()
    }

    deinit {
        unregister()
    }

    func updateConfig(_ newConfig: HotkeyConfig) {
        unregisterHotKey()
        config = newConfig
        newConfig.save()
        registerHotKey()
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let box = HotkeyWeakBox(self)
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleHotKeyEvent,
            1,
            &eventType,
            Unmanaged.passRetained(box).toOpaque(),
            &installedHandler
        )

        guard handlerStatus == noErr else {
            errorMessage = "Hotkey handler failed (\(handlerStatus))"
            return
        }

        eventHandlerRef = installedHandler
        eventHandlerInstalled = true
        weakBox = Unmanaged.passRetained(box)
    }

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        var registeredHotKey: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(config.keyCode),
            UInt32(config.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )

        guard registerStatus == noErr else {
            errorMessage = "\(config.displayString) is in use"
            isRegistered = false
            return
        }

        hotKeyRef = registeredHotKey
        isRegistered = true
        errorMessage = nil
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        isRegistered = false
    }

    nonisolated private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }

        hotKeyRef = nil
        eventHandlerRef = nil

        if let weakBox {
            weakBox.release()
            self.weakBox = nil
        }
    }

    private func performAction() {
        action?()
    }

    private static let handleHotKeyEvent: EventHandlerUPP = { _, _, userData in
        guard let userData else {
            return noErr
        }

        let box = Unmanaged<HotkeyWeakBox>
            .fromOpaque(userData)
            .takeUnretainedValue()

        guard let controller = box.controller else {
            return noErr
        }

        DispatchQueue.main.async {
            controller.performAction()
        }

        return noErr
    }

    private final class HotkeyWeakBox {
        weak var controller: GlobalHotkeyController?
        init(_ controller: GlobalHotkeyController) {
            self.controller = controller
        }
    }

    private static let hotKeySignature: OSType = {
        let bytes = Array("CCLT".utf8)
        return OSType(bytes[0]) << 24
            | OSType(bytes[1]) << 16
            | OSType(bytes[2]) << 8
            | OSType(bytes[3])
    }()
}
