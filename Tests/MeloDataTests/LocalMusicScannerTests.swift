import AVFoundation
import CryptoKit
import XCTest
@testable import MeloData
import MeloCore

/// 本地音乐扫描测试：用现有 MediaTagWriter 生成带标签的 mp3/flac，并手工构造 WAV/损坏文件，
/// 验证递归、排序、标签优先/回退、interval、meta、去重、路径容错与「不写库」。
final class LocalMusicScannerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeloDataScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        try super.tearDownWithError()
    }

    // MARK: - 夹具构造

    /// 最小 MP3：3 个 MPEG1 Layer3 44.1kHz 128kbps 帧（帧头 + 静音字节）。
    private func makeMinimalMP3() -> Data {
        var data = Data()
        for _ in 0..<3 {
            data.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])
            data.append(Data(repeating: 0x11, count: 413))
        }
        return data
    }

    private func makeJPEG() -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0xDE, 0xAD])
    }

    private func write(_ data: Data, relativePath: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    private func syncsafeBytes(_ value: Int) -> [UInt8] {
        [UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)]
    }

    private func bigEndianBytes(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private func littleEndian16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private func littleEndian32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    /// 无标签 MP3 + 手写 ID3v2.3 TLEN 帧（毫秒），用于验证「标签时长优先」。
    private func makeMP3WithTLEN(milliseconds: Int) -> Data {
        var frame = Data("TLEN".utf8)
        let body = Data([0x00] + Array(String(milliseconds).utf8))
        frame.append(contentsOf: bigEndianBytes(body.count))
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(body)

        var tag = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00])
        tag.append(contentsOf: syncsafeBytes(frame.count))
        tag.append(frame)
        tag.append(makeMinimalMP3())
        return tag
    }

    /// 构造带 STREAMINFO 的 FLAC：sampleRate=44100、totalSamples=88200（= 2 秒）。
    private func makeMinimalFLAC(totalSamples: UInt64 = 88200, sampleRate: UInt32 = 44100) -> Data {
        var streamInfo = Data(repeating: 0x00, count: 34)
        streamInfo[0] = 0x10 // 最小块大小占位
        var value: UInt64 = UInt64(sampleRate) << 44       // 20-bit 采样率
        value |= UInt64(1) << 41                           // 2 声道 - 1
        value |= UInt64(15) << 36                          // 16-bit - 1
        value |= totalSamples                              // 36-bit 总采样数
        let bytes = [
            UInt8((value >> 56) & 0xFF), UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF), UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
        for (offset, byte) in bytes.enumerated() { streamInfo[10 + offset] = byte }

        var data = Data([0x66, 0x4C, 0x61, 0x43]) // fLaC
        data.append(contentsOf: [0x80, 0x00, 0x00, 0x22]) // STREAMINFO, last, len=34
        data.append(streamInfo)
        data.append(contentsOf: [0xFF, 0xF8, 0x69, 0x08, 0x00, 0x01, 0x02]) // 伪音频帧
        return data
    }

    /// 手工构造合法 PCM WAV（16-bit 单声道），AVAudioFile 可读出准确时长。
    private func makeWAV(duration: TimeInterval, sampleRate: Int = 8000) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataSize = Int((duration * Double(sampleRate)).rounded()) * bytesPerSample
        let byteRate = UInt32(sampleRate * bytesPerSample)

        var data = Data("RIFF".utf8)
        data.append(contentsOf: littleEndian32(UInt32(36 + dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: littleEndian32(16))
        data.append(contentsOf: littleEndian16(1)) // PCM
        data.append(contentsOf: littleEndian16(channels))
        data.append(contentsOf: littleEndian32(UInt32(sampleRate)))
        data.append(contentsOf: littleEndian32(byteRate))
        data.append(contentsOf: littleEndian16(UInt16(bytesPerSample) * channels))
        data.append(contentsOf: littleEndian16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: littleEndian32(UInt32(dataSize)))
        data.append(Data(repeating: 0, count: dataSize))
        return data
    }

    // MARK: - 场景夹具：嵌套目录 + 非音频 + 隐藏 + 损坏

    /// 返回 root，构造：
    /// root/
    ///   top.wav（有效 WAV，2s）
    ///   album/track1.mp3（ID3 标签：晴天 / 周杰伦;费玉清 / 叶惠美）
    ///   album/track2.FLAC（Vorbis 标签 + 封面，STREAMINFO 2s，扩展名大写）
    ///   album/tlen.mp3（手写 TLEN=65000ms，无标题）
    ///   album/corrupted.mp3（随机字节，标签解析失败 → 文件名回退）
    ///   album/notes.txt（非音频）
    ///   album/.hidden.mp3（隐藏文件，跳过）
    ///   album/sub/deep.m4a（无标签 → 文件名回退）
    ///   node_modules/ignored.mp3（无意义目录，跳过）
    ///   .hiddenDir/hidden2.flac（隐藏目录，跳过）
    @discardableResult
    private func makeFixtureTree() throws -> URL {
        let root = tempDirectory.appendingPathComponent("music", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // top.wav：有效 PCM，2 秒
        _ = try write(makeWAV(duration: 2.0), relativePath: "music/top.wav")

        // track1.mp3：标签完整
        let track1URL = try write(makeMinimalMP3(), relativePath: "music/album/track1.mp3")
        try MediaTagWriter.writeMP3Tags(
            path: track1URL.path,
            title: "晴天",
            artist: "周杰伦;费玉清",
            album: "叶惠美",
            lyrics: nil,
            artwork: nil
        )

        // track2.FLAC：标签 + 封面 + STREAMINFO 时长 2s，扩展名大写
        let track2URL = try write(makeMinimalFLAC(), relativePath: "music/album/track2.FLAC")
        try MediaTagWriter.writeFLACTags(
            path: track2URL.path,
            title: "七里香",
            artist: "周杰伦",
            album: "七里香",
            lyrics: "[00:00.00]窗外的麻雀",
            artwork: makeJPEG()
        )

        // tlen.mp3：只靠 ID3 TLEN 提供时长
        _ = try write(makeMP3WithTLEN(milliseconds: 65000), relativePath: "music/album/tlen.mp3")

        // corrupted.mp3：损坏音频，标签解析失败 → 文件名回退
        _ = try write(Data((0..<128).map { UInt8($0) }), relativePath: "music/album/corrupted.mp3")

        // 非音频 / 隐藏文件
        _ = try write(Data("just some notes".utf8), relativePath: "music/album/notes.txt")
        _ = try write(makeMinimalMP3(), relativePath: "music/album/.hidden.mp3")

        // 嵌套目录里的无标签音频
        _ = try write(Data(repeating: 0x22, count: 64), relativePath: "music/album/sub/deep.m4a")

        // 无意义/隐藏目录
        _ = try write(makeMinimalMP3(), relativePath: "music/node_modules/ignored.mp3")
        _ = try write(makeMinimalFLAC(), relativePath: "music/.hiddenDir/hidden2.flac")
        return root
    }

    private func music(_ musics: [MusicInfo], named name: String) -> MusicInfo? {
        musics.first { $0.name == name }
    }

    private func assertValidIntervalOrNil(_ interval: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard let interval else { return }
        XCTAssertTrue(
            interval.range(of: "^\\d{2}:\\d{2}(:\\d{2})?$", options: .regularExpression) != nil,
            "interval 格式应为 mm:ss / hh:mm:ss，实际：\(interval)",
            file: file,
            line: line
        )
    }

    // MARK: - 递归 / 过滤 / 排序

    @MainActor
    func testScanRecursesFiltersAndSortsByPath() async throws {
        let root = try makeFixtureTree()
        let musics = LocalMusicScanner.scan(at: [root])

        let expectedPaths = [
            "album/corrupted.mp3",
            "album/sub/deep.m4a",
            "album/tlen.mp3",
            "album/track1.mp3",
            "album/track2.FLAC",
            "top.wav",
        ].map { root.appendingPathComponent($0).standardizedFileURL.path }

        XCTAssertEqual(musics.map(\.id), expectedPaths, "递归结果应按绝对路径稳定排序")
        XCTAssertEqual(Set(musics.map(\.source)), ["local"])
        XCTAssertEqual(Set(musics.map(\.id)).count, musics.count, "同一路径只出现一次")
        // 非音频/隐藏文件/无意义目录被过滤
        XCTAssertNil(music(musics, named: "notes"))
        XCTAssertNil(music(musics, named: ".hidden"))
        XCTAssertNil(music(musics, named: "ignored"))
        XCTAssertNil(music(musics, named: "hidden2"))

        // 二次扫描顺序稳定
        let second = LocalMusicScanner.scan(at: [root])
        XCTAssertEqual(second.map(\.id), musics.map(\.id))
    }

    // MARK: - 标签优先 / 回退 / interval / meta

    @MainActor
    func testTagMetadataFilenameFallbackIntervalAndMeta() async throws {
        let root = try makeFixtureTree()
        let musics = LocalMusicScanner.scan(at: [root])

        // 1) MP3 标签优先；`;` 多歌手规范为 `、`
        let track1 = try XCTUnwrap(music(musics, named: "晴天"))
        XCTAssertEqual(track1.id, track1.filePath)
        XCTAssertEqual(track1.singer, "周杰伦、费玉清")
        XCTAssertEqual(track1.albumName, "叶惠美")
        XCTAssertEqual(track1.source, "local")
        assertValidIntervalOrNil(track1.interval)
        XCTAssertEqual(track1.meta["filePath"]?.stringValue, track1.id)
        XCTAssertEqual(track1.meta["songId"]?.stringValue, track1.id)
        XCTAssertEqual(track1.meta["albumName"]?.stringValue, "叶惠美")
        XCTAssertEqual(track1.meta["picUrl"]?.stringValue, "")
        XCTAssertEqual(track1.meta["ext"]?.stringValue, "mp3")
        XCTAssertEqual(track1.meta["hasEmbeddedPic"]?.boolValue, false)

        // 2) FLAC 标签 + 封面 + STREAMINFO 时长（2s）；扩展名大小写不敏感
        let track2 = try XCTUnwrap(music(musics, named: "七里香"))
        XCTAssertEqual(track2.singer, "周杰伦")
        XCTAssertEqual(track2.albumName, "七里香")
        XCTAssertEqual(track2.interval, "00:02", "FLAC STREAMINFO 时长应优先于 AVAudioFile")
        XCTAssertEqual(track2.meta["ext"]?.stringValue, "flac")
        XCTAssertEqual(track2.meta["hasEmbeddedPic"]?.boolValue, true)
        XCTAssertTrue(track2.id.hasSuffix("track2.FLAC"), "id 保留真实文件名（扩展名大小写）")

        // 3) 文件名回退：损坏文件 / 无标签 m4a
        let corrupted = try XCTUnwrap(music(musics, named: "corrupted"))
        XCTAssertEqual(corrupted.singer, "")
        XCTAssertEqual(corrupted.albumName, "")
        XCTAssertNil(corrupted.interval, "损坏文件读不到时长")
        XCTAssertEqual(corrupted.meta["ext"]?.stringValue, "mp3")

        let deep = try XCTUnwrap(music(musics, named: "deep"))
        XCTAssertEqual(deep.singer, "")
        XCTAssertEqual(deep.meta["ext"]?.stringValue, "m4a")
        XCTAssertNil(deep.interval, "无标签 + AVFoundation 不支持/损坏 → interval nil")

        // 4) MP3 ID3 TLEN 时长（65000ms → 01:05）
        let tlen = try XCTUnwrap(music(musics, named: "tlen"))
        XCTAssertEqual(tlen.interval, "01:05", "有标签时长时不使用 AVAudioFile")

        // 5) WAV 通过 AVAudioFile 读取时长（2s）
        let wav = try XCTUnwrap(music(musics, named: "top"))
        XCTAssertEqual(wav.interval, "00:02")
        XCTAssertEqual(wav.meta["ext"]?.stringValue, "wav")
    }

    // MARK: - 去重 / 不存在路径 / 空输入

    @MainActor
    func testDedupeAndMissingPaths() async throws {
        let root = try makeFixtureTree()
        let baseline = LocalMusicScanner.scan(at: [root])
        XCTAssertFalse(baseline.isEmpty)

        let nestedTrack = root.appendingPathComponent("album/track1.mp3")
        let mixed = LocalMusicScanner.scan(at: [
            root,
            nestedTrack,
            root.appendingPathComponent("album"),
            root.appendingPathComponent("does-not-exist"),
            URL(fileURLWithPath: "/tmp/definitely-not-exists-\(UUID().uuidString)"),
        ])
        XCTAssertEqual(mixed.map(\.id), baseline.map(\.id), "目录/文件重复输入应去重且顺序一致")

        XCTAssertEqual(LocalMusicScanner.scan(at: []), [], "空输入返回空数组")
        XCTAssertEqual(
            LocalMusicScanner.scan(at: [root.appendingPathComponent("missing")]),
            [],
            "全部路径不存在时返回空数组且不抛错"
        )
    }

    // MARK: - 委托数据层 / 不写库

    @MainActor
    func testServiceDelegationDoesNotTouchDatabase() async throws {
        let root = try makeFixtureTree()
        let dataDirectory = tempDirectory.appendingPathComponent("LxDatas", isDirectory: true)
        let service = SQLiteDataService(dataDirectory: dataDirectory)

        // 未 bootstrap 也能扫描（扫描只读，不需要数据库）
        XCTAssertFalse(service.isBootstrapped)
        let scanned = try service.scanLocalMusic(at: [root])
        XCTAssertEqual(scanned.count, 6)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: service.databasePath.path),
            "扫描不应创建数据库"
        )

        // 已初始化后扫描也不产生任何列表/歌曲记录
        try service.bootstrap()
        let list = try service.createList(name: "扫描目标")
        let countsBefore = try service.loadMusicCounts()
        let scannedAgain = try service.scanLocalMusic(at: [root])
        XCTAssertEqual(scannedAgain.count, 6)
        XCTAssertEqual(try service.loadMusicCounts(), countsBefore)
        XCTAssertEqual(try service.loadMusics(listId: list.id), [])
        XCTAssertEqual(try service.loadUserLists().map(\.id), [list.id], "扫描不应新增列表")
        XCTAssertTrue(try XCTUnwrap(service.verification).isValid)
    }
    // MARK: - 扩展名覆盖

    @MainActor
    func testSupportsAllRequiredExtensionsCaseInsensitively() async throws {
        let requiredExtensions = ["mp3", "flac", "m4a", "aac", "wav", "aiff", "aif", "ogg", "opus"]
        let root = tempDirectory.appendingPathComponent("exts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var expectedCount = 0
        for (index, fileExtension) in requiredExtensions.enumerated() {
            // 大小写混用验证大小写不敏感
            let writtenExtension = index.isMultiple(of: 2) ? fileExtension : fileExtension.uppercased()
            _ = try write(
                Data(repeating: UInt8(index), count: 32),
                relativePath: "exts/track\(index).\(writtenExtension)"
            )
            expectedCount += 1
        }
        _ = try write(Data("not audio".utf8), relativePath: "exts/readme.txt")
        _ = try write(Data("not audio".utf8), relativePath: "exts/cover.jpeg")

        let musics = LocalMusicScanner.scan(at: [root])
        XCTAssertEqual(musics.count, expectedCount, "9 种要求支持的扩展名都应被收录，txt/jpeg 被过滤")
        let foundExtensions = Set(musics.compactMap { $0.meta["ext"]?.stringValue })
        XCTAssertEqual(foundExtensions, Set(requiredExtensions))

        // 显式传入隐藏文件也应跳过
        let hidden = try write(makeMinimalMP3(), relativePath: "exts/.hidden-track.mp3")
        XCTAssertEqual(LocalMusicScanner.scan(at: [hidden]), [])
    }
    // MARK: - Round 6：封面提取 / AVFoundation 元数据 / M4A

    private func makePNG() -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0xCA, 0xFE])
    }

    private func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 构造「mp3 带 JPEG 封面 + flac 带 PNG 封面 + 无封面 mp3」的目录
    private func makeCoverFixture() throws -> URL {
        let root = tempDirectory.appendingPathComponent("cover-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let mp3URL = try write(makeMinimalMP3(), relativePath: "cover-root/with-jpg.mp3")
        try MediaTagWriter.writeMP3Tags(
            path: mp3URL.path, title: "封面 MP3", artist: "歌手A", album: "专辑A",
            lyrics: nil, artwork: makeJPEG()
        )

        let flacURL = try write(makeMinimalFLAC(), relativePath: "cover-root/with-png.flac")
        try MediaTagWriter.writeFLACTags(
            path: flacURL.path, title: "封面 FLAC", artist: "歌手B", album: "专辑B",
            lyrics: nil, artwork: makePNG()
        )

        _ = try write(makeMinimalMP3(), relativePath: "cover-root/plain.mp3")
        return root
    }

    @MainActor
    func testCoverArtworkExtractedToCoversDirectory() async throws {
        let root = try makeCoverFixture()
        let covers = tempDirectory.appendingPathComponent("covers", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: covers.path), "初始 covers 目录不存在")

        let musics = LocalMusicScanner.scan(at: [root], coversDirectory: covers)
        XCTAssertEqual(musics.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: covers.path), "covers 目录应自动创建")

        // MP3：JPEG 封面 → <sha256(path)>.jpg
        let mp3 = try XCTUnwrap(music(musics, named: "封面 MP3"))
        let mp3Pic = try XCTUnwrap(mp3.meta["picUrl"]?.stringValue)
        XCTAssertFalse(mp3Pic.isEmpty)
        let mp3CoverURL = URL(fileURLWithPath: mp3Pic)
        XCTAssertEqual(mp3CoverURL.lastPathComponent, sha256Hex(mp3.id) + ".jpg")
        XCTAssertEqual(mp3CoverURL.deletingLastPathComponent().standardizedFileURL.path, covers.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: mp3CoverURL), makeJPEG())
        XCTAssertEqual(mp3.meta["hasEmbeddedPic"]?.boolValue, true)

        // FLAC：PNG 封面 → jpg/png 由 magic bytes 判定
        let flac = try XCTUnwrap(music(musics, named: "封面 FLAC"))
        let flacPic = try XCTUnwrap(flac.meta["picUrl"]?.stringValue)
        let flacCoverURL = URL(fileURLWithPath: flacPic)
        XCTAssertEqual(flacCoverURL.lastPathComponent, sha256Hex(flac.id) + ".png")
        XCTAssertEqual(try Data(contentsOf: flacCoverURL), makePNG())
        XCTAssertEqual(flac.meta["hasEmbeddedPic"]?.boolValue, true)

        // 无封面：picUrl 空串、hasEmbeddedPic=false
        let plain = try XCTUnwrap(music(musics, named: "plain"))
        XCTAssertEqual(plain.meta["picUrl"]?.stringValue, "")
        XCTAssertEqual(plain.meta["hasEmbeddedPic"]?.boolValue, false)

        // 重复扫描幂等（picUrl 不变、文件仍在）
        let again = LocalMusicScanner.scan(at: [root], coversDirectory: covers)
        XCTAssertEqual(music(again, named: "封面 MP3")?.meta["picUrl"]?.stringValue, mp3Pic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3Pic))
    }

    @MainActor
    func testArtworkWithoutCoversDirectoryKeepsEmptyPicUrl() async throws {
        let root = try makeCoverFixture()
        let musics = LocalMusicScanner.scan(at: [root]) // 不注入 covers 目录
        let mp3 = try XCTUnwrap(music(musics, named: "封面 MP3"))
        XCTAssertEqual(mp3.meta["picUrl"]?.stringValue, "", "未注入 covers 目录时不落盘、picUrl 保持空串")
        XCTAssertEqual(mp3.meta["hasEmbeddedPic"]?.boolValue, true, "但仍应标记存在内嵌封面")
    }

    @MainActor
    func testServiceScanWritesCoversUnderDataDirectoryAndDoesNotCreateDB() async throws {
        let root = try makeCoverFixture()
        let dataDirectory = tempDirectory.appendingPathComponent("LxDatas", isDirectory: true)
        let service = SQLiteDataService(dataDirectory: dataDirectory)
        XCTAssertFalse(service.isBootstrapped)

        let musics = try service.scanLocalMusic(at: [root])
        XCTAssertEqual(musics.count, 3)
        let mp3 = try XCTUnwrap(music(musics, named: "封面 MP3"))
        let picUrl = try XCTUnwrap(mp3.meta["picUrl"]?.stringValue)
        let expectedCoversDirectory = dataDirectory.appendingPathComponent("covers", isDirectory: true)
        XCTAssertEqual(
            URL(fileURLWithPath: picUrl).deletingLastPathComponent().standardizedFileURL.path,
            expectedCoversDirectory.standardizedFileURL.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: picUrl))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.databasePath.path), "扫描不应创建数据库")
    }

    // MARK: M4A（真实容器）

    private func runAfconvert(wavURL: URL, m4aURL: URL) throws {
        let tool = "/usr/bin/afconvert"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw XCTSkip("系统没有 /usr/bin/afconvert，跳过真实 m4a 测试")
        }
        try FileManager.default.createDirectory(at: m4aURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-f", "m4af", "-d", "aac", "-b", "96000", wavURL.path, m4aURL.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: m4aURL.path) else {
            let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw XCTSkip("afconvert 转换失败，跳过：\(message)")
        }
    }

    @MainActor
    func testRealM4AFromAfconvertScansDurationAndFilenameFallback() async throws {
        let wavURL = try write(makeWAV(duration: 2.0, sampleRate: 44100), relativePath: "m4a/input.wav")
        let m4aURL = tempDirectory.appendingPathComponent("m4a/converted.m4a")
        try runAfconvert(wavURL: wavURL, m4aURL: m4aURL)

        let musics = LocalMusicScanner.scan(at: [m4aURL])
        XCTAssertEqual(musics.count, 1)
        let music = try XCTUnwrap(musics.first)
        XCTAssertEqual(music.meta["ext"]?.stringValue, "m4a")
        XCTAssertEqual(music.singer, "")
        XCTAssertEqual(music.albumName, "")
        // afconvert 不写标签 → 文件名回退
        XCTAssertEqual(music.name, "converted")
        // AVAsset.duration 能读到约 2s 时长
        let interval = try XCTUnwrap(music.interval, "m4a 应能通过 AVFoundation 读到时长")
        assertValidIntervalOrNil(interval)
        XCTAssertEqual(music.meta["picUrl"]?.stringValue, "")
        XCTAssertEqual(music.meta["hasEmbeddedPic"]?.boolValue, false)
    }

    @available(macOS 15.0, *)
    private func exportTaggedM4A(
        from sourceURL: URL,
        to outputURL: URL,
        title: String,
        artist: String,
        album: String,
        artwork: Data
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw XCTSkip("无法创建 AVAssetExportSession")
        }
        func textItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
        let artworkItem = AVMutableMetadataItem()
        artworkItem.identifier = .commonIdentifierArtwork
        artworkItem.value = artwork as NSData
        export.metadata = [
            textItem(.commonIdentifierTitle, title),
            textItem(.commonIdentifierArtist, artist),
            textItem(.commonIdentifierAlbumName, album),
            artworkItem,
        ]
        try await export.export(to: outputURL, as: .m4a)
    }

    @MainActor
    func testM4AMetadataAndArtworkViaAVFoundation() async throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("需要 macOS 15+ 的 AVAssetExportSession async export")
        }
        let wavURL = try write(makeWAV(duration: 2.0, sampleRate: 44100), relativePath: "m4a-tagged/input.wav")
        let m4aURL = tempDirectory.appendingPathComponent("m4a-tagged/tagged.m4a")
        try FileManager.default.createDirectory(at: m4aURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let artwork = makeJPEG()
        try await exportTaggedM4A(
            from: wavURL, to: m4aURL,
            title: "M4A 歌名", artist: "M4A 歌手", album: "M4A 专辑", artwork: artwork
        )

        let covers = tempDirectory.appendingPathComponent("m4a-tagged/covers", isDirectory: true)
        let musics = LocalMusicScanner.scan(at: [m4aURL], coversDirectory: covers)
        XCTAssertEqual(musics.count, 1)
        let music = try XCTUnwrap(musics.first)
        XCTAssertEqual(music.name, "M4A 歌名", "m4a 标题应来自 AVFoundation metadata")
        XCTAssertEqual(music.singer, "M4A 歌手")
        XCTAssertEqual(music.albumName, "M4A 专辑")
        XCTAssertNotNil(music.interval, "m4a 时长应来自 AVAsset.duration")
        XCTAssertEqual(music.meta["ext"]?.stringValue, "m4a")
        XCTAssertEqual(music.meta["hasEmbeddedPic"]?.boolValue, true)
        let picUrl = try XCTUnwrap(music.meta["picUrl"]?.stringValue)
        let coverURL = URL(fileURLWithPath: picUrl)
        XCTAssertTrue(FileManager.default.fileExists(atPath: picUrl))
        XCTAssertEqual(coverURL.lastPathComponent, sha256Hex(music.id) + ".jpg")
        XCTAssertEqual(try Data(contentsOf: coverURL), artwork, "m4a artwork 应落盘且内容一致")
    }
}
