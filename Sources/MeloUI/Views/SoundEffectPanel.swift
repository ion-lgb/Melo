import SwiftUI
import AppKit
import MeloCore

// MARK: - 跨视图打开音效面板

public extension Notification.Name {
    /// 从设置页等处请求打开播放条的音效面板（由 PlayerBar 监听并弹出 sheet）
    static let meloShowSoundEffectPanel = Notification.Name("MeloShowSoundEffectPanel")
}

// MARK: - 原版 EQ 预设（移植自 src/renderer/plugins/player/index.ts freqsPreset）

struct EQPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let bands: [Double]

    static let builtins: [EQPreset] = [
        EQPreset(id: "pop", name: Localizer.tr("player__sound_effect_biquad_filter_preset_pop"), bands: [6, 5, -3, -2, 5, 4, -4, -3, 6, 4]),
        EQPreset(id: "dance", name: Localizer.tr("player__sound_effect_biquad_filter_preset_dance"), bands: [4, 3, -4, -6, 0, 0, 3, 4, 4, 5]),
        EQPreset(id: "rock", name: Localizer.tr("player__sound_effect_biquad_filter_preset_rock"), bands: [7, 6, 2, 1, -3, -4, 2, 1, 4, 5]),
        EQPreset(id: "classical", name: Localizer.tr("player__sound_effect_biquad_filter_preset_classical"), bands: [6, 7, 1, 2, -1, 1, -4, -6, -7, -8]),
        EQPreset(id: "vocal", name: Localizer.tr("player__sound_effect_biquad_filter_preset_vocal"), bands: [-5, -6, -4, -3, 3, 4, 5, 4, -3, -3]),
        EQPreset(id: "slow", name: Localizer.tr("player__sound_effect_biquad_filter_preset_slow"), bands: [5, 4, 2, 0, -2, 0, 3, 6, 7, 8]),
        EQPreset(id: "electronic", name: Localizer.tr("player__sound_effect_biquad_filter_preset_electronic"), bands: [6, 5, 0, -5, -4, 0, 6, 8, 8, 7]),
        EQPreset(id: "subwoofer", name: Localizer.tr("player__sound_effect_biquad_filter_preset_subwoofer"), bands: [8, 7, 5, 4, 0, 0, 0, 0, 0, 0]),
        EQPreset(id: "soft", name: Localizer.tr("player__sound_effect_biquad_filter_preset_soft"), bands: [-5, -5, -4, -4, 3, 2, 4, 4, 0, 0]),
    ]

    static func matching(_ bands: [Double]) -> EQPreset? {
        builtins.first { preset in
            zip(preset.bands, bands).allSatisfy { abs($0 - $1) < 0.01 }
        }
    }
}

// MARK: - 音效面板（10 段 EQ + 变速变调）

