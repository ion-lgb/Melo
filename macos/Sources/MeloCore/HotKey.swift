import Foundation

// MARK: - 快捷键（兼容原版 LxDatas/hot_key.json：{"local":{enable,keys:{shortcut:{type,name,action}}},"global":{...}}）

public enum HotKeyScope: String, Codable, Sendable, CaseIterable {
    case local
    case global
}

public struct HotKeyBinding: Codable, Hashable, Sendable {
    public var type: String
    public var name: String
    public var action: String

    public init(type: String, name: String, action: String) {
        self.type = type
        self.name = name
        self.action = action
    }
}

public struct HotKeyConfig: Codable, Sendable, Equatable {
    public var enable: Bool
    public var keys: [String: HotKeyBinding]

    public init(enable: Bool = false, keys: [String: HotKeyBinding] = [:]) {
        self.enable = enable
        self.keys = keys
    }
}

public struct HotKeyConfigAll: Codable, Sendable, Equatable {
    public var local: HotKeyConfig
    public var global: HotKeyConfig

    public init(local: HotKeyConfig = HotKeyConfig(), global: HotKeyConfig = HotKeyConfig()) {
        self.local = local
        self.global = global
    }
}

public struct HotKeyDefinition: Identifiable, Hashable, Sendable {
    public var action: String
    public var label: String
    public var scope: HotKeyScope
    public var type: String

    public var id: String { action }

    public init(action: String, label: String, scope: HotKeyScope, type: String) {
        self.action = action
        self.label = label
        self.scope = scope
        self.type = type
    }
}

