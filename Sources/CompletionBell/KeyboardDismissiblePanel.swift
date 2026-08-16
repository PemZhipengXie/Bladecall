import AppKit

/// `nonactivatingPanel` windows do not always send Escape through the normal
/// app command path, so handle both direct keyDown and responder cancellation.
@MainActor
class KeyboardDismissiblePanel: NSPanel {
    var onEscape: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode != 53 else {
            onEscape()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }
}
