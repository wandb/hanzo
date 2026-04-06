import HotKey
import AppKit

final class HotkeyService {
    private let settings: AppSettingsProtocol
    private var hotKey: HotKey?
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    init(settings: AppSettingsProtocol = AppSettings.live) {
        self.settings = settings
    }

    func register() {
        let carbonKeyCode = settings.hotkeyCode
        let carbonModifiers = settings.hotkeyModifiers

        hotKey = HotKey(carbonKeyCode: carbonKeyCode, carbonModifiers: carbonModifiers)
        hotKey?.keyDownHandler = { [weak self] in
            self?.onKeyDown?()
        }
        hotKey?.keyUpHandler = { [weak self] in
            self?.onKeyUp?()
        }
        LoggingService.shared.info("Hotkey registered: keyCode=\(carbonKeyCode), modifiers=\(carbonModifiers)")
    }

    func unregister() {
        hotKey = nil
        LoggingService.shared.info("Hotkey unregistered")
    }

    func reregister() {
        unregister()
        register()
    }

    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & 4096 != 0 { parts.append("⌃") }
        if modifiers & 2048 != 0 { parts.append("⌥") }
        if modifiers & 512 != 0 { parts.append("⇧") }
        if modifiers & 256 != 0 { parts.append("⌘") }

        let keyName = Key(carbonKeyCode: keyCode)?.description
            ?? String(format: "0x%02X", keyCode)
        parts.append(keyName)

        return parts.joined(separator: " ")
    }
}

private extension Key {
    var description: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .d: return "D"
        case .e: return "E"
        case .f: return "F"
        case .g: return "G"
        case .h: return "H"
        case .i: return "I"
        case .j: return "J"
        case .k: return "K"
        case .l: return "L"
        case .m: return "M"
        case .n: return "N"
        case .o: return "O"
        case .p: return "P"
        case .q: return "Q"
        case .r: return "R"
        case .s: return "S"
        case .t: return "T"
        case .u: return "U"
        case .v: return "V"
        case .w: return "W"
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        case .zero: return "0"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5"
        case .six: return "6"
        case .seven: return "7"
        case .eight: return "8"
        case .nine: return "9"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        case .f13: return "F13"
        case .f14: return "F14"
        case .f15: return "F15"
        case .f16: return "F16"
        case .f17: return "F17"
        case .f18: return "F18"
        case .f19: return "F19"
        case .f20: return "F20"
        case .space: return "Space"
        case .tab: return "Tab"
        case .return: return "Return"
        case .escape: return "Esc"
        case .delete: return "Delete"
        case .forwardDelete: return "Fwd Delete"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .period: return "."
        case .comma: return ","
        case .slash: return "/"
        case .backslash: return "\\"
        case .minus: return "-"
        case .equal: return "="
        case .semicolon: return ";"
        case .quote: return "'"
        case .leftBracket: return "["
        case .rightBracket: return "]"
        case .grave: return "`"
        default: return "?"
        }
    }
}
