import Foundation
import MeloCore

// MARK: - 媒体标签错误

public enum MediaTagError: LocalizedError, Equatable {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case invalidFile(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "文件不存在：\(path)"
        case .unsupportedFormat(let ext):
            return "不支持写入标签的音频格式：\(ext)"
        case .invalidFile(let message):
            return "音频文件结构无效：\(message)"
        case .ioError(let message):
            return "文件读写失败：\(message)"
        }
    }
}

// MARK: - 标签写入 / 读取（MP3 ID3v2 / FLAC VorbisComment+PICTURE）

/// 原生实现 MP3 / FLAC 标签读写，对齐原版 `node-id3` + `flac-metadata` 的写入结果：
/// - MP3：整体重写 ID3v2.3 标签（TIT2/TPE1/TALB/USLT/APIC，文本 UTF-16 带 BOM），音频帧原样保留；
/// - FLAC：解析元数据块（24-bit 大端长度 / last-block 标志），替换/追加 VORBIS_COMMENT 与 PICTURE，
///   STREAMINFO/SEEKTABLE 等其它块与音频帧原样保留，整体重写文件。
public enum MediaTagWriter {
    private static let flacDefaultVendor = "reference libFLAC 1.2.1 20070917"
    private static let flacPictureBlockType: UInt8 = 6
    private static let flacVorbisCommentBlockType: UInt8 = 4

    // MARK: - 对外 API

