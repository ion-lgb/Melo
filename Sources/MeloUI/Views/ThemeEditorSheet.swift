import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeloCore

// MARK: - 主题编辑器（新建 / 编辑自定义主题）

/// 可编辑的关键颜色变量（实际存在于内置/用户主题的 themeColors + extInfo 中）
struct ThemeColorField: Identifiable {
    let key: String
    let label: String
    let group: String
    var id: String { key }

    static let all: [ThemeColorField] = [
        .init(key: "--color-primary", label: "主色", group: "主色"),
        .init(key: "--color-theme", label: Localizer.tr("theme_edit_modal__primary"), group: "主色"),
        .init(key: "--color-primary-light-100", label: "主色浅", group: "主色"),

        .init(key: "--color-000", label: "背景 000", group: "背景"),
        .init(key: "--color-100", label: "背景 100", group: "背景"),
        .init(key: "--color-200", label: "边框 200", group: "背景"),
        .init(key: "--color-app-background", label: "应用背景", group: "背景"),
        .init(key: "--color-main-background", label: "主背景", group: "背景"),

        .init(key: "--color-500", label: "中性 500", group: "文字 / 中性"),
        .init(key: "--color-900", label: "文字 900", group: "文字 / 中性"),
        .init(key: "--color-1000", label: "文字 1000", group: "文字 / 中性"),
        .init(key: "--color-nav-font", label: "导航文字", group: "文字 / 中性"),

        .init(key: "--color-badge-primary", label: "徽标主色", group: "徽标 / 按钮"),
        .init(key: "--color-badge-secondary", label: "徽标次色", group: "徽标 / 按钮"),
        .init(key: "--color-badge-tertiary", label: "徽标第三色", group: "徽标 / 按钮"),
        .init(key: "--color-btn-hide", label: "按钮隐藏", group: "徽标 / 按钮"),
        .init(key: "--color-btn-min", label: "按钮最小", group: "徽标 / 按钮"),
        .init(key: "--color-btn-close", label: "按钮关闭", group: "徽标 / 按钮"),
    ]

    static let groups: [String] = ["主色", "背景", "文字 / 中性", "徽标 / 按钮"]
}