struct SoundEffectPanel: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @Environment(\.dismiss) private var dismiss

    private var effects: AudioEffectSettings { app.audioEffects }
    private var bands: [Double] { effects.eqBands }
    private var shifterRate: Double { app.pitchShifterRate }
    private var semitones: Double { shifterRate > 0 ? 12 * log2(shifterRate) : 0 }

    /// 音效层是否真的启用（不含播放条倍速；倍速是另一套机制）
    private var soundEffectActive: Bool {
        effects.isEQActive || abs(shifterRate - 1) > 0.005 || effects.isConvolutionActive || effects.pannerEnabled
    }

    private var currentPreset: EQPreset? { EQPreset.matching(bands) }

    private var presetName: String {
        if let currentPreset { return currentPreset.name }
        return effects.isEQActive ? "自定义" : "全平（无增益）"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: MeloMetrics.gridSpacing) {
                    eqSection
                    pitchSection
                    convolutionSection
                    pannerSection
                }
                .padding(MeloMetrics.pageInset)
            }
            Divider().overlay(colors.border)
            footer
        }
        .frame(width: 800, height: 880)
        .presentationBackground(.regularMaterial)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous)
                    .fill(colors.primaryOpacity(0.12))
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(colors.primary)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("音效")
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                Text("均衡器 / 变速变调 · 会写入原版 player.soundEffect.* 设置并立即生效")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontSecondary)
            }

            Spacer()

            statusBadge

            MeloCircleIconButton(systemName: "xmark", help: Localizer.tr("close"), size: 12, frameSize: 28) {
                dismiss()
            }
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.vertical, 14)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(soundEffectActive ? colors.primary : colors.fontTertiary)
                .frame(width: 7, height: 7)
            Text(soundEffectActive ? "音效引擎已启用" : "当前无音效 · 普通引擎")
                .font(MeloFont.controlLabel)
                .foregroundStyle(soundEffectActive ? colors.primary : colors.fontSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(colors.chipFill, in: Capsule())
    }

    // MARK: 均衡器

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.primary)
                Text(Localizer.tr("player__sound_effect_biquad_filter"))
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                Text("10 段 · 单位 dB")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontSecondary)
                Text("±15")
                    .font(MeloFont.microCaption.monospacedDigit())
                    .foregroundStyle(colors.fontTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(colors.chipFill, in: Capsule())

                Spacer()

                Menu {
                    ForEach(EQPreset.builtins) { preset in
                        Button {
                            app.applyEQPreset(preset.bands)
                        } label: {
                            if currentPreset?.id == preset.id {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                    Divider()
                    Button("重置（全平）") { app.resetEQ() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                        Text(presetName)
                            .font(MeloFont.controlLabel)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(colors.font)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(colors.chipFill, in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("原版 EQ 预设")

                Button(Localizer.tr("lyric_menu__size_reset")) { app.resetEQ() }
                    .buttonStyle(.meloSecondary)
                    .disabled(!effects.isEQActive)
            }

            HStack(alignment: .top, spacing: 0) {
                ForEach(0..<10, id: \.self) { index in
                    bandColumn(index)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)

            if !effects.isEQActive {
                Text("均衡器当前全平；拖动滑块或选择预设后进入音效播放引擎。")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontSecondary)
            }
        }
        .padding(MeloMetrics.pageInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func bandColumn(_ index: Int) -> some View {
        let gain = bands.indices.contains(index) ? bands[index] : 0
        return VStack(spacing: 7) {
            VerticalEQSlider(value: gain) { newValue in
                app.setEQBand(index, gain: newValue)
            }
            .frame(height: 170)

            Text(SettingKeys.eqFrequencyLabels[safe: index] ?? "")
                .font(MeloFont.controlLabel)
                .foregroundStyle(colors.fontSecondary)

            Text(gain == 0 ? "0" : String(format: "%+.0f", gain))
                .font(MeloFont.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(gain == 0 ? colors.fontTertiary : colors.primary)
                .frame(height: 14)
        }
    }

    // MARK: 变速变调

    private var pitchSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "tuningfork")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.primary)
                Text("变速变调")
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                Text("pitch shifter · 0.5x – 1.5x")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontSecondary)
                Spacer()
                Button(Localizer.tr("lyric_menu__size_reset")) { app.setPitchShifterRate(1) }
                    .buttonStyle(.meloSecondary)
                    .disabled(abs(shifterRate - 1) < 0.005)
            }

            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { shifterRate },
                        set: { app.setPitchShifterRate($0) }
                    ),
                    in: 0.5...1.5,
                    step: 0.05
                )
                .controlSize(.small)
                .tint(colors.primary)

                HStack(spacing: 8) {
                    Text(String(format: "%.2fx", shifterRate))
                        .font(MeloFont.controlLabel.monospacedDigit())
                        .foregroundStyle(colors.font)
                    Text(semitoneText)
                        .font(MeloFont.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(abs(semitones) < 0.05 ? colors.fontTertiary : colors.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (colors.primary).opacity(abs(semitones) < 0.05 ? 0 : 0.10),
                            in: Capsule()
                        )
                }
                .frame(width: 170, alignment: .leading)
            }

            whySeparateNote
        }
        .padding(MeloMetrics.pageInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var semitoneText: String {
        if abs(semitones) < 0.05 { return "±0 半音" }
        return String(format: "%+.1f 半音", semitones)
    }

    /// 播放条倍速（player.playbackRate）与音效层升降调（pitch shifter）是两套机制
    private var whySeparateNote: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.fontTertiary)
                Text("这是音效层的升降调（pitch shifter），与播放条上的「倍速」是两套机制")
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.fontSecondary)
            }
            Text("倍速只改变播放速度并保持音调；升降调通过实时 DSP 处理改变音高。升降调会增加 CPU 占用，CPU 不足时可能出现声音异常，可暂停片刻等待处理完成。")
                .font(MeloFont.caption)
                .foregroundStyle(colors.fontTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 环境混响（卷积混响）

    private var convolutionPreset: ConvolutionPreset? {
        guard let fileName = effects.convolutionFileName else { return nil }
        return app.convolutionPresets.first { $0.fileName == fileName }
    }

    /// 原版设置值 0–50（实际增益 = /10）
    private var rawMainGain: Double {
        min(max(effects.convolutionMainGain * 10, 0), 50)
    }

    private var rawSendGain: Double {
        min(max(effects.convolutionSendGain * 10, 0), 50)
    }

    private var convolutionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.primary)
                Text("环境混响")
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                Text("卷积混响 · 内置脉冲响应")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontSecondary)
                if effects.isConvolutionActive, let preset = convolutionPreset {
                    MeloBadge(preset.name, color: colors.primary)
                }
                Spacer()
                if effects.isConvolutionActive {
                    Button(Localizer.tr("close")) { app.setConvolutionFileName(nil) }
                        .buttonStyle(.meloSecondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    MeloChip(text: Localizer.tr("close"), isSelected: !effects.isConvolutionActive) {
                        app.setConvolutionFileName(nil)
                    }
                    ForEach(app.convolutionPresets) { preset in
                        MeloChip(text: preset.name, isSelected: preset.fileName == effects.convolutionFileName) {
                            app.applyConvolutionPreset(preset)
                        }
                    }
                }
                .padding(.vertical, 1)
            }

            HStack(spacing: 10) {
                Text("主增益")
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.fontSecondary)
                    .frame(width: 52, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { rawMainGain },
                        set: { app.setConvolutionGains(main: $0.rounded(), send: rawSendGain) }
                    ),
                    in: 0...50
                )
                .controlSize(.small)
                .tint(colors.primary)
                .frame(width: 150)
                Text(String(format: "%.0f%%", rawMainGain * 10))
                    .font(MeloFont.caption.monospacedDigit())
                    .foregroundStyle(colors.font)
                    .frame(width: 48, alignment: .trailing)

                Text("发送增益")
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.fontSecondary)
                    .frame(width: 60, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { rawSendGain },
                        set: { app.setConvolutionGains(main: rawMainGain, send: $0.rounded()) }
                    ),
                    in: 0...50
                )
                .controlSize(.small)
                .tint(colors.primary)
                .frame(width: 150)
                Text(String(format: "%.0f%%", rawSendGain * 10))
                    .font(MeloFont.caption.monospacedDigit())
                    .foregroundStyle(colors.font)
                    .frame(width: 48, alignment: .trailing)
                Spacer(minLength: 0)
            }
            .disabled(!effects.isConvolutionActive)
            .opacity(effects.isConvolutionActive ? 1 : 0.45)

            Text("100% = 原始 1.0 倍增益；首次应用卷积混响需要处理音频，可能有短暂加载。")
                .font(MeloFont.caption)
                .foregroundStyle(colors.fontTertiary)
        }
        .padding(MeloMetrics.pageInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: 3D 立体环绕（声像）

    private var pannerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "person.wave.2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.primary)
                Text("3D 立体环绕")
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                Text("声像旋转 · 需使用耳机")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontSecondary)
                if app.pannerEnabled {
                    MeloBadge("已启用", color: colors.primary)
                }
                Spacer()
                Toggle(Localizer.tr("setting__is_enable"), isOn: Binding(
                    get: { app.pannerEnabled },
                    set: { app.setPanner(enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(colors.primary)
                .font(MeloFont.controlLabel)
            }

            HStack(spacing: 10) {
                Text(Localizer.tr("player__sound_effect_panner_sound_speed"))
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.fontSecondary)
                    .frame(width: 52, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(app.pannerSpeed) },
                        set: { app.setPanner(speed: Int($0.rounded())) }
                    ),
                    in: 1...50
                )
                .controlSize(.small)
                .tint(colors.primary)
                .frame(width: 180)
                Text("\(app.pannerSpeed)")
                    .font(MeloFont.caption.monospacedDigit())
                    .foregroundStyle(colors.font)
                    .frame(width: 30, alignment: .leading)

                Text(Localizer.tr("player__sound_effect_panner_sound_r"))
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.fontSecondary)
                    .frame(width: 60, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(app.pannerSoundR) },
                        set: { app.setPanner(soundR: Int($0.rounded())) }
                    ),
                    in: 1...30
                )
                .controlSize(.small)
                .tint(colors.primary)
                .frame(width: 150)
                Text("\(app.pannerSoundR)")
                    .font(MeloFont.caption.monospacedDigit())
                    .foregroundStyle(colors.font)
                    .frame(width: 30, alignment: .leading)
                Spacer(minLength: 0)
            }
            .disabled(!app.pannerEnabled)
            .opacity(app.pannerEnabled ? 1 : 0.45)

            Text("启用后声音会绕头部旋转（与原版 3D 环绕一致），建议佩戴耳机；未启用时普通立体声输出。")
                .font(MeloFont.caption)
                .foregroundStyle(colors.fontTertiary)
        }
        .padding(MeloMetrics.pageInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.badgeTertiary)
                    .padding(.top, 1)
                Text("有音效时会切换到音效播放引擎，首次播放需要先缓存音频，可能短暂加载；音效设置与原版「自定义音频输出设备」存在冲突时，输出设备会被重置为默认设备。")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("全部重置") {
                    app.resetEQ()
                    app.setPitchShifterRate(1)
                    app.setConvolutionFileName(nil)
                    app.setPanner(enabled: false)
                }
                .buttonStyle(.meloSecondary)

                Button("完成") { dismiss() }
                    .buttonStyle(.meloPrimary)
            }
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.vertical, 14)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: MeloMetrics.cardRadius, style: .continuous)
            .fill(colors.cardFill)
            .shadow(color: colors.cardShadow, radius: 6, x: 0, y: 2)
    }
}