    /// 写入 MP3 标签（无标签时插入文件头；已有标签则替换并保留音频帧）。
    public static func writeMP3Tags(
        path: String,
        title: String?,
        artist: String?,
        album: String?,
        lyrics: String?,
        artwork: Data?
    ) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw MediaTagError.fileNotFound(path)
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw MediaTagError.ioError(error.localizedDescription)
        }

        let existingTagLength = id3v2TagLength(in: data) ?? 0
        let audio = Data(data.dropFirst(existingTagLength))

        var frames = Data()
        if let title, !title.isEmpty {
            frames.append(makeID3TextFrame(id: "TIT2", text: title))
        }
        if let artist, !artist.isEmpty {
            frames.append(makeID3TextFrame(id: "TPE1", text: artist))
        }
        if let album, !album.isEmpty {
            frames.append(makeID3TextFrame(id: "TALB", text: album))
        }
        if let lyrics, !lyrics.isEmpty {
            frames.append(makeID3USLTFrame(lyrics: lyrics))
        }
        if let artwork, !artwork.isEmpty {
            frames.append(makeID3APICFrame(artwork: artwork))
        }

        var output = Data()
        output.reserveCapacity(10 + frames.count + audio.count)
        output.append(makeID3Header(frameSize: frames.count))
        output.append(frames)
        output.append(audio)
        try writeAtomically(output, to: url)
    }

    /// 写入 FLAC 标签（替换 VORBIS_COMMENT 的 TITLE/ARTIST/ALBUM/LYRICS；有封面时替换 PICTURE）。
    public static func writeFLACTags(
        path: String,
        title: String?,
        artist: String?,
        album: String?,
        lyrics: String?,
        artwork: Data?
    ) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw MediaTagError.fileNotFound(path)
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw MediaTagError.ioError(error.localizedDescription)
        }

        let parsed = try parseFLAC(data)
        let audio = Data(data.dropFirst(parsed.audioStart))

        // 保留 STREAMINFO 等其它块；有封面时移除旧 PICTURE（无封面时保留原封面）。
        var preserved: [FLACBlock] = []
        var existingComments: [String: String] = [:]
        var existingVendor: String?
        for block in parsed.blocks {
            switch block.type {
            case flacVorbisCommentBlockType:
                if let comment = parseVorbisComment(block.body) {
                    existingVendor = comment.vendor
                    for entry in comment.entries {
                        existingComments[entry.key.uppercased()] = entry.value
                    }
                }
            case flacPictureBlockType:
                if artwork == nil { preserved.append(block) }
            default:
                preserved.append(block)
            }
        }

        // 重建 VORBIS_COMMENT：保留未知字段，覆盖/移除本次涉及的四个键。
        let managedKeys = ["TITLE", "ARTIST", "ALBUM", "LYRICS"]
        let unknownEntries = existingComments
            .filter { !managedKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var newEntries: [String] = unknownEntries
        let managedValues: [(String, String?)] = [
            ("TITLE", title), ("ARTIST", artist), ("ALBUM", album), ("LYRICS", lyrics),
        ]
        for (key, value) in managedValues {
            if let value, !value.isEmpty { newEntries.append("\(key)=\(value)") }
        }
        let vendor = existingVendor.flatMap { $0.isEmpty ? nil : $0 } ?? flacDefaultVendor
        let vorbisBlock = FLACBlock(
            type: flacVorbisCommentBlockType,
            isLast: false,
            body: buildVorbisComment(vendor: vendor, entries: newEntries)
        )

        var blocks = preserved
        blocks.append(vorbisBlock)
        if let artwork, !artwork.isEmpty {
            blocks.append(FLACBlock(
                type: flacPictureBlockType,
                isLast: false,
                body: buildFLACPicture(artwork: artwork)
            ))
        }
        guard !blocks.isEmpty else { throw MediaTagError.invalidFile("FLAC 元数据块为空") }
        for block in blocks where block.body.count > 0xFFFFFF {
            throw MediaTagError.invalidFile("FLAC 元数据块过大（type=\(block.type)）")
        }

        var output = Data()
        output.append(contentsOf: [0x66, 0x4C, 0x61, 0x43]) // "fLaC"
        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            output.append(makeFLACBlockHeader(type: block.type, isLast: isLast, length: block.body.count))
            output.append(block.body)
        }
        output.append(audio)
        try writeAtomically(output, to: url)
    }

    /// 读取 MP3 / FLAC 标签（供本地导入与测试验证）。
    public static func readMetadata(
        path: String
    ) throws -> (title: String?, artist: String?, album: String?, lyrics: String?, artwork: Data?) {
        guard FileManager.default.fileExists(atPath: path) else {
            throw MediaTagError.fileNotFound(path)
        }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
            throw MediaTagError.ioError(error.localizedDescription)
        }
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mp3":
            return try readMP3Metadata(data)
        case "flac":
            return try readFLACMetadata(data)
        default:
            throw MediaTagError.unsupportedFormat(URL(fileURLWithPath: path).pathExtension)
        }
    }

    // MARK: - 通用工具

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw MediaTagError.ioError(error.localizedDescription)
        }
    }

    private static func byte(_ data: Data, _ offset: Int) -> UInt8 {
        data[data.startIndex + offset]
    }

    private static func subdata(_ data: Data, _ range: Range<Int>) -> Data {
        data.subdata(in: (data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound))
    }

    // MARK: - MP3 / ID3v2

    private struct ID3Frame {
        let id: String
        let body: [UInt8]
    }

    private static func syncsafeValue(_ bytes: [UInt8], offset: Int) -> Int {
        ((Int(bytes[offset]) & 0x7F) << 21)
            | ((Int(bytes[offset + 1]) & 0x7F) << 14)
            | ((Int(bytes[offset + 2]) & 0x7F) << 7)
            | (Int(bytes[offset + 3]) & 0x7F)
    }

    private static func bigEndianValue(_ bytes: [UInt8], offset: Int) -> Int {
        (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
            | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
    }

    private static func bigEndianBytes(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func syncsafeBytes(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    /// 已有 ID3v2 标签的总字节数（含 10 字节头、可选 footer）；不是 ID3 文件返回 nil。
    private static func id3v2TagLength(in data: Data) -> Int? {
        guard data.count >= 10 else { return nil }
        let header = [UInt8](data.prefix(10))
        guard header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { return nil }
        let major = Int(header[3])
        guard major >= 3 else { return nil } // 只处理 ID3v2.3/2.4；v2.2 留给读者兼容
        let flags = header[5]
        var length = 10 + syncsafeValue(header, offset: 6)
        if flags & 0x10 != 0 { length += 10 } // footer
        return min(length, data.count)
    }

    private static func makeID3Header(frameSize: Int) -> Data {
        var header: [UInt8] = [0x49, 0x44, 0x33, 0x03, 0x00, 0x00] // "ID3" v2.3，无 flags
        header.append(contentsOf: syncsafeBytes(frameSize))
        return Data(header)
    }

    private static func makeID3TextFrame(id: String, text: String) -> Data {
        var body = Data([0x01]) // encoding: UTF-16 with BOM
        body.append(utf16WithBOM(text))
        return makeID3Frame(id: id, body: body)
    }

    private static func makeID3USLTFrame(lyrics: String) -> Data {
        var body = Data()
        body.append(0x01) // encoding: UTF-16 with BOM
        body.append(contentsOf: [0x7A, 0x68, 0x6F]) // language "zho"
        // 空内容描述：BOM + UTF-16 NUL 终止符
        body.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00])
        body.append(utf16WithBOM(lyrics))
        return makeID3Frame(id: "USLT", body: body)
    }

    private static func makeID3APICFrame(artwork: Data) -> Data {
        var body = Data()
        body.append(0x00) // description/mime: ISO-8859-1
        body.append(contentsOf: Array(mimeType(for: artwork).utf8))
        body.append(0x00) // MIME 结束
        body.append(0x03) // picture type: 3 = front cover
        body.append(0x00) // 空描述结束
        body.append(artwork)
        return makeID3Frame(id: "APIC", body: body)
    }

    private static func makeID3Frame(id: String, body: Data) -> Data {
        precondition(id.utf8.count == 4, "ID3v2.3 frame id must be 4 ASCII characters")
        var frame = Data()
        frame.reserveCapacity(10 + body.count)
        frame.append(contentsOf: Array(id.utf8))
        frame.append(contentsOf: bigEndianBytes(body.count)) // ID3v2.3 帧长度为普通 32-bit 大端
        frame.append(contentsOf: [0x00, 0x00]) // frame flags
        frame.append(body)
        return frame
    }

    private static func utf16WithBOM(_ text: String) -> Data {
        var data = Data([0xFF, 0xFE]) // little-endian BOM
        data.reserveCapacity(2 + text.utf16.count * 2)
        for unit in text.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8((unit >> 8) & 0xFF))
        }
        return data
    }

    private static func mimeType(for artwork: Data) -> String {
        let prefix = [UInt8](artwork.prefix(8))
        if prefix.count >= 3, prefix[0] == 0xFF, prefix[1] == 0xD8, prefix[2] == 0xFF {
            return "image/jpeg"
        }
        if prefix.count >= 8, prefix[0] == 0x89, prefix[1] == 0x50, prefix[2] == 0x4E, prefix[3] == 0x47 {
            return "image/png"
        }
        if prefix.count >= 4, prefix[0] == 0x47, prefix[1] == 0x49, prefix[2] == 0x46, prefix[3] == 0x38 {
            return "image/gif"
        }
        return "application/octet-stream"
    }

    private static func parseID3Frames(_ tag: [UInt8]) -> (major: Int, frames: [ID3Frame])? {
        guard tag.count >= 10 else { return nil }
        let major = Int(tag[3])
        guard major == 3 || major == 4 else { return nil }
        let size = syncsafeValue(tag, offset: 6)
        let tagEnd = min(10 + size, tag.count)
        var offset = 10
        var frames: [ID3Frame] = []
        // 注：ID3v2 unsynchronisation（flags & 0x80）常见于图片标签，这里不做展开，
        // 文本帧通常不受影响；如需完整支持可在后续版本补充。
        while offset + 10 <= tagEnd {
            let idBytes = Array(tag[offset..<(offset + 4)])
            guard idBytes.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }) else { break }
            let frameID = String(decoding: idBytes, as: UTF8.self)
            let frameSize = major >= 4 ? syncsafeValue(tag, offset: offset + 4) : bigEndianValue(tag, offset: offset + 4)
            let bodyStart = offset + 10
            let bodyEnd = bodyStart + frameSize
            guard frameSize > 0, bodyEnd <= tagEnd else { break }
            frames.append(ID3Frame(id: frameID, body: Array(tag[bodyStart..<bodyEnd])))
            offset = bodyEnd
        }
        return (major, frames)
    }

    private static func readMP3Metadata(
        _ data: Data
    ) throws -> (title: String?, artist: String?, album: String?, lyrics: String?, artwork: Data?) {
        let tagLength = id3v2TagLength(in: data) ?? 0
        guard tagLength > 0 else {
            return (nil, nil, nil, nil, nil)
        }
        let tag = [UInt8](subdata(data, 0..<tagLength))
        guard let parsed = parseID3Frames(tag) else {
            return (nil, nil, nil, nil, nil)
        }
        var title: String?
        var artist: String?
        var album: String?
        var lyrics: String?
        var artwork: Data?
        for frame in parsed.frames {
            switch frame.id {
            case "TIT2": title = decodeID3TextFrame(frame.body)
            case "TPE1": artist = decodeID3TextFrame(frame.body)
            case "TALB": album = decodeID3TextFrame(frame.body)
            case "USLT": lyrics = decodeID3USLTFrame(frame.body)
            case "APIC": artwork = decodeID3APICFrame(frame.body)
            default: break
            }
        }
        return (title, artist, album, lyrics, artwork)
    }

    private static func decodeID3TextFrame(_ body: [UInt8]) -> String? {
        guard !body.isEmpty else { return nil }
        let encoding = body[0]
        let payload = Array(body.dropFirst())
        switch encoding {
        case 0:
            return trimTagText(String(data: Data(payload), encoding: .isoLatin1))
        case 1:
            return trimTagText(decodeUTF16(payload))
        case 2:
            return trimTagText(decodeUTF16BigEndian(payload))
        case 3:
            return trimTagText(String(data: Data(payload), encoding: .utf8))
        default:
            return nil
        }
    }

    private static func trimTagText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        return trimmed
    }

    private static func decodeUTF16(_ bytes: [UInt8]) -> String? {
        var payload = bytes
        while payload.count >= 2, payload[payload.count - 1] == 0x00, payload[payload.count - 2] == 0x00 {
            payload.removeLast(2)
        }
        guard !payload.isEmpty else { return "" }
        var littleEndian = true
        if payload.count >= 2 {
            if payload[0] == 0xFF, payload[1] == 0xFE {
                payload.removeFirst(2)
                littleEndian = true
            } else if payload[0] == 0xFE, payload[1] == 0xFF {
                payload.removeFirst(2)
                littleEndian = false
            }
        }
        var units: [UInt16] = []
        units.reserveCapacity(payload.count / 2)
        var index = 0
        while index + 1 < payload.count {
            let unit = littleEndian
                ? UInt16(payload[index]) | (UInt16(payload[index + 1]) << 8)
                : (UInt16(payload[index]) << 8) | UInt16(payload[index + 1])
            units.append(unit)
            index += 2
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    private static func decodeUTF16BigEndian(_ bytes: [UInt8]) -> String? {
        var payload = bytes
        while payload.count >= 2, payload[payload.count - 1] == 0x00, payload[payload.count - 2] == 0x00 {
            payload.removeLast(2)
        }
        guard !payload.isEmpty else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(payload.count / 2)
        var index = 0
        while index + 1 < payload.count {
            units.append((UInt16(payload[index]) << 8) | UInt16(payload[index + 1]))
            index += 2
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// 解析编码字符串，返回 (文本, 消耗字节数)；消耗字节数包含终止符。
    private static func decodeID3String(_ bytes: [UInt8], encoding: UInt8) -> (text: String, consumed: Int) {
        switch encoding {
        case 1:
            var littleEndian = true
            var start = 0
            if bytes.count >= 2 {
                if bytes[0] == 0xFF, bytes[1] == 0xFE { start = 2; littleEndian = true } else if bytes[0] == 0xFE, bytes[1] == 0xFF { start = 2; littleEndian = false }
            }
            var units: [UInt16] = []
            var index = start
            while index + 1 < bytes.count {
                let unit = littleEndian
                    ? UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                    : (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
                if unit == 0 {
                    return (String(utf16CodeUnits: units, count: units.count), index + 2)
                }
                units.append(unit)
                index += 2
            }
            return (String(utf16CodeUnits: units, count: units.count), bytes.count)
        case 2:
            var units: [UInt16] = []
            var index = 0
            while index + 1 < bytes.count {
                let unit = (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
                if unit == 0 { return (String(utf16CodeUnits: units, count: units.count), index + 2) }
                units.append(unit)
                index += 2
            }
            return (String(utf16CodeUnits: units, count: units.count), bytes.count)
        default:
            if let terminator = bytes.firstIndex(of: 0) {
                return (String(decoding: bytes[0..<terminator], as: UTF8.self), terminator + 1)
            }
            return (String(decoding: bytes, as: UTF8.self), bytes.count)
        }
    }

    private static func decodeID3USLTFrame(_ body: [UInt8]) -> String? {
        guard body.count >= 4 else { return nil }
        let encoding = body[0]
        let content = Array(body.dropFirst(4)) // 跳过 encoding + 3 字节语言
        let descriptor = decodeID3String(content, encoding: encoding)
        let lyrics = decodeID3String(Array(content.dropFirst(descriptor.consumed)), encoding: encoding)
        return trimTagText(lyrics.text)
    }

    private static func decodeID3APICFrame(_ body: [UInt8]) -> Data? {
        guard body.count > 4 else { return nil }
        let encoding = body[0]
        var index = 1
        guard let mimeEnd = body[index...].firstIndex(of: 0) else { return nil }
        index = mimeEnd + 1
        guard index < body.count else { return nil }
        index += 1 // picture type
        let description = decodeID3String(Array(body[index...]), encoding: encoding)
        index += description.consumed
        guard index <= body.count else { return nil }
        let image = Array(body[index...])
        return image.isEmpty ? nil : Data(image)
    }

    // MARK: - FLAC

    private struct FLACBlock {
        var type: UInt8
        var isLast: Bool
        var body: Data
    }

    private struct ParsedFLAC {
        var blocks: [FLACBlock]
        var audioStart: Int
    }

    private static func parseFLAC(_ data: Data) throws -> ParsedFLAC {
        guard data.count >= 4,
              byte(data, 0) == 0x66, byte(data, 1) == 0x4C, byte(data, 2) == 0x61, byte(data, 3) == 0x43 else {
            throw MediaTagError.invalidFile("缺少 fLaC 魔数")
        }
        var blocks: [FLACBlock] = []
        var offset = 4
        while offset + 4 <= data.count {
            let header = byte(data, offset)
            let isLast = header & 0x80 != 0
            let type = header & 0x7F
            let length = (Int(byte(data, offset + 1)) << 16)
                | (Int(byte(data, offset + 2)) << 8)
                | Int(byte(data, offset + 3))
            let bodyStart = offset + 4
            let bodyEnd = bodyStart + length
            guard bodyEnd <= data.count else {
                throw MediaTagError.invalidFile("元数据块长度越界（type=\(type), length=\(length)）")
            }
            blocks.append(FLACBlock(type: type, isLast: isLast, body: subdata(data, bodyStart..<bodyEnd)))
            offset = bodyEnd
            if isLast { break }
        }
        guard let first = blocks.first, first.type == 0 else {
            throw MediaTagError.invalidFile("首个元数据块不是 STREAMINFO")
        }
        return ParsedFLAC(blocks: blocks, audioStart: offset)
    }

    private static func makeFLACBlockHeader(type: UInt8, isLast: Bool, length: Int) -> Data {
        let bytes: [UInt8] = [
            (isLast ? 0x80 : 0x00) | (type & 0x7F),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
        ]
        return Data(bytes)
    }

    private static func parseVorbisComment(_ body: Data) -> (vendor: String, entries: [(key: String, value: String)])? {
        var offset = 0
        guard body.count >= 4 else { return nil }
        func readUInt32LE() -> Int? {
            guard offset + 4 <= body.count else { return nil }
            let value = Int(byte(body, offset)) | (Int(byte(body, offset + 1)) << 8)
                | (Int(byte(body, offset + 2)) << 16) | (Int(byte(body, offset + 3)) << 24)
            offset += 4
            return value
        }
        guard let vendorLength = readUInt32LE(), offset + vendorLength <= body.count else { return nil }
        let vendor = String(decoding: subdata(body, offset..<(offset + vendorLength)), as: UTF8.self)
        offset += vendorLength
        guard let count = readUInt32LE() else { return nil }
        var entries: [(key: String, value: String)] = []
        for _ in 0..<count {
            guard let length = readUInt32LE(), offset + length <= body.count else { return nil }
            let entry = String(decoding: subdata(body, offset..<(offset + length)), as: UTF8.self)
            offset += length
            if let separator = entry.firstIndex(of: "=") {
                entries.append((String(entry[..<separator]), String(entry[entry.index(after: separator)...])))
            }
        }
        return (vendor, entries)
    }

    private static func buildVorbisComment(vendor: String, entries: [String]) -> Data {
        var body = Data()
        let vendorBytes = Array(vendor.utf8)
        body.append(contentsOf: littleEndianBytes(vendorBytes.count))
        body.append(contentsOf: vendorBytes)
        body.append(contentsOf: littleEndianBytes(entries.count))
        for entry in entries {
            let bytes = Array(entry.utf8)
            body.append(contentsOf: littleEndianBytes(bytes.count))
            body.append(contentsOf: bytes)
        }
        return body
    }

    private static func littleEndianBytes(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private static func buildFLACPicture(artwork: Data) -> Data {
        var body = Data()
        body.append(contentsOf: bigEndianBytes(3)) // picture type: 3 = front cover
        let mime = Array(mimeType(for: artwork).utf8)
        body.append(contentsOf: bigEndianBytes(mime.count))
        body.append(contentsOf: mime)
        body.append(contentsOf: bigEndianBytes(0)) // 空描述
        body.append(contentsOf: bigEndianBytes(0)) // width（可选 0）
        body.append(contentsOf: bigEndianBytes(0)) // height（可选 0）
        body.append(contentsOf: bigEndianBytes(0)) // bits per pixel
        body.append(contentsOf: bigEndianBytes(0)) // colors
        body.append(contentsOf: bigEndianBytes(artwork.count))
        body.append(artwork)
        return body
    }

    private static func readFLACMetadata(
        _ data: Data
    ) throws -> (title: String?, artist: String?, album: String?, lyrics: String?, artwork: Data?) {
        let parsed = try parseFLAC(data)
        var title: String?
        var artist: String?
        var album: String?
        var lyrics: String?
        var artwork: Data?
        for block in parsed.blocks where block.type == flacVorbisCommentBlockType {
            guard let comment = parseVorbisComment(block.body) else { continue }
            for entry in comment.entries {
                switch entry.key.uppercased() {
                case "TITLE": title = entry.value
                case "ARTIST": artist = entry.value
                case "ALBUM": album = entry.value
                case "LYRICS", "UNSYNCEDLYRICS": lyrics = entry.value
                default: break
                }
            }
        }
        for block in parsed.blocks where block.type == flacPictureBlockType {
            if let picture = parseFLACPicture(block.body) {
                artwork = picture
                break
            }
        }
        return (title, artist, album, lyrics, artwork)
    }

    private static func parseFLACPicture(_ body: Data) -> Data? {
        var offset = 0
        guard body.count >= 4 else { return nil }
        func readUInt32BE() -> Int? {
            guard offset + 4 <= body.count else { return nil }
            let value = (Int(byte(body, offset)) << 24) | (Int(byte(body, offset + 1)) << 16)
                | (Int(byte(body, offset + 2)) << 8) | Int(byte(body, offset + 3))
            offset += 4
            return value
        }
        guard let pictureType = readUInt32BE() else { return nil }
        guard let mimeLength = readUInt32BE(), offset + mimeLength <= body.count else { return nil }
        offset += mimeLength
        guard let descriptionLength = readUInt32BE(), offset + descriptionLength <= body.count else { return nil }
        offset += descriptionLength
        guard readUInt32BE() != nil, readUInt32BE() != nil, readUInt32BE() != nil, readUInt32BE() != nil else {
            return nil
        }
        guard let dataLength = readUInt32BE(), offset + dataLength <= body.count else { return nil }
        _ = pictureType
        return subdata(body, offset..<(offset + dataLength))
    }

    // MARK: - 时长读取（本地扫描用）

    /// 读取音频时长（秒）。优先标签内信息：MP3 的 ID3 `TLEN`（毫秒）/ FLAC 的 STREAMINFO（采样数÷采样率）
    /// 或 VorbisComment 的 `LENGTH`（毫秒）/`DURATION`（秒）。读不到返回 nil（由调用方回退 AVAudioFile）。
    internal static func readDuration(path: String) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mp3":
            return mp3Duration(in: data)
        case "flac":
            return flacDuration(in: data)
        default:
            return nil
        }
    }

    private static func mp3Duration(in data: Data) -> TimeInterval? {
        let tagLength = id3v2TagLength(in: data) ?? 0
        guard tagLength > 0 else { return nil }
        let tag = [UInt8](subdata(data, 0..<tagLength))
        guard let parsed = parseID3Frames(tag) else { return nil }
        for frame in parsed.frames where frame.id == "TLEN" {
            guard let text = decodeID3TextFrame(frame.body), let milliseconds = parseTLEN(text) else { continue }
            if milliseconds > 0 { return milliseconds / 1000 }
        }
        return nil
    }

    /// TLEN 规范为毫秒整数字符串；少数标签写成 `mm:ss(.xxx)`，这里都做兼容。
    private static func parseTLEN(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(":") {
            var seconds: Double = 0
            for component in trimmed.split(separator: ":") {
                guard let part = Double(component) else { return nil }
                seconds = seconds * 60 + part
            }
            return seconds * 1000
        }
        if let milliseconds = Double(trimmed) { return milliseconds }
        let digits = trimmed.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Double(digits)
    }

    private static func flacDuration(in data: Data) -> TimeInterval? {
        guard let parsed = try? parseFLAC(data) else { return nil }
        var fallback: TimeInterval?
        for block in parsed.blocks {
            if block.type == 0, let duration = streamInfoDuration(block.body) {
                return duration
            }
            if block.type == flacVorbisCommentBlockType, let comment = parseVorbisComment(block.body) {
                for entry in comment.entries {
                    let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch entry.key.uppercased() {
                    case "LENGTH":
                        if let milliseconds = Double(value) { fallback = milliseconds / 1000 }
                    case "DURATION":
                        if let seconds = Double(value) { fallback = seconds }
                    default:
                        break
                    }
                }
            }
        }
        return fallback
    }

    /// FLAC STREAMINFO 后 8 字节：20-bit 采样率 + 3-bit 声道 + 5-bit 位深 + 36-bit 总采样数。
    private static func streamInfoDuration(_ body: Data) -> TimeInterval? {
        guard body.count >= 18 else { return nil }
        let bytes = [UInt8](subdata(body, 10..<18))
        var value: UInt64 = 0
        for byte in bytes { value = (value << 8) | UInt64(byte) }
        let sampleRate = (value >> 44) & 0xFFFFF
        let totalSamples = value & 0xF_FFFF_FFFF
        guard sampleRate > 0, totalSamples > 0 else { return nil }
        return Double(totalSamples) / Double(sampleRate)
    }
}

// MARK: - 下载文件名（原版 download.fileName 三种模板）

public enum MediaFileName {
    /// 与原版 `createDownloadInfo` 一致：
    /// `template` 支持「歌名 - 歌手」「歌手 - 歌名」「歌名」及任意组合；
    /// 多歌手先按原版 `clipNameLength` 截到 80 字符内，再替换模板、截断文件名并过滤非法字符。
    public static func makeFileName(template: String, music: MusicInfo, ext: String) -> String {
        let singer = clipNameLength(music.singer)
        var name = template
        if let range = name.range(of: "歌手") {
            name.replaceSubrange(range, with: singer)
        }
        if let range = name.range(of: "歌名") {
            name.replaceSubrange(range, with: music.name)
        }
        name = clipFileNameLength(name)
        let normalizedExtension = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        if !normalizedExtension.isEmpty {
            name += ".\(normalizedExtension.lowercased())"
        }
        name = filterFileName(name)
        if name.isEmpty || name == normalizedExtension {
            let fallback = music.id.isEmpty ? "music" : music.id
            name = "\(fallback).\(normalizedExtension.lowercased())"
        }
        return name
    }

    /// 引擎侧复用：过滤文件名非法字符（不截断、不改扩展名）。
    internal static func sanitizeFileName(_ name: String) -> String {
        filterFileName(name)
    }

    private static func filterFileName(_ name: String) -> String {
        let illegalCharacters = Set("\\/:*?#\"<>|")
        return String(name.filter { !illegalCharacters.contains($0) })
    }

    private static func clipFileNameLength(_ name: String) -> String {
        name.count > 150 ? String(name.prefix(150)) : name
    }

    /// 原版 `clipNameLength`：多歌手（以「、」分隔）时保证截断后不超过 80 字符。
    private static func clipNameLength(_ name: String) -> String {
        let maxLength = 80
        guard name.count > maxLength, name.contains("、") else { return name }
        var parts = name.split(separator: "、", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return name }
        var result = parts.removeFirst()
        for part in parts {
            if result.count + part.count > maxLength { break }
            result += "、" + part
        }
        return result
    }
}
