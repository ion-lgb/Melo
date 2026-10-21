import AppKit
import Carbon.HIToolbox
import MeloCore

/// 全局/软件内快捷键注册（Carbon RegisterEventHotKey + NSEvent 本地监听）。
/// 配置存储与动作分发在 MeloCore/AppModel，本类只负责系统注册与按键解析。
@MainActor
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    /// 由 App 层设置：返回 true 表示已处理；窗口类动作由 App 层自行处理
    var actionHandler: ((String) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actionByHotKeyID: [UInt32: String] = [:]
    private var nextHotKeyID: UInt32 = 1
    private var eventHandlerRef: EventHandlerRef?
    private var localMonitor: Any?
    private var localShortcuts: [String: String] = [:]
    private var isInstalled = false

    private func installIfNeeded() {
        guard !isInstalled else { return }
        isInstalled = true

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
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
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                manager.handleGlobalHotKey(id: hotKeyID.id)
            }
            return noErr
        }, 1, &eventType, selfPointer, &eventHandlerRef)

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleLocalEvent(event) }
            return handled ? nil : event
        }
    }

    /// 重新注册（配置变化/App 启动后调用）
    func reload(config: HotKeyConfigAll) {
        installIfNeeded()
        unregisterAll()

        if config.local.enable {
            localShortcuts = Dictionary(uniqueKeysWithValues: config.local.keys.map { ($0.key, $0.value.action) })
        } else {
            localShortcuts = [:]
        }

        guard config.global.enable else { return }
        for (shortcut, binding) in config.global.keys {
            guard let parsed = Self.parse(shortcut) else { continue }
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: nextHotKeyID)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(parsed.keyCode),
                parsed.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                actionByHotKeyID[nextHotKeyID] = binding.action
                nextHotKeyID += 1
                MeloLog.info("已注册全局快捷键：\(HotKeyStore.displayName(for: shortcut)) -> \(binding.action)")
            } else {
                MeloLog.warn("注册全局快捷键失败：\(shortcut)")
            }
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        actionByHotKeyID.removeAll()
        nextHotKeyID = 1
    }

    private func handleGlobalHotKey(id: UInt32) {
        guard let action = actionByHotKeyID[id] else { return }
        actionHandler?(action)
    }

    private func handleLocalEvent(_ event: NSEvent) -> Bool {
        guard !localShortcuts.isEmpty else { return false }
        let shortcut = Self.shortcutString(for: event)
        guard let action = localShortcuts[shortcut] else { return false }
        actionHandler?(action)
        return true
    }

    // MARK: - 解析

    private static let signature: OSType = 0x4D454C4F // 'MELO'

    private static let keyCodeMap: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "arrowleft": kVK_LeftArrow, "arrowright": kVK_RightArrow, "arrowup": kVK_UpArrow, "arrowdown": kVK_DownArrow,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        "space": kVK_Space, "enter": kVK_Return, "escape": kVK_Escape, "tab": kVK_Tab, "backspace": kVK_Delete,
    ]

    struct ParsedShortcut {
        var keyCode: Int
        var modifiers: UInt32
    }

    static func parse(_ shortcut: String) -> ParsedShortcut? {
        let normalized = HotKeyStore.normalize(shortcut)
        guard !normalized.isEmpty else { return nil }
        var modifiers: UInt32 = 0
        var key: String?
        for token in normalized.split(separator: "+").map(String.init) {
            switch token {
            case "mod": modifiers |= UInt32(cmdKey)
            case "ctrl": modifiers |= UInt32(controlKey)
            case "alt": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: key = token
            }
        }
        guard let key, let keyCode = keyCodeMap[key] else { return nil }
        return ParsedShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    /// 把 NSEvent 转成与配置一致的快捷键字符串
    static func shortcutString(for event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) { parts.append("mod") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        let keyCode = Int(event.keyCode)
        if let key = keyCodeMap.first(where: { $0.value == keyCode })?.key {
            parts.append(key)
        } else if let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
            parts.append(chars)
        } else {
            return ""
        }
        return parts.joined(separator: "+")
    }
}