public enum HotKeyStore {
    public static func fileURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("hot_key.json")
    }

    public static func load(from dataDirectory: URL) -> HotKeyConfigAll {
        let url = fileURL(dataDirectory: dataDirectory)
        guard let data = try? Data(contentsOf: url),
              let root = JSONValue(jsonData: data)?.objectValue else {
            return defaultConfig
        }
        return HotKeyConfigAll(
            local: decodeConfig(root["local"]) ?? defaultConfig.local,
            global: decodeConfig(root["global"]) ?? defaultConfig.global
        )
    }

    private static func decodeConfig(_ value: JSONValue?) -> HotKeyConfig? {
        guard let object = value?.objectValue else { return nil }
        let enable = object["enable"]?.boolValue ?? false
        var keys: [String: HotKeyBinding] = [:]
        if let keyObject = object["keys"]?.objectValue {
            for (shortcut, info) in keyObject {
                guard let infoObject = info.objectValue,
                      let action = infoObject["action"]?.stringValue else { continue }
                keys[shortcut] = HotKeyBinding(
                    type: infoObject["type"]?.stringValue ?? "",
                    name: infoObject["name"]?.stringValue ?? action,
                    action: action
                )
            }
        }
        return HotKeyConfig(enable: enable, keys: keys)
    }

    public static func save(_ config: HotKeyConfigAll, to dataDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let url = fileURL(dataDirectory: dataDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: 动作定义（名称取自原版 lang/zh-cn）

    public static let playerDefinitions: [HotKeyDefinition] = [
        .init(action: "player_toggle_play", label: "播放/暂停控制", scope: .global, type: "player"),
        .init(action: "player_next", label: "下一首歌曲", scope: .global, type: "player"),
        .init(action: "player_prev", label: "上一首歌曲", scope: .global, type: "player"),
        .init(action: "player_seekbackward", label: "快退 5s", scope: .global, type: "player"),
        .init(action: "player_seekforward", label: "快进 5s", scope: .global, type: "player"),
        .init(action: "player_volume_up", label: "增加音量", scope: .global, type: "player"),
        .init(action: "player_volume_down", label: "减少音量", scope: .global, type: "player"),
        .init(action: "player_volume_mute", label: "静音切换", scope: .global, type: "player"),
        .init(action: "player_music_love", label: "收藏歌曲", scope: .global, type: "player"),
        .init(action: "player_music_unlove", label: "取消收藏", scope: .global, type: "player"),
        .init(action: "player_music_dislike", label: "不喜欢该歌曲", scope: .global, type: "player"),
    ]

    public static let commonDefinitions: [HotKeyDefinition] = [
        .init(action: "common_min", label: "最小化程序", scope: .global, type: "common"),
        .init(action: "common_toggle_min", label: "最小化/还原程序", scope: .global, type: "common"),
        .init(action: "common_toggle_hide", label: "显示/隐藏程序", scope: .global, type: "common"),
        .init(action: "common_toggle_close", label: "退出程序", scope: .global, type: "common"),
        .init(action: "common_focus_search_input", label: "聚焦搜索框", scope: .global, type: "common"),
    ]

    public static let desktopLyricDefinitions: [HotKeyDefinition] = [
        .init(action: "desktop_lyric_toggle_visible", label: "开/关桌面歌词", scope: .global, type: "desktop_lyric"),
        .init(action: "desktop_lyric_toggle_lock", label: "桌面歌词锁定切换", scope: .global, type: "desktop_lyric"),
        .init(action: "desktop_lyric_toggle_always_top", label: "桌面歌词置顶切换", scope: .global, type: "desktop_lyric"),
    ]

    /// 软件内快捷键（与窗口/播放器相关，App 内生效）
    public static var localDefinitions: [HotKeyDefinition] {
        playerDefinitions.map { definition in
            var copy = definition
            copy.scope = .local
            return copy
        } + [HotKeyDefinition(action: "common_focus_search_input", label: "聚焦搜索框", scope: .local, type: "common")]
    }

    /// 全局快捷键（系统级注册）
    public static var globalDefinitions: [HotKeyDefinition] {
        var defs = commonDefinitions + playerDefinitions
        defs += desktopLyricDefinitions
        return defs
    }

    public static func definition(for action: String) -> HotKeyDefinition? {
        (localDefinitions + globalDefinitions).first { $0.action == action }
    }

    // MARK: 默认配置（逐项对齐原版 src/common/defaultHotKey.ts）

    public static let defaultConfig = HotKeyConfigAll(
        local: HotKeyConfig(enable: true, keys: [
            "mod+f5": HotKeyBinding(type: "player", name: "player_toggle_play", action: "player_toggle_play"),
            "mod+arrowleft": HotKeyBinding(type: "player", name: "player_prev", action: "player_prev"),
            "mod+arrowright": HotKeyBinding(type: "player", name: "player_next", action: "player_next"),
            "f1": HotKeyBinding(type: "common", name: "common_focus_search_input", action: "common_focus_search_input"),
        ]),
        global: HotKeyConfig(enable: false, keys: [
            "mod+alt+f5": HotKeyBinding(type: "player", name: "player_toggle_play", action: "player_toggle_play"),
            "mod+alt+arrowleft": HotKeyBinding(type: "player", name: "player_prev", action: "player_prev"),
            "mod+alt+arrowright": HotKeyBinding(type: "player", name: "player_next", action: "player_next"),
            "mod+alt+arrowup": HotKeyBinding(type: "player", name: "player_volume_up", action: "player_volume_up"),
            "mod+alt+arrowdown": HotKeyBinding(type: "player", name: "player_volume_down", action: "player_volume_down"),
            "mod+alt+0": HotKeyBinding(type: "desktop_lyric", name: "desktop_lyric_toggle_visible", action: "desktop_lyric_toggle_visible"),
            "mod+alt+-": HotKeyBinding(type: "desktop_lyric", name: "desktop_lyric_toggle_lock", action: "desktop_lyric_toggle_lock"),
            "mod+alt+=": HotKeyBinding(type: "desktop_lyric", name: "desktop_lyric_toggle_always_top", action: "desktop_lyric_toggle_always_top"),
        ])
    )

    // MARK: 快捷键字符串处理

    /// 归一化：小写、统一箭头/空格等别名，并保持 token 顺序（mod/shift/alt/ctrl 在前）。
    public static func normalize(_ shortcut: String) -> String {
        let tokens = shortcut
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+")
            .map(String.init)
        guard !tokens.isEmpty else { return "" }
        let modifierOrder = ["mod", "ctrl", "alt", "shift"]
        var modifiers = Set<String>()
        var key: String?
        for token in tokens {
            switch token {
            case "mod", "commandorcontrol", "cmd", "command", "super", "meta":
                modifiers.insert("mod")
            case "ctrl", "control":
                modifiers.insert("ctrl")
            case "alt", "option", "opt":
                modifiers.insert("alt")
            case "shift":
                modifiers.insert("shift")
            case "arrowleft", "left", "←":
                key = "arrowleft"
            case "arrowright", "right", "→":
                key = "arrowright"
            case "arrowup", "up", "↑":
                key = "arrowup"
            case "arrowdown", "down", "↓":
                key = "arrowdown"
            case "space", " ":
                key = "space"
            case "enter", "return":
                key = "enter"
            case "esc", "escape":
                key = "escape"
            case "backspace":
                key = "backspace"
            case "tab":
                key = "tab"
            default:
                key = token
            }
        }
        guard let key else { return "" }
        var parts = modifierOrder.filter { modifiers.contains($0) }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    public static func displayName(for shortcut: String) -> String {
        guard !shortcut.isEmpty else { return "" }
        let keyNames: [String: String] = [
            "arrowleft": "←", "arrowright": "→", "arrowup": "↑", "arrowdown": "↓",
            "space": "Space", "enter": "Enter", "escape": "Esc", "backspace": "Backspace", "tab": "Tab",
            "mod": "⌘", "alt": "⌥", "ctrl": "⌃", "shift": "⇧",
        ]
        let tokens = shortcut.split(separator: "+").map(String.init)
        var result = ""
        for (index, token) in tokens.enumerated() {
            let name = keyNames[token] ?? token.uppercased()
            if index == 0 {
                result = name == "⌘" || name == "⌥" || name == "⌃" || name == "⇧" ? name : token.uppercased()
            } else {
                let isModifier = keyNames[token] != nil && ["mod", "alt", "ctrl", "shift"].contains(token)
                if isModifier || (keyNames[token] != nil && !["space", "enter", "escape", "backspace", "tab"].contains(token)) {
                    result += name
                } else {
                    result += " + " + name
                }
            }
        }
        return result
    }

    public static func matches(eventKey: String, flags: Set<String>, shortcut: String) -> Bool {
        let normalized = normalize(shortcut)
        guard !normalized.isEmpty else { return false }
        var tokens = Set(normalized.split(separator: "+").map(String.init))
        let expectedKey = tokens.remove("mod") != nil ? "mod" : nil
        _ = expectedKey
        var requiredModifiers = Set<String>()
        for modifier in ["mod", "ctrl", "alt", "shift"] where tokens.contains(modifier) {
            requiredModifiers.insert(modifier)
            tokens.remove(modifier)
        }
        guard let key = tokens.first else { return false }
        return key == eventKey.lowercased() && requiredModifiers == flags
    }
}
