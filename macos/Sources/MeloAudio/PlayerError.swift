import Foundation
import AVFoundation

/// 音频层错误。全部提供可读中文描述（`localizedDescription`），供 UI Toast 直接展示。
public enum PlayerError: LocalizedError, Equatable, Sendable {
    /// URL 本身非法（无 scheme / 空 host 等）
    case invalidURL(String)
    /// 不支持的协议（仅支持 http/https/file）
    case unsupportedScheme(String)
    /// 本地文件不存在
    case fileNotFound(String)
    /// 其他播放错误（含 AVFoundation 的底层错误）
    case playbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "无效的播放地址：\(value)"
        case .unsupportedScheme(let scheme):
            return "不支持的播放协议：\(scheme)（仅支持 http、https、file）"
        case .fileNotFound(let path):
            return "本地音频文件不存在：\(path)"
        case .playbackFailed(let message):
            return message
        }
    }

    /// 把 AVFoundation / NSError 转成可读中文（用于异步 `.error` 事件）。
    ///
    /// 注意：返回值不带「播放失败：」前缀，由上层（AppModel）统一加「播放出错：」前缀。
    public static func describe(_ error: Error?) -> String {
        guard let error else { return "未知播放错误" }
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain,
           let code = AVError.Code(rawValue: nsError.code) {
            return "\(hint(for: code))（\(nsError.localizedDescription)）"
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return "\(nsError.localizedDescription)（\(underlying.localizedDescription)）"
        }
        return nsError.localizedDescription
    }

    /// 常见 AVFoundation 错误码的中文解释。
    private static func hint(for code: AVError.Code) -> String {
        switch code {
        case .fileFormatNotRecognized:
            return "音频格式不受支持或文件已损坏"
        case .fileFailedToParse, .failedToParse:
            return "音频数据解析失败"
        case .decoderNotFound, .decoderTemporarilyUnavailable:
            return "系统缺少可用的音频解码器"
        case .noSourceTrack:
            return "文件中没有可播放的音轨"
        case .unsupportedOutputSettings, .formatUnsupported:
            return "音频格式或输出设置不受支持"
        case .contentIsProtected:
            return "音频受版权保护，无法播放"
        case .noLongerPlayable:
            return "音频地址已失效，无法继续播放"
        case .contentIsUnavailable:
            return "音频内容当前不可用"
        case .invalidSourceMedia, .incompatibleAsset:
            return "音频源无效或与系统不兼容"
        case .failedToLoadMediaData, .undecodableMediaData:
            return "音频数据加载或解码失败"
        case .outOfMemory:
            return "内存不足"
        case .unknown:
            return "未知错误"
        default:
            return "播放错误（AVFoundation 错误码 \(code.rawValue)）"
        }
    }
}
