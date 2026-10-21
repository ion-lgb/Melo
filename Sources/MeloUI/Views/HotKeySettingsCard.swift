import SwiftUI
import AppKit
import MeloCore

// MARK: - 快捷键设置（软件内 / 全局）

/// 录制结果 → 与 HotKeyStore 一致的快捷键字符串（mod/ctrl/alt/shift + key）
enum HotKeyRecorderKey {
    static func shortcut(from event: NSEvent) -> String? {
        guard let key = keyToken(from: event) else { return nil }
        var tokens: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { tokens.append("mod") }
        if flags.contains(.control) { tokens.append("ctrl") }
        if flags.contains(.option) { tokens.append("alt") }
        if flags.contains(.shift) { tokens.append("shift") }
        tokens.append(key)
        return HotKeyStore.normalize(tokens.joined(separator: "+"))
    }

    private static func keyToken(from event: NSEvent) -> String? {
        switch event.keyCode {
        case 123: return "arrowleft"
        case 124: return "arrowright"
        case 125: return "arrowdown"
        case 126: return "arrowup"
        case 49: return "space"
        case 36: return "enter"
        case 48: return "tab"
        case 51: return "backspace"
        case 122: return "f1"
        case 120: return "f2"
        case 99: return "f3"
        case 118: return "f4"
        case 96: return "f5"
        case 97: return "f6"
        case 98: return "f7"
        case 100: return "f8"
        case 101: return "f9"
        case 109: return "f10"
        case 103: return "f11"
        case 111: return "f12"
        default:
            guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else {
                return nil
            }
            if let scalar = characters.unicodeScalars.first, scalar.value < 32 { return nil }
            return characters
        }
    }
}

/// 录制控件：成为第一响应者后捕获 keyDown，Esc 取消
private struct HotKeyRecorderView: NSViewRepresentable {
    let isRecording: Bool
    let onKeyDown: (String) -> Void
    let onCancel: () -> Void

    final class RecorderNSView: NSView {
        var isRecording = false
        var onKeyDown: ((String) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { isRecording }

        override func keyDown(with event: NSEvent) {
            guard isRecording else {
                super.keyDown(with: event)
                return
            }
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            if let shortcut = HotKeyRecorderKey.shortcut(from: event), !shortcut.isEmpty {
                onKeyDown?(shortcut)
            }
        }

        override func flagsChanged(with event: NSEvent) {
            // 录制以 keyDown 为准；单独按修饰键不产生快捷键
        }
    }

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.isRecording = isRecording
        view.onKeyDown = onKeyDown
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.isRecording = isRecording
        nsView.onKeyDown = onKeyDown
        nsView.onCancel = onCancel
        if isRecording {
            DispatchQueue.main.async {
                if let window = nsView.window {
                    window.makeFirstResponder(nsView)
                }
            }
        }
    }
}

// MARK: - 快捷键设置卡片

struct HotKeySettingsCard: View {
    let app: AppModel

    private struct RecordingTarget: Equatable {
        let action: String
        let scope: HotKeyScope
    }

    @Environment(\.meloColors) private var colors

    @State private var recording: RecordingTarget?
    @State private var showResetConfirm = false

    init(app: AppModel,
         previewRecordingAction: String? = nil,
         previewRecordingScope: HotKeyScope = .local,
         previewResetConfirm: Bool = false) {
        self.app = app
        if let previewRecordingAction {
            _recording = State(initialValue: RecordingTarget(action: previewRecordingAction, scope: previewRecordingScope))
        }
        _showResetConfirm = State(initialValue: previewResetConfirm)
    }

    var body: some View {
        MeloCard(
            title: "快捷键",
            subtitle: "软件内快捷键仅 App 前台生效；全局快捷键由系统级注册（需系统允许，部分组合可能被系统占用）。配置兼容原版 hot_key.json",
            systemImage: "keyboard"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                hotKeySection(scope: .local)
                Divider().overlay(colors.border)
                hotKeySection(scope: .global)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(colors.fontTertiary)
                        .padding(.top, 1)
                    Text("点击快捷键框后按下新的组合键完成录制，Esc 取消；清除按钮可解除绑定。「恢复默认」会同时恢复本地/全局两类快捷键的原版默认值（如 ⌘F5 播放/暂停）。全局快捷键被其他程序占用时可能注册失败，可在系统设置中检查。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(colors.fontTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 隐藏的键盘录制控件（录制时成为第一响应者）
                HotKeyRecorderView(
                    isRecording: recording != nil,
                    onKeyDown: { shortcut in finishRecording(shortcut) },
                    onCancel: { recording = nil }
                )
                .frame(width: 0, height: 0)
            }
        }
        .alert("恢复默认快捷键", isPresented: $showResetConfirm) {
            Button(Localizer.tr("btn_cancel"), role: .cancel) {}
            Button("恢复默认", role: .destructive) {
                app.resetHotKeys()
            }
        } message: {
            Text("将把「软件内快捷键」和「全局快捷键」恢复为原版默认配置（⌘F5、⌘⌥←/→ 等），当前自定义绑定会被覆盖。")
        }
        .onDisappear { recording = nil }
    }

