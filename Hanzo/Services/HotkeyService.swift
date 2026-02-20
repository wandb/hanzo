import HotKey
import AppKit

final class HotkeyService {
    private var hotKey: HotKey?
    var onToggle: (() -> Void)?

    func register() {
        // Default: Ctrl + Option + H
        hotKey = HotKey(key: .h, modifiers: [.control, .option])
        hotKey?.keyDownHandler = { [weak self] in
            self?.onToggle?()
        }
        LoggingService.shared.info("Hotkey registered: Ctrl+Option+H")
    }

    func unregister() {
        hotKey = nil
        LoggingService.shared.info("Hotkey unregistered")
    }
}
