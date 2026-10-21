import Foundation
import Compression

/// zlib（RFC1950）容器编解码：用于两块场景
/// 1. 原版 `user_api.json` 的 `gz_<base64(zlib deflate)>` 脚本存储；
/// 2. 自定义源脚本可用的 `lx.utils.zlib.inflate/deflate`。
///
/// Apple Compression 框架的 `COMPRESSION_ZLIB` 实际是 **raw DEFLATE**，
/// 因此这里自行补/剥 2 字节 zlib 头与 4 字节 Adler-32 尾巴（Big Endian）。
enum ZlibCodec {

    enum ZlibError: Error, LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    // MARK: - 公共入口

    /// Node `zlib.deflate` 兼容输出（zlib 容器）
    static func deflate(_ data: [UInt8]) -> [UInt8]? {
        guard !data.isEmpty else { return nil }
        guard let raw = encodeRaw(data) else { return nil }
        if isZlibWrapped(raw) { return raw }
        var out: [UInt8] = [0x78, 0x9C]
        out.append(contentsOf: raw)
        out.append(contentsOf: adler32(data).bigEndianBytes)
        return out
    }

    /// Node `zlib.inflate` 兼容输入（zlib 容器；也容忍 raw DEFLATE）
    static func inflate(_ data: [UInt8]) -> [UInt8]? {
        guard !data.isEmpty else { return [] }
        if isZlibWrapped(data), data.count > 6 {
            let raw = Array(data[2..<(data.count - 4)])
            if let out = decodeRaw(raw) { return out }
        }
        return decodeRaw(data)
    }

    /// raw DEFLATE（无 zlib 头/尾），供 gzip/Network 兜底解压使用
    static func inflateRaw(_ data: [UInt8]) -> [UInt8]? {
        decodeRaw(data)
    }

    /// 原版脚本压缩格式：`gz_` + base64(zlib deflate)
    static func compressScript(_ script: String) -> String? {
        let bytes = Array(script.utf8)
        if bytes.isEmpty { return nil }
        guard let compressed = deflate(bytes) else { return nil }
        return "gz_" + Data(compressed).base64EncodedString()
    }

    /// 兼容读取：`gz_` 前缀解压；无前缀视为明文脚本（原版 inflateScript 行为）
    static func decompressScript(_ stored: String) -> String? {
        guard stored.hasPrefix("gz_") else { return stored }
        guard let data = Data(base64Encoded: String(stored.dropFirst(3))) else { return nil }
        guard let plain = inflate([UInt8](data)) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }

    // MARK: - Adler-32

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    // MARK: - Compression 框架

    private static func decodeRaw(_ data: [UInt8]) -> [UInt8]? {
        guard !data.isEmpty else { return [] }
        var capacity = max(64 * 1024, data.count * 32)
        let cap = 64 * 1024 * 1024
        while capacity <= cap {
            var dst = [UInt8](repeating: 0, count: capacity)
            let written = data.withUnsafeBufferPointer { source in
                dst.withUnsafeMutableBufferPointer { destination in
                    compression_decode_buffer(
                        destination.baseAddress!, capacity,
                        source.baseAddress!, data.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0 { return Array(dst[0..<written]) }
            capacity *= 4
        }
        return nil
    }

    private static func encodeRaw(_ data: [UInt8]) -> [UInt8]? {
        var capacity = max(64 * 1024, data.count + 1024)
        let cap = 64 * 1024 * 1024
        while capacity <= cap {
            var dst = [UInt8](repeating: 0, count: capacity)
            let written = data.withUnsafeBufferPointer { source in
                dst.withUnsafeMutableBufferPointer { destination in
                    compression_encode_buffer(
                        destination.baseAddress!, capacity,
                        source.baseAddress!, data.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0 { return Array(dst[0..<written]) }
            capacity *= 4
        }
        return nil
    }

    private static func isZlibWrapped(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        let header = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return (bytes[0] & 0x0F) == 8 && header % 31 == 0
    }
}

extension UInt32 {
    /// RFC1950 Adler-32 尾巴（Big Endian；注意不能用 `.bigEndian` 属性本身）
    var bigEndianBytes: [UInt8] {
        [UInt8(truncatingIfNeeded: self >> 24),
         UInt8(truncatingIfNeeded: self >> 16),
         UInt8(truncatingIfNeeded: self >> 8),
         UInt8(truncatingIfNeeded: self)]
    }
}