// MARK: - 竖向 EQ 滑块（中心 0 dB，-15…+15，步进 1）

private struct VerticalEQSlider: View {
    let value: Double
    let onCommit: (Double) -> Void

    @Environment(\.meloColors) private var colors

    private let knobRadius: CGFloat = 6.5

    var body: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, 1)
            let centerX = proxy.size.width / 2
            let usable = max(height - knobRadius * 2, 1)
            let zeroY = knobRadius + usable / 2
            let knobY = knobRadius + usable * (15 - value) / 30

            ZStack {
                Capsule()
                    .fill(colors.chipFill)
                    .frame(width: 5, height: usable)
                    .position(x: centerX, y: height / 2)

                Rectangle()
                    .fill(colors.border)
                    .frame(width: 13, height: 1)
                    .position(x: centerX, y: zeroY)

                Capsule()
                    .fill(colors.primary)
                    .frame(width: 5, height: max(abs(knobY - zeroY), 0))
                    .position(x: centerX, y: (knobY + zeroY) / 2)

                Circle()
                    .fill(colors.cardFill)
                    .overlay(Circle().strokeBorder(colors.primary, lineWidth: 2))
                    .frame(width: knobRadius * 2, height: knobRadius * 2)
                    .shadow(color: colors.cardShadow, radius: 2, x: 0, y: 1)
                    .position(x: centerX, y: knobY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let ratio = 1 - min(max((gesture.location.y - knobRadius) / usable, 0), 1)
                        let raw = -15 + ratio * 30
                        let stepped = raw.rounded()
                        if abs(stepped - value) > 0.001 {
                            onCommit(stepped)
                        }
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    if abs(value) > 0.001 { onCommit(0) }
                }
            )
        }
        .frame(width: 26)
        .help("双击恢复 0 dB")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
