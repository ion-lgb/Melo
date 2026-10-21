import Foundation
import CoreAudio

/// 一个可用的音频输出设备（CoreAudio）。
public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    /// 设备稳定标识（CoreAudio `kAudioDevicePropertyDeviceUID`，可持久化到设置）。
    public var id: String { uid }
    public let uid: String
    public let name: String
    public let isDefault: Bool
    /// CoreAudio 设备对象 ID（运行时有效，不用于持久化）。
    public let deviceID: AudioDeviceID

    public init(uid: String, name: String, isDefault: Bool, deviceID: AudioDeviceID) {
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
        self.deviceID = deviceID
    }
}

/// 输出设备相关错误（可读中文，供 UI Toast / 日志）。
public enum AudioOutputDeviceError: LocalizedError, Equatable, Sendable {
    case notFound(String)
    case notOutputDevice(String)
    case switchFailed(String)
    case noOutputUnit

    public var errorDescription: String? {
        switch self {
        case .notFound(let uid):
            return "输出设备不存在：\(uid)"
        case .notOutputDevice(let uid):
            return "该设备不是音频输出设备：\(uid)"
        case .switchFailed(let detail):
            return "切换输出设备失败：\(detail)"
        case .noOutputUnit:
            return "当前音频引擎没有可用的输出单元"
        }
    }
}

/// CoreAudio 输出设备枚举 / 查询 / 切换。
///
/// 全部查询失败都返回 `[]` / `nil`，不抛错、不崩溃（headless CI 也可安全调用）。
public enum AudioOutputDevices {

    // MARK: - 查询

    /// 枚举系统输出设备（有输出声道、UID 有效的设备），默认设备排在最前。
    public static func list() -> [AudioOutputDevice] {
        let defaultID = defaultAudioDeviceID()
        let devices: [AudioOutputDevice] = allDeviceIDs().compactMap { deviceID in
            guard hasOutputChannels(deviceID),
                  let uid = deviceUID(deviceID), !uid.isEmpty else { return nil }
            let name = deviceName(deviceID) ?? uid
            return AudioOutputDevice(
                uid: uid,
                name: name,
                isDefault: deviceID == defaultID,
                deviceID: deviceID
            )
        }
        return devices.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 系统默认输出设备的 UID（无默认设备时 nil）。
    public static func defaultDeviceID() -> String? {
        guard let deviceID = defaultAudioDeviceID() else { return nil }
        return deviceUID(deviceID)
    }

    /// 默认输出设备（名称为空时回退 UID）。
    public static func defaultDevice() -> AudioOutputDevice? {
        guard let deviceID = defaultAudioDeviceID(),
              let uid = deviceUID(deviceID) else { return nil }
        return AudioOutputDevice(
            uid: uid,
            name: deviceName(deviceID) ?? uid,
            isDefault: true,
            deviceID: deviceID
        )
    }

    /// 设备 UID → CoreAudio `AudioDeviceID`；找不到返回 nil。
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let device = list().first(where: { $0.uid == trimmed }) {
            return device.deviceID
        }
        // 兜底：在全部设备里再找一次（可能被输出声道过滤掉，调用方自行判断）
        for deviceID in allDeviceIDs() where deviceUID(deviceID) == trimmed {
            return deviceID
        }
        return nil
    }

    // MARK: - 内部（供引擎/路由使用）

    /// 默认输出设备的 CoreAudio ID。
    static func defaultAudioDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    /// 输出设备（有输出声道）查询。
    static func outputDevice(forUID uid: String) -> AudioOutputDevice? {
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return list().first { $0.uid == trimmed }
    }

    // MARK: - CoreAudio property helpers

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        return deviceIDs
    }

    private static func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.contains { $0.mNumberChannels > 0 }
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    /// 读取 CFString 类型属性（UID / 名称）。
    private static func stringProperty(_ objectID: AudioObjectID,
                                       selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let unmanaged = value else { return nil }
        return unmanaged.takeRetainedValue() as String
    }
}
