import Foundation
import MeloCore

/// MeloCore ↔ CoreAudio 输出设备桥接：让 UI/AppModel 只依赖 MeloCore 的模型。
extension RoutedPlayerService: AudioOutputDeviceSelecting {
    public func availableOutputDevices() -> [AudioOutputDeviceInfo] {
        AudioOutputDevices.list().map {
            AudioOutputDeviceInfo(id: $0.uid, name: $0.name, isDefault: $0.isDefault)
        }
    }

    public func currentOutputDeviceUID() -> String? {
        effectsPlayer.outputDeviceUID
    }

    public func applyOutputDevice(uid: String?) throws {
        try effectsPlayer.setOutputDevice(uid: uid)
        applyOutputDeviceSetting()
    }
}


extension RoutedPlayerService: AudioVisualizationRouting {
    // applyVisualizationSetting() 已在 RoutedPlayerService 中实现
}