struct ThemeEditorSheet: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @Environment(\.dismiss) private var dismiss

    @State private var editing: Theme?
    @State private var name: String
    @State private var baseID: String
    @State private var isDark: Bool
    @State private var isDarkFont: Bool
    @State private var values: [String: String]
    @State private var showDeleteConfirm = false
    @State private var errorText: String?

    init(app: AppModel, editingTheme: Theme? = nil, initialBaseID: String? = nil, initialName: String = "") {
        self.app = app
        _editing = State(initialValue: editingTheme)
        let resolvedBase = editingTheme?.id ?? initialBaseID ?? app.currentTheme.id
        _baseID = State(initialValue: resolvedBase)
        _name = State(initialValue: editingTheme?.name ?? (initialName.isEmpty ? "我的主题" : initialName))
        let source = editingTheme
            ?? app.allThemes.first(where: { $0.id == resolvedBase })
            ?? app.currentTheme
        _isDark = State(initialValue: source.isDark)
        _isDarkFont = State(initialValue: source.isDarkFont)
        var initial: [String: String] = [:]
        let variables = ThemePreview.variables(source)
        for field in ThemeColorField.all {
            initial[field.key] = Self.normalizeCSS(Self.resolveCSS(field.key, variables: variables))
        }
        _values = State(initialValue: initial)
    }

    private var isNew: Bool { editing == nil }

    private func themeDisplayName(_ theme: Theme) -> String {
        "\(theme.name)\(theme.isCustom == true ? "（自定义）" : "")"
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmedName.isEmpty }

    private var baseTheme: Theme {
        app.allThemes.first(where: { $0.id == baseID }) ?? app.currentTheme
    }

    /// 编辑已保存主题时，从 config.extInfo["baseThemeId"] 读取基础主题（MeloCore 创建时写入）；
    /// 不存在则回退当前主题。
    private var editingBaseThemeName: String {
        guard let editing else { return themeDisplayName(baseTheme) }
        let stored = editing.config.extInfo["baseThemeId"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty, let base = app.allThemes.first(where: { $0.id == stored }) {
            return themeDisplayName(base)
        }
        return themeDisplayName(app.currentTheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(colors.border)
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    form
                        .padding(18)
                }
                .frame(width: 470)
                Divider().overlay(colors.border)
                ScrollView {
                    previewPane
                        .padding(18)
                }
                .frame(maxWidth: .infinity)
            }
            Divider().overlay(colors.border)
            footer
        }
        .frame(width: 940, height: 760)
        .background(colors.mainBackground)
        .alert("删除自定义主题", isPresented: $showDeleteConfirm) {
            Button(Localizer.tr("btn_cancel"), role: .cancel) {}
            Button("删除", role: .destructive) {
                if let editing {
                    app.removeUserTheme(id: editing.id)
                    dismiss()
                }
            }
        } message: {
            Text("将删除「\(editing?.name ?? "")」，此操作不可撤销；内置主题不受影响。")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(colors.primary.opacity(0.12))
                Image(systemName: isNew ? "paintpalette.fill" : "pencil.and.outline")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.primary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "新建主题" : Localizer.tr("theme_edit_modal__title_edit"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colors.font)
                Text(isNew
                     ? "基于内置/用户主题创建自定义配色；保存后写入 LxDatas/theme.json（原版格式）"
                     : "修改「\(editing?.name ?? "")」的颜色与名称；保存后立即应用")
                    .font(.system(size: 10))
                    .foregroundStyle(colors.fontTertiary)
            }
            Spacer()
            if let editing {
                Text(editing.id.hasPrefix("custom_") ? "自定义主题" : "主题")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(colors.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(colors.primary.opacity(0.10), in: Capsule())
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.fontSecondary)
                    .frame(width: 24, height: 24)
                    .background(colors.fontTertiary.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: 表单

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldRow(Localizer.tr("theme_selector_modal__theme_name")) {
                TextField(Localizer.tr("theme_selector_modal__theme_name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 260)
            }

            fieldRow("基础主题") {
                if !isNew {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(colors.fontTertiary)
                        Text("基础主题：\(editingBaseThemeName)")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.font)
                            .lineLimit(1)
                        Text("（不可更改）")
                            .font(.system(size: 9.5))
                            .foregroundStyle(colors.fontTertiary)
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                } else {
                Menu {
                    ForEach(app.allThemes) { theme in
                        Button {
                            guard isNew else { return }
                            baseID = theme.id
                            loadValues(from: theme)
                        } label: {
                            if theme.id == baseID {
                                Label(themeDisplayName(theme), systemImage: "checkmark")
                            } else {
                                Text(themeDisplayName(theme))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(themeDisplayName(baseTheme))
                            .font(.system(size: 12))
                            .foregroundStyle(colors.font)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(colors.fontTertiary)
                    }
                    .frame(width: 228, height: 22)
                    .padding(.horizontal, 8)
                    .background(colors.fontTertiary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                }
            }

            fieldRow("明暗") {
                Toggle("深色主题", isOn: $isDark)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11))
                Toggle(Localizer.tr("theme_edit_modal__dark_font"), isOn: $isDarkFont)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Text("影响配色预览与状态栏/歌词文字反色策略")
                    .font(.system(size: 9.5))
                    .foregroundStyle(colors.fontTertiary)
            }

            if let errorText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                    Text(errorText)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Divider().overlay(colors.border)

            Text("关键颜色变量")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colors.font)
            Text("编辑常用变量；其余派生变量（-alpha-* / -dark-* / -light-*）沿用基础主题。支持 #rgb / #rrggbb / rgb() / rgba()。")
                .font(.system(size: 9.5))
                .foregroundStyle(colors.fontTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ThemeColorField.groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(colors.fontTertiary)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                        ForEach(ThemeColorField.all.filter { $0.group == group }) { field in
                            colorRow(field)
                        }
                    }
                }
            }
        }
    }

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(colors.fontSecondary)
                .frame(width: 64, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func colorRow(_ field: ThemeColorField) -> some View {
        HStack(spacing: 8) {
            ColorPicker("", selection: colorBinding(for: field.key), supportsOpacity: true)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 46, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(field.label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(colors.fontSecondary)
                TextField("#rrggbb", text: hexBinding(for: field.key))
                    .textFieldStyle(.plain)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(colors.fontTertiary)
                    .lineLimit(1)
                    .onSubmit {
                        if let rgba = RGBAColor(css: values[field.key] ?? "") {
                            values[field.key] = Self.cssString(from: rgba)
                        }
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(colors.fontTertiary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: 预览

    private var previewValues: [String: String] {
        var vars = ThemePreview.variables(baseTheme)
        for (key, value) in values {
            vars[key] = value
        }
        return vars
    }

    private func previewColor(_ key: String, fallback: Color) -> Color {
        guard let css = Self.resolveCSS(key, variables: previewValues) else { return fallback }
        return RGBAColor(css: css)?.color ?? fallback
    }

    private var previewPrimary: Color { previewColor("--color-primary", fallback: colors.primary) }
    private var previewSecondary: Color { previewColor("--color-badge-secondary", fallback: colors.badgeSecondary) }
    private var previewTertiary: Color { previewColor("--color-badge-tertiary", fallback: colors.badgeTertiary) }
    private var previewBackground: Color {
        if let css = Self.resolveCSS("--color-main-background", variables: previewValues),
           let rgba = RGBAColor(css: css) {
            return rgba.color
        }
        return previewColor("--color-app-background", fallback: isDark ? Color(white: 0.09) : .white)
    }
    private var previewFont: Color {
        previewColor("--color-1000", fallback: isDark ? Color(white: 0.9) : Color(white: 0.13))
    }
    private var previewBorder: Color {
        previewColor("--color-200", fallback: previewFont.opacity(0.15))
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("实时预览")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colors.font)
            Text("保存并应用后，主窗口/侧边栏/播放条会使用该配色；预览为关键变量合成效果。")
                .font(.system(size: 9.5))
                .foregroundStyle(colors.fontTertiary)
                .fixedSize(horizontal: false, vertical: true)

            colorSwatches
            sampleCard
        }
    }

    private var colorSwatches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("色块")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(colors.fontTertiary)
            HStack(spacing: 8) {
                swatch("主色", previewPrimary)
                swatch("背景", previewBackground)
                swatch("文字", previewFont)
                swatch("边框", previewBorder)
                swatch("徽标", previewSecondary)
                swatch("强调", previewTertiary)
            }
        }
    }

    private func swatch(_ label: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .frame(height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(colors.border, lineWidth: 1)
                )
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(colors.fontTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private var sampleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("小样例卡片")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(colors.fontTertiary)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(previewPrimary)
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(previewBackground)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("示例歌曲名")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(previewFont)
                        Text("示例歌手 · 示例专辑")
                            .font(.system(size: 9.5))
                            .foregroundStyle(previewFont.opacity(0.62))
                    }
                    Spacer()
                    Text("04:00")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(previewFont.opacity(0.5))
                }

                HStack(spacing: 5) {
                    pill("128K", color: previewSecondary, filled: false)
                    pill("无损", color: previewTertiary, filled: false)
                    Spacer()
                    Label("已收藏", systemImage: "heart.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(previewPrimary)
                }

                ZStack(alignment: .leading) {
                    Capsule().fill(previewBorder.opacity(0.35))
                    Capsule().fill(previewPrimary).frame(width: 120)
                }
                .frame(height: 4)

                HStack(spacing: 8) {
                    Text(Localizer.tr("list__play"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(previewBackground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(previewPrimary, in: Capsule())
                    Text("添加到列表")
                        .font(.system(size: 10))
                        .foregroundStyle(previewFont.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(previewFont.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(previewBorder.opacity(0.5), lineWidth: 1))
                    Spacer()
                }

                HStack(spacing: 6) {
                    Circle().fill(previewPrimary).frame(width: 5, height: 5)
                    Text("被选中的歌曲行（主题主色高亮）")
                        .font(.system(size: 9.5))
                        .foregroundStyle(previewPrimary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(previewPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                HStack(spacing: 6) {
                    ForEach(["--color-btn-hide", "--color-btn-min", "--color-btn-close"], id: \.self) { key in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(previewColor(key, fallback: previewPrimary))
                            .frame(width: 18, height: 18)
                    }
                    Text("按钮 / 状态色")
                        .font(.system(size: 9))
                        .foregroundStyle(previewFont.opacity(0.5))
                    Spacer()
                }
            }
            .padding(12)
            .background(previewBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(previewBorder.opacity(0.6), lineWidth: 1)
            )
            .environment(\.colorScheme, isDark ? .dark : .light)
        }
    }

    private func pill(_ text: String, color: Color, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                importThemeJSON()
            } label: {
                Label("导入 JSON…", systemImage: "square.and.arrow.down")
                    .font(.system(size: 10.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                exportThemeJSON()
            } label: {
                Label("导出 JSON…", systemImage: "square.and.arrow.up")
                    .font(.system(size: 10.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if editing != nil {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除主题", systemImage: "trash")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            if editing != nil {
                Button("复制为新主题") {
                    copyAsNew()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(Localizer.tr("btn_cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)

            Button(action: save) {
                Text(isNew ? "创建并应用" : "保存并应用")
                    .frame(minWidth: 78)
            }
            .buttonStyle(.borderedProminent)
            .tint(colors.primary)
            .controlSize(.small)
            .disabled(!canSave)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: 动作

    private func loadValues(from theme: Theme) {
        let variables = ThemePreview.variables(theme)
        var next: [String: String] = [:]
        for field in ThemeColorField.all {
            next[field.key] = Self.normalizeCSS(Self.resolveCSS(field.key, variables: variables))
        }
        values = next
        isDark = theme.isDark
        isDarkFont = theme.isDarkFont
    }

    private func copyAsNew() {
        guard let editing else { return }
        baseID = editing.id
        self.editing = nil
        name = "\(editing.name) 副本"
    }

    private func save() {
        errorText = nil
        guard canSave else { return }
        if let editing {
            var updated = editing
            updated.name = trimmedName
            updated.isDark = isDark
            updated.isDarkFont = isDarkFont
            apply(values: values, to: &updated, reference: editing)
            guard app.saveUserTheme(updated) else {
                errorText = "保存失败，请查看提示"
                return
            }
            app.setTheme(id: updated.id)
            dismiss()
        } else {
            guard let createdBase = app.createUserTheme(name: trimmedName, baseThemeID: baseID, overrides: [:]) else {
                errorText = "创建失败：基础主题不存在"
                return
            }
            var updated = createdBase
            updated.name = trimmedName
            updated.isDark = isDark
            updated.isDarkFont = isDarkFont
            apply(values: values, to: &updated, reference: baseTheme)
            guard app.saveUserTheme(updated) else {
                errorText = "保存失败，请查看提示"
                return
            }
            app.setTheme(id: updated.id)
            dismiss()
        }
    }

    private func apply(values: [String: String], to theme: inout Theme, reference: Theme) {
        for (key, value) in values {
            if reference.config.extInfo[key] != nil {
                theme.config.extInfo[key] = value
            } else if reference.config.themeColors[key] != nil {
                theme.config.themeColors[key] = value
            } else if key.hasPrefix("--color") {
                theme.config.themeColors[key] = value
            } else {
                theme.config.extInfo[key] = value
            }
        }
    }

    private func importThemeJSON() {
        let panel = NSOpenPanel()
        panel.title = "导入主题 JSON"
        panel.message = "选择原版格式的主题 JSON 文件（单个 Theme 对象）"
        panel.prompt = Localizer.tr("import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .text]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            errorText = "读取文件失败"
            return
        }
        guard let imported = app.importThemeJSON(text) else {
            errorText = app.toastMessage ?? "导入失败"
            return
        }
        editing = imported
        name = imported.name
        baseID = imported.id
        isDark = imported.isDark
        isDarkFont = imported.isDarkFont
        loadValues(from: imported)
        app.setTheme(id: imported.id)
    }

    private func exportThemeJSON() {
        let panel = NSSavePanel()
        panel.title = "导出主题 JSON"
        panel.prompt = Localizer.tr("export")
        panel.nameFieldStringValue = "\(trimmedName.isEmpty ? "theme" : trimmedName).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var draft = editing ?? app.currentTheme
        draft = Theme(
            id: editing?.id ?? "custom_export_\(Int(Date().timeIntervalSince1970))",
            name: trimmedName.isEmpty ? "未命名主题" : trimmedName,
            isDark: isDark,
            isDarkFont: isDarkFont,
            isCustom: true,
            config: draft.config
        )
        apply(values: values, to: &draft, reference: baseTheme)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(draft),
              let text = String(data: data, encoding: .utf8) else {
            errorText = "主题序列化失败"
            return
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            app.showToast("已导出主题 JSON：\(url.lastPathComponent)")
        } catch {
            errorText = "写入文件失败：\(error.localizedDescription)"
        }
    }

    // MARK: 颜色工具

    private func colorBinding(for key: String) -> Binding<Color> {
        Binding(
            get: { Self.colorValue(values[key]) ?? .gray },
            set: { values[key] = Self.cssString(from: $0) }
        )
    }

    private func hexBinding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    private static func resolveCSS(_ key: String, variables: [String: String], depth: Int = 0) -> String? {
        guard depth < 10, let raw = variables[key] else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("var(") {
            var inner = String(value.dropFirst(4))
            if inner.hasSuffix(")") { inner = String(inner.dropLast()) }
            return resolveCSS(inner.trimmingCharacters(in: .whitespaces), variables: variables, depth: depth + 1)
        }
        return value
    }

    private static func normalizeCSS(_ css: String?) -> String {
        guard let css, let rgba = RGBAColor(css: css) else { return css ?? "#808080" }
        return cssString(from: rgba)
    }

    private static func colorValue(_ css: String?) -> Color? {
        guard let css else { return nil }
        return RGBAColor(css: css)?.color
    }

    private static func cssString(from color: Color) -> String {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return "#808080" }
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        let a = ns.alphaComponent
        if a >= 0.999 {
            return String(format: "#%02x%02x%02x", r, g, b)
        }
        return String(format: "rgba(%d, %d, %d, %.2f)", r, g, b, a)
    }

    private static func cssString(from rgba: RGBAColor) -> String {
        if rgba.a >= 0.999 {
            return String(format: "#%02x%02x%02x", Int(rgba.r.rounded()), Int(rgba.g.rounded()), Int(rgba.b.rounded()))
        }
        return String(format: "rgba(%d, %d, %d, %.2f)", Int(rgba.r.rounded()), Int(rgba.g.rounded()), Int(rgba.b.rounded()), rgba.a)
    }
}
