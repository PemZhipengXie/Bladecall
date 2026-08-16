import Carbon
import Foundation

private let jianlingHotKeySignature: OSType = 0x4A4C4E47 // "JLNG"
private let jianlingHotKeyID: UInt32 = 1

private let jianlingHotKeyHandler: EventHandlerUPP = { _, event, context in
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == jianlingHotKeySignature,
          hotKeyID.id == jianlingHotKeyID else {
        return OSStatus(eventNotHandledErr)
    }
    let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in controller.performAction() }
    return noErr
}

/// Carbon hot keys work while Bladecall is inactive and do not require the
/// Accessibility permission that an NSEvent global keyboard monitor would.
@MainActor
final class GlobalHotKeyController {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            registerIfNeeded()
        } else {
            unregister()
        }
    }

    fileprivate func performAction() {
        action()
    }

    private func registerIfNeeded() {
        guard hotKey == nil else { return }
        if eventHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetApplicationEventTarget(),
                jianlingHotKeyHandler,
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
        }
        let identifier = EventHotKeyID(signature: jianlingHotKeySignature, id: jianlingHotKeyID)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_J),
            UInt32(controlKey | optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }
}
