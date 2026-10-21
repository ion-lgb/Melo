import XCTest
@testable import MeloData
import MeloCore

/// MP3 ID3v2 / FLAC VorbisComment+PICTURE 标签写入与读回测试（使用手工构造的最小音频文件）。
final class MediaTagWriterTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeloDataTagTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    /// 最小 MP3：3 个 MPEG1 Layer3 44.1kHz 128kbps 帧（帧长 417 字节，帧头 0xFF 0xFB 0x90 0x00）。
    private func makeMinimalMP3() -> Data {
        var data = Data()
        for _ in 0..<3 {
            data.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])
            data.append(Data(repeating: 0x11, count: 413))
        }
        return data
    }

    /// 最小 FLAC：fLaC + STREAMINFO（34 字节，last-block）+ 少量伪音频帧。
    private func makeMinimalFLAC() -> Data {
        var data = Data([0x66, 0x4C, 0x61, 0x43]) // "fLaC"
        // STREAMINFO: last flag=1, type=0, length=34
        data.append(contentsOf: [0x80, 0x00, 0x00, 0x22])
        data.append(Data(repeating: 0xAB, count: 34))
        data.append(contentsOf: [0xFF, 0xF8, 0x69, 0x08, 0x00, 0x01, 0x02, 0x03]) // 伪音频帧
        return data
    }

    private func makeJPEG() -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF])
    }

    private func makePNG() -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0xCA, 0xFE])
    }

    private func writeFile(_ data: Data, name: String) throws -> String {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    private func readAudioTail(_ path: String, tagLength: Int) throws -> Data {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return Data(data.dropFirst(tagLength))
    }

    /// 返回 ID3v2 标签总长度（10 字节头 + syncsafe 大小 + 可选 footer）。
    private func id3TagLength(_ data: Data) -> Int {
        guard data.count >= 10 else { return 0 }
        let bytes = [UInt8](data.prefix(10))
        guard bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return 0 }
        let size = ((Int(bytes[6]) & 0x7F) << 21)
            | ((Int(bytes[7]) & 0x7F) << 14)
            | ((Int(bytes[8]) & 0x7F) << 7)
            | (Int(bytes[9]) & 0x7F)
        return 10 + size + (bytes[5] & 0x10 != 0 ? 10 : 0)
    }

    // MARK: - MP3

    func testMP3WriteAndReadBackPreservesAudioFrames() throws {
        let original = makeMinimalMP3()
        let path = try writeFile(original, name: "sample.mp3")

        let title = "晴天"
        let artist = "周杰伦"
        let album = "叶惠美"
        let lyrics = "[00:00.00]故事的小黄花\n[00:01.00]从出生那年就飘着"
        let artwork = makeJPEG()

        try MediaTagWriter.writeMP3Tags(
            path: path, title: title, artist: artist, album: album, lyrics: lyrics, artwork: artwork
        )

        let output = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertTrue([UInt8](output.prefix(3)) == [0x49, 0x44, 0x33], "文件头必须是 ID3")
        XCTAssertEqual(output[3], 0x03, "使用 ID3v2.3")
        let tagLength = id3TagLength(output)
        XCTAssertGreaterThan(tagLength, 10)
        let audio = Data(output.dropFirst(tagLength))
        XCTAssertEqual(audio, original, "写标签不能改动 MP3 音频帧")

        let metadata = try MediaTagWriter.readMetadata(path: path)
        XCTAssertEqual(metadata.title, title)
        XCTAssertEqual(metadata.artist, artist)
        XCTAssertEqual(metadata.album, album)
        XCTAssertEqual(metadata.lyrics, lyrics)
        XCTAssertEqual(metadata.artwork, artwork)
    }

    func testMP3RewriteReplacesOldTagAndKeepsAudio() throws {
        let original = makeMinimalMP3()
        let path = try writeFile(original, name: "rewrite.mp3")
        try MediaTagWriter.writeMP3Tags(
            path: path, title: "旧标题", artist: "旧歌手", album: "旧专辑", lyrics: nil, artwork: nil
        )
        // 再次写入：整个 ID3 标签被替换，旧值不应残留
        try MediaTagWriter.writeMP3Tags(
            path: path, title: "新标题", artist: nil, album: nil, lyrics: nil, artwork: nil
        )

        let output = try Data(contentsOf: URL(fileURLWithPath: path))
        let tagLength = id3TagLength(output)
        XCTAssertEqual(Data(output.dropFirst(tagLength)), original, "重写后音频帧仍要保持原样")
        // 只有一个 ID3 标签（不能把旧标签当音频数据保留下来）
        let secondTag = id3TagLength(Data(output.dropFirst(tagLength)))
        XCTAssertEqual(secondTag, 0)

        let metadata = try MediaTagWriter.readMetadata(path: path)
        XCTAssertEqual(metadata.title, "新标题")
        XCTAssertNil(metadata.artist)
        XCTAssertNil(metadata.album)
        XCTAssertNil(metadata.artwork)
    }

    func testMP3WithoutLyricsOrArtwork() throws {
        let original = makeMinimalMP3()
        let path = try writeFile(original, name: "plain.mp3")
        try MediaTagWriter.writeMP3Tags(
            path: path, title: "只有标题", artist: nil, album: nil, lyrics: nil, artwork: nil
        )
        let metadata = try MediaTagWriter.readMetadata(path: path)
        XCTAssertEqual(metadata.title, "只有标题")
        XCTAssertNil(metadata.lyrics)
        XCTAssertNil(metadata.artwork)
        XCTAssertEqual(try readAudioTail(path, tagLength: id3TagLength(try Data(contentsOf: URL(fileURLWithPath: path)))), original)
    }

    func testMP3ReadMetadataWithoutTagReturnsNils() throws {
        let path = try writeFile(makeMinimalMP3(), name: "notag.mp3")
        let metadata = try MediaTagWriter.readMetadata(path: path)
        XCTAssertNil(metadata.title)
        XCTAssertNil(metadata.artist)
        XCTAssertNil(metadata.album)
        XCTAssertNil(metadata.lyrics)
        XCTAssertNil(metadata.artwork)
    }

    func testMP3FileNotFoundAndUnsupportedExtension() throws {
        XCTAssertThrowsError(try MediaTagWriter.writeMP3Tags(
            path: tempDirectory.appendingPathComponent("missing.mp3").path,
            title: "x", artist: nil, album: nil, lyrics: nil, artwork: nil
        )) { error in
            guard case MediaTagError.fileNotFound = error else {
                return XCTFail("应抛出 fileNotFound，实际：\(error)")
            }
        }
        let wavPath = try writeFile(Data([0x52, 0x49, 0x46, 0x46]), name: "sample.wav")
        XCTAssertThrowsError(try MediaTagWriter.readMetadata(path: wavPath)) { error in
            guard case MediaTagError.unsupportedFormat = error else {
                return XCTFail("应抛出 unsupportedFormat，实际：\(error)")
            }
        }
        XCTAssertThrowsError(try MediaTagWriter.writeFLACTags(
            path: wavPath, title: "x", artist: nil, album: nil, lyrics: nil, artwork: nil
        )) { error in
            guard case MediaTagError.invalidFile = error else {
                return XCTFail("应抛出 invalidFile，实际：\(error)")
            }
        }
    }

    // MARK: - FLAC

    /// 解析 FLAC 元数据块，返回 (type, isLast, bodyLength, bodyStart) 列表与音频起点。
    private func parseFLACBlocks(_ data: Data) -> (blocks: [(type: UInt8, isLast: Bool, length: Int)], audioStart: Int) {
        var blocks: [(UInt8, Bool, Int)] = []
        var offset = 4
        while offset + 4 <= data.count {
            let header = data[offset]
            let isLast = header & 0x80 != 0
            let type = header & 0x7F
            let length = (Int(data[offset + 1]) << 16) | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
            blocks.append((type, isLast, length))
            offset += 4 + length
            if isLast { break }
        }
        return (blocks, offset)
    }

    func testFLACWriteAndReadBackPreservesStreamInfoAndAudio() throws {
        let original = makeMinimalFLAC()
        let path = try writeFile(original, name: "sample.flac")
        let title = "七里香"
        let artist = "周杰伦"
        let album = "七里香"
        let lyrics = "[00:00.00]窗外的麻雀\n[00:01.00]在电线杆上多嘴"
        let artwork = makePNG()

        try MediaTagWriter.writeFLACTags(
            path: path, title: title, artist: artist, album: album, lyrics: lyrics, artwork: artwork
        )

        let output = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual([UInt8](output.prefix(4)), [0x66, 0x4C, 0x61, 0x43], "fLaC 魔数")
        let parsed = parseFLACBlocks(output)
        XCTAssertEqual(parsed.blocks.map(\.type), [0, 4, 6], "STREAMINFO + VORBIS_COMMENT + PICTURE")
        XCTAssertEqual(parsed.blocks.map(\.isLast), [false, false, true], "只有最后一个元数据块置 last 标志")
        // STREAMINFO 原样保留
        let streamInfo = output.subdata(in: 8..<42)
        XCTAssertEqual(streamInfo, Data(repeating: 0xAB, count: 34))
        // 音频帧原样保留
        let audio = Data(output.dropFirst(parsed.audioStart))
        XCTAssertEqual(audio, Data(original.dropFirst(42)))
        // 封面块按 24-bit 长度正确编码
        let picture = parsed.blocks[2]
        XCTAssertGreaterThan(picture.length, artwork.count)

        let metadata = try MediaTagWriter.readMetadata(path: path)
        XCTAssertEqual(metadata.title, title)
        XCTAssertEqual(metadata.artist, artist)
        XCTAssertEqual(metadata.album, album)
        XCTAssertEqual(metadata.lyrics, lyrics)
        XCTAssertEqual(metadata.artwork, artwork)
    }

    func testFLACRewriteUpdatesCommentsAndPreservesUnknownFields() throws {
        let original = makeMinimalFLAC()
        let path = try writeFile(original, name: "rewrite.flac")
        try MediaTagWriter.writeFLACTags(
            path: path, title: "旧标题", artist: "旧歌手", album: "旧专辑", lyrics: nil, artwork: makeJPEG()
        )
        // 第二次写入：标题更新、歌手/专辑清空、歌词新增；封面不传时保留旧封面
        try MediaTagWriter.writeFLACTags(
            path: path, title: "新标题", artist: nil, album: nil, lyrics: "新歌词", artwork: nil
        )

        let metadata = try MediaTagWriter.readMetadata(path: path)
        XCTAssertEqual(metadata.title, "新标题")
        XCTAssertNil(metadata.artist)
        XCTAssertNil(metadata.album)
        XCTAssertEqual(metadata.lyrics, "新歌词")
        XCTAssertEqual(metadata.artwork, makeJPEG(), "未传封面时应保留旧 PICTURE")

        // 音频与 STREAMINFO 仍未被破坏
        let output = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = parseFLACBlocks(output)
        XCTAssertEqual(output.subdata(in: 8..<42), Data(repeating: 0xAB, count: 34))
        XCTAssertEqual(Data(output.dropFirst(parsed.audioStart)), Data(original.dropFirst(42)))
        // 只有一个 VORBIS_COMMENT / PICTURE
        XCTAssertEqual(parsed.blocks.filter { $0.type == 4 }.count, 1)
        XCTAssertEqual(parsed.blocks.filter { $0.type == 6 }.count, 1)
    }

    func testFLACWithoutArtworkKeepsNoPictureBlock() throws {
        let path = try writeFile(makeMinimalFLAC(), name: "noart.flac")
        try MediaTagWriter.writeFLACTags(
            path: path, title: "无封面", artist: nil, album: nil, lyrics: nil, artwork: nil
        )
        let output = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = parseFLACBlocks(output)
        XCTAssertEqual(parsed.blocks.map(\.type), [0, 4])
        let metadata = try MediaTagWriter.readMetadata(path: path)
        XCTAssertEqual(metadata.title, "无封面")
        XCTAssertNil(metadata.artwork)
    }

    func testFLACInvalidFileThrows() throws {
        let path = try writeFile(Data("not a flac file".utf8), name: "broken.flac")
        XCTAssertThrowsError(try MediaTagWriter.writeFLACTags(
            path: path, title: "x", artist: nil, album: nil, lyrics: nil, artwork: nil
        )) { error in
            guard case MediaTagError.invalidFile = error else {
                return XCTFail("应抛出 invalidFile，实际：\(error)")
            }
        }
        // 元数据块长度越界
        var corrupted = Data([0x66, 0x4C, 0x61, 0x43, 0x00, 0xFF, 0xFF, 0xFF])
        corrupted.append(Data(repeating: 0, count: 10))
        let corruptedPath = try writeFile(corrupted, name: "corrupted.flac")
        XCTAssertThrowsError(try MediaTagWriter.readMetadata(path: corruptedPath))
    }

    // MARK: - 文件名模板

    private func makeMusic(id: String = "kw_1", name: String, singer: String) -> MusicInfo {
        MusicInfo(id: id, name: name, singer: singer, source: "kw", interval: "04:29", meta: .object([:]))
    }

    func testMediaFileNameTemplates() {
        let music = makeMusic(name: "晴天", singer: "周杰伦")
        XCTAssertEqual(MediaFileName.makeFileName(template: "歌名 - 歌手", music: music, ext: "mp3"), "晴天 - 周杰伦.mp3")
        XCTAssertEqual(MediaFileName.makeFileName(template: "歌手 - 歌名", music: music, ext: "mp3"), "周杰伦 - 晴天.mp3")
        XCTAssertEqual(MediaFileName.makeFileName(template: "歌名", music: music, ext: "flac"), "晴天.flac")
        // 扩展名大小写归一
        XCTAssertEqual(MediaFileName.makeFileName(template: "歌名", music: music, ext: "FLAC"), "晴天.flac")
        XCTAssertEqual(MediaFileName.makeFileName(template: "歌名", music: makeMusic(name: "x", singer: "y"), ext: ".mp3"), "x.mp3")
    }

    func testMediaFileNameFiltersIllegalCharactersAndClipsLength() {
        let illegal = makeMusic(name: "a/b:c*d?e#f\"g<h>i|j\\k", singer: "歌手")
        XCTAssertEqual(MediaFileName.makeFileName(template: "歌名 - 歌手", music: illegal, ext: "mp3"), "abcdefghijk - 歌手.mp3")

        let longName = makeMusic(name: String(repeating: "很", count: 300), singer: "歌手")
        let fileName = MediaFileName.makeFileName(template: "歌名", music: longName, ext: "mp3")
        XCTAssertEqual(fileName.count, 150 + ".mp3".count)
        XCTAssertTrue(fileName.hasSuffix(".mp3"))

        // 多歌手：最多截到 80 字符内（原版 clipNameLength 语义）
        let manySingers = (0..<40).map { "歌手\($0)" }.joined(separator: "、")
        let music = makeMusic(name: "歌", singer: manySingers)
        let multiSingerFile = MediaFileName.makeFileName(template: "歌手 - 歌名", music: music, ext: "mp3")
        let singerPart = multiSingerFile.components(separatedBy: " - ").first ?? ""
        XCTAssertLessThanOrEqual(singerPart.count, 80)
    }
}