    // MARK: 区块

    private func hotKeySection(scope: HotKeyScope) -> some View {
        let definitions = scope == .local ? app.hotKeyLocalDefinitions : app.hotKeyGlobalDefinitions
        let isEnabled = scope == .local ? app.hotKeys.local.enable : app.hotKeys.global.enable
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: scope == .local ? "macwindow" : "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.primary)
                Text(scope == .local ? Localizer.tr("setting__hot_key_local_title") : Localizer.tr("setting__hot_key_global_title"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(colors.font)
                Text(scope == .local ? "· 仅 App 前台" : "· 系统级注册")
                    .font(.system(size: 9.5))
                    .foregroundStyle(colors.fontTertiary)
                if !isEnabled {
                    Text("已禁用")
                        .font(.system(size: 9))
                        .foregroundStyle(colors.badgeTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(colors.badgeTertiary.opacity(0.10), in: Capsule())
                }
                Spacer()
                Toggle(Localizer.tr("setting__is_enable"), isOn: Binding(
                    get: { isEnabled },
                    set: { app.setHotKeysEnabled($0, scope: scope) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 10.5))

                Button("恢复默认") {
                    showResetConfirm = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            VStack(spacing: 0) {
                ForEach(Array(definitions.enumerated()), id: \.element.id) { index, definition in
                    hotKeyRow(definition, scope: scope)
                    if index < definitions.count - 1 {
                        Divider().overlay(colors.border.opacity(0.65))
                    }
                }
            }
            .background(
                colors.fontTertiary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(colors.border, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.72)
        }
    }

    private func hotKeyRow(_ definition: HotKeyDefinition, scope: HotKeyScope) -> some View {
        let isRecordingRow = recording == RecordingTarget(action: definition.action, scope: scope)
        let displayName = app.hotKeyDisplayName(for: definition.action, scope: scope)
        return HStack(spacing: 10) {
            Text(definition.label)
                .font(.system(size: 11))
                .foregroundStyle(colors.font)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                recording = RecordingTarget(action: definition.action, scope: scope)
            } label: {
                HStack(spacing: 5) {
                    if isRecordingRow {
                        ProgressView().controlSize(.mini)
                        Text("请按新的快捷键（Esc 取消）")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(colors.primary)
                    } else if displayName.isEmpty {
                        Text(Localizer.tr("setting__hot_key_unset_input"))
                            .font(.system(size: 10))
                            .foregroundStyle(colors.fontTertiary)
                    } else {
                        Text(displayName)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(colors.font)
                    }
                }
                .frame(width: 196, height: 20)
                .background(
                    isRecordingRow ? colors.primary.opacity(0.10) : colors.fontTertiary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isRecordingRow ? colors.primary.opacity(0.5) : colors.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(isRecordingRow ? "按下新的快捷键，Esc 取消" : "点击录制新的快捷键")

            Button {
                app.unbindHotKey(for: definition.action, scope: scope)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(displayName.isEmpty ? colors.fontTertiary.opacity(0.4) : colors.fontTertiary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(displayName.isEmpty)
            .help("清除该快捷键")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isRecordingRow ? colors.primary.opacity(0.05) : Color.clear)
    }

    // MARK: 动作

    private func finishRecording(_ shortcut: String) {
        guard let target = recording else { return }
        let definitions = target.scope == .local ? app.hotKeyLocalDefinitions : app.hotKeyGlobalDefinitions
        guard let definition = definitions.first(where: { $0.action == target.action }) else {
            recording = nil
            return
        }

        // 检查同一作用域内是否已被其它动作占用（AppModel 会覆盖，这里额外提示）
        let normalized = HotKeyStore.normalize(shortcut)
        let conflict = definitions.first { other in
            other.action != target.action
                && app.hotKeyBinding(for: other.action, scope: target.scope) == normalized
        }
        if let conflict {
            app.showToast("提示：组合键已被「\(conflict.label)」使用，将覆盖原绑定")
        }

        app.bindHotKey(shortcut, to: definition, scope: target.scope)
        recording = nil
    }
}
