import CoreFoundation
import Network
import XCTest
@testable import MeloData
import MeloCore

// MARK: - 本地 HTTP 测试服务器（NWListener，支持 Range/HEAD/慢速/中断）

private final class TestHTTPServer {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]

        var rangeHeader: String? { headers["range"] }
        var rangeStart: Int? {
            guard let rangeHeader, rangeHeader.hasPrefix("bytes=") else { return nil }
            let value = rangeHeader.dropFirst("bytes=".count)
            guard let dash = value.firstIndex(of: "-") else { return nil }
            return Int(value[..<dash])
        }
    }

    struct Response {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// >0 时按块 + 间隔发送（模拟慢速下载）
        var chunkSize = 0
        var chunkDelay: TimeInterval = 0
        /// >0 时只发送前 N 字节后断连（模拟传输中断）
        var truncateAfter = 0
        /// true 时不发送任何响应（模拟服务器无响应）
        var hang = false
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MeloDataTests.HTTPServer")
    private let lock = NSLock()
    private var recordedRequests: [Request] = []
    private var connections: [NWConnection] = []
    var handler: ((Request) -> Response)?
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    deinit {
        listener.cancel()
    }

    func start() throws {
        let semaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed:
                semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        guard semaphore.wait(timeout: .now() + 5) == .success, let listenerPort = listener.port else {
            throw NSError(domain: "TestHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "服务器启动失败"])
        }
        port = listenerPort.rawValue
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let pending = connections
        connections.removeAll()
        lock.unlock()
        for connection in pending { connection.cancel() }
    }

    var songURL: URL { URL(string: "http://127.0.0.1:\(port)/song.mp3")! }
    var coverURL: URL { URL(string: "http://127.0.0.1:\(port)/cover.jpg")! }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    var requestCount: Int { requests.count }

    // MARK: 内部

    private func handle(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let headerRange = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: accumulated[..<headerRange.lowerBound], as: UTF8.self)
                let request = Self.parse(head)
                self.lock.lock()
                self.recordedRequests.append(request)
                self.lock.unlock()
                let response = self.handler?(request) ?? Response(status: 404)
                self.send(response, request: request, connection: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receive(connection, buffer: accumulated)
            }
        }
    }

    private static func parse(_ head: String) -> Request {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let method = requestLine.count > 0 ? String(requestLine[0]) : ""
        let path = requestLine.count > 1 ? String(requestLine[1]) : "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return Request(method: method, path: path, headers: headers)
    }

    private func send(_ response: Response, request: Request, connection: NWConnection) {
        if response.hang { return }
        if response.truncateAfter > 0 {
            var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
            head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            let truncated = Data(response.body.prefix(response.truncateAfter))
            let chunkSize = max(1, response.chunkSize > 0 ? response.chunkSize : truncated.count)
            let chunks = stride(from: 0, to: truncated.count, by: chunkSize).map { start in
                truncated.subdata(in: start..<min(start + chunkSize, truncated.count))
            }
            sendChunks(chunks, index: 0, delay: response.chunkDelay, closeAfter: true, connection: connection)
            return
        }
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        if response.chunkSize > 0 {
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            let chunks = stride(from: 0, to: response.body.count, by: response.chunkSize).map { start in
                response.body.subdata(in: start..<min(start + response.chunkSize, response.body.count))
            }
            sendChunks(chunks, index: 0, delay: response.chunkDelay, closeAfter: false, connection: connection)
            return
        }
        var payload = Data(head.utf8)
        if request.method != "HEAD" { payload.append(response.body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendChunks(_ chunks: [Data], index: Int, delay: TimeInterval, closeAfter: Bool, connection: NWConnection) {
        guard index < chunks.count else {
            // closeAfter=true 时数据未发完就关闭连接，模拟传输中断；否则为正常结束
            connection.cancel()
            return
        }
        connection.send(content: chunks[index], completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { return }
            if delay > 0 {
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.sendChunks(chunks, index: index + 1, delay: delay, closeAfter: closeAfter, connection: connection)
                }
            } else {
                self.sendChunks(chunks, index: index + 1, delay: delay, closeAfter: closeAfter, connection: connection)
            }
        })
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

// MARK: - 测试

final class DownloadEngineTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeloDataDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        try super.tearDownWithError()
    }

    // MARK: 工具

    private func makeMusic(id: String = "kw_1", name: String = "晴天", singer: String = "周杰伦") -> MusicInfo {
        MusicInfo(
            id: id,
            name: name,
            singer: singer,
            source: "kw",
            interval: "04:29",
            meta: .object(["songId": .string("1"), "albumName": .string("叶惠美")])
        )
    }

    private func makeRequest(
        url: URL,
        fileName: String = "晴天 - 周杰伦.mp3",
        fileExtension: String = "mp3",
        embedPicture: Bool = false,
        embedLyrics: Bool = false,
        lyrics: LyricInfo? = nil,
        pictureURL: URL? = nil,
        music: MusicInfo? = nil
    ) -> DownloadRequest {
        DownloadRequest(
            music: music ?? makeMusic(),
            quality: "320k",
            url: url,
            saveDirectory: tempDirectory,
            fileName: fileName,
            fileExtension: fileExtension,
            embedPicture: embedPicture,
            embedLyrics: embedLyrics,
            lyrics: lyrics,
            pictureURL: pictureURL
        )
    }

    /// 标准响应：有 Range 时返回 206 + 剩余内容，否则 200 全量。
    private func rangedResponse(body: Data, request: TestHTTPServer.Request, chunkSize: Int = 0, chunkDelay: TimeInterval = 0) -> TestHTTPServer.Response {
        if let start = request.rangeStart {
            guard start >= 0, start < body.count else {
                return TestHTTPServer.Response(status: 416)
            }
            return TestHTTPServer.Response(
                status: 206,
                headers: [
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(start)-\(body.count - 1)/\(body.count)",
                ],
                body: body.subdata(in: start..<body.count),
                chunkSize: chunkSize,
                chunkDelay: chunkDelay
            )
        }
        return TestHTTPServer.Response(
            status: 200,
            headers: ["Accept-Ranges": "bytes"],
            body: body,
            chunkSize: chunkSize,
            chunkDelay: chunkDelay
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 8,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待超时：\(description)", file: file, line: line)
    }

    private func makeMinimalMP3() -> Data {
        var data = Data()
        for _ in 0..<3 {
            data.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])
            data.append(Data(repeating: 0x11, count: 413))
        }
        return data
    }

    private func makeMinimalFLAC() -> Data {
        var data = Data([0x66, 0x4C, 0x61, 0x43]) // fLaC
        data.append(contentsOf: [0x80, 0x00, 0x00, 0x22]) // STREAMINFO: last, len=34
        data.append(Data(repeating: 0xAB, count: 34))
        data.append(contentsOf: [0xFF, 0xF8, 0x69, 0x08, 0x00, 0x01]) // 伪音频帧
        return data
    }

    // MARK: - 完整下载 / 进度事件

    @MainActor
    func testFullDownloadWritesFileAndEmitsProgress() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        server.handler = { _ in TestHTTPServer.Response(status: 200, headers: ["Accept-Ranges": "bytes"], body: payload) }

        let engine = DownloadEngine(maxConcurrent: 3)
        var events: [DownloadEvent] = []
        engine.eventHandler = { events.append($0) }
        let request = makeRequest(url: server.songURL, fileName: "纯下载.zip", fileExtension: "zip")
        let id = engine.enqueue(request)

        await waitUntil("下载完成") { engine.tasks.first?.isCompleted == true }
        let task = try XCTUnwrap(engine.tasks.first)
        XCTAssertEqual(task.id, id)
        XCTAssertEqual(task.status, "completed")
        XCTAssertEqual(task.statusText, "已完成")
        XCTAssertEqual(task.progressDownloaded, Int64(payload.count))
        XCTAssertEqual(task.progressTotal, Int64(payload.count))
        XCTAssertEqual(task.fileName, "纯下载.zip")
        XCTAssertTrue(task.filePath.hasSuffix("纯下载.zip"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: task.filePath)), payload)

        XCTAssertTrue(events.contains { if case .completed(let taskId, let path) = $0 { taskId == id && path == task.filePath } else { false } })
        let progressEvents = events.compactMap { event -> (Int64, Int64, Double)? in
            if case .progress(_, let downloaded, let total, let speed) = event { return (downloaded, total, speed) }
            return nil
        }
        XCTAssertFalse(progressEvents.isEmpty)
        XCTAssertEqual(progressEvents.last?.0, Int64(payload.count))
        XCTAssertEqual(progressEvents.last?.1, Int64(payload.count))
        XCTAssertEqual(server.requestCount, 1)
    }

    @MainActor
    func testDownloadWritesMP3TagsIncludingLyricsAndArtwork() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let song = makeMinimalMP3()
        let cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x01, 0x02])
        server.handler = { request in
            if request.path.contains("cover") {
                return TestHTTPServer.Response(status: 200, headers: ["Content-Type": "image/jpeg"], body: cover)
            }
            return TestHTTPServer.Response(status: 200, headers: ["Accept-Ranges": "bytes"], body: song)
        }

        let engine = DownloadEngine(maxConcurrent: 2)
        let lyrics = LyricInfo(lyric: "[00:00.00]故事的小黄花\n[00:01.00]从出生那年就飘着")
        let request = makeRequest(
            url: server.songURL,
            fileName: "晴天",
            fileExtension: "mp3",
            embedPicture: true,
            embedLyrics: true,
            lyrics: lyrics,
            pictureURL: server.coverURL
        )
        engine.enqueue(request)

        await waitUntil("下载+写标签完成") { engine.tasks.first?.isCompleted == true }
        let task = try XCTUnwrap(engine.tasks.first)
        let metadata = try MediaTagWriter.readMetadata(path: task.filePath)
        XCTAssertEqual(metadata.title, "晴天")
        XCTAssertEqual(metadata.artist, "周杰伦")
        XCTAssertEqual(metadata.album, "叶惠美")
        XCTAssertEqual(metadata.lyrics, lyrics.lyric)
        XCTAssertEqual(metadata.artwork, cover)
        // 音频帧保持原样（标签整体插入文件头）
        let data = try Data(contentsOf: URL(fileURLWithPath: task.filePath))
        XCTAssertTrue([UInt8](data.prefix(3)) == [0x49, 0x44, 0x33])
        XCTAssertEqual(Data(data.suffix(song.count)), song)
    }

    @MainActor
    func testDownloadWritesFLACTags() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let song = makeMinimalFLAC()
        server.handler = { _ in TestHTTPServer.Response(status: 200, headers: ["Accept-Ranges": "bytes"], body: song) }

        let engine = DownloadEngine(maxConcurrent: 1)
        let request = makeRequest(
            url: server.songURL, fileName: "七里香", fileExtension: "flac",
            music: makeMusic(name: "七里香")
        )
        engine.enqueue(request)

        await waitUntil("FLAC 下载完成") { engine.tasks.first?.isCompleted == true }
        let task = try XCTUnwrap(engine.tasks.first)
        XCTAssertTrue(task.filePath.hasSuffix(".flac"))
        let metadata = try MediaTagWriter.readMetadata(path: task.filePath)
        XCTAssertEqual(metadata.title, "七里香")
        XCTAssertEqual(metadata.artist, "周杰伦")
        let data = try Data(contentsOf: URL(fileURLWithPath: task.filePath))
        XCTAssertEqual([UInt8](data.prefix(4)), [0x66, 0x4C, 0x61, 0x43])
        XCTAssertEqual(Data(data.suffix(6)), Data(song.suffix(6)))
    }

    // MARK: - 断点续传 / 重试

    @MainActor
    func testInterruptedDownloadResumesWithRangeRequest() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data((0..<8192).map { UInt8($0 % 199) })
        server.handler = { request in
            if server.requestCount == 1, request.rangeHeader == nil {
                // 首次请求：只发 3000 字节就断开，模拟网络中断
                return TestHTTPServer.Response(
                    status: 200,
                    headers: ["Accept-Ranges": "bytes"],
                    body: payload,
                    chunkSize: 512,
                    chunkDelay: 0.005,
                    truncateAfter: 3000
                )
            }
            return self.rangedResponse(body: payload, request: request)
        }

        let engine = DownloadEngine(maxConcurrent: 1)
        engine.retryDelay = 0.01
        engine.enqueue(makeRequest(url: server.songURL, fileName: "断点", fileExtension: "zip"))

        await waitUntil("续传后下载完成") { engine.tasks.first?.isCompleted == true }
        let task = try XCTUnwrap(engine.tasks.first)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: task.filePath)), payload)
        XCTAssertEqual(task.progressDownloaded, Int64(payload.count))
        XCTAssertGreaterThanOrEqual(server.requestCount, 2)
        XCTAssertTrue(server.requests.contains { $0.rangeHeader != nil }, "重试时必须带 Range 头续传")
    }

    @MainActor
    func testRetryThenSucceed() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data(repeating: 0x42, count: 1024)
        server.handler = { _ in
            if server.requestCount < 3 {
                return TestHTTPServer.Response(status: 500)
            }
            return TestHTTPServer.Response(status: 200, headers: ["Accept-Ranges": "bytes"], body: payload)
        }

        let engine = DownloadEngine(maxConcurrent: 1)
        engine.retryDelay = 0.01
        engine.enqueue(makeRequest(url: server.songURL, fileName: "重试", fileExtension: "zip"))

        await waitUntil("重试后成功") { engine.tasks.first?.isCompleted == true }
        XCTAssertEqual(server.requestCount, 3)
        let path = try XCTUnwrap(engine.tasks.first?.filePath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), payload)
    }

    @MainActor
    func testRetryLimitEmitsFailure() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        server.handler = { _ in TestHTTPServer.Response(status: 500) }

        let engine = DownloadEngine(maxConcurrent: 1)
        engine.retryDelay = 0.01
        var events: [DownloadEvent] = []
        engine.eventHandler = { events.append($0) }
        engine.enqueue(makeRequest(url: server.songURL, fileName: "失败", fileExtension: "zip"))

        await waitUntil("重试用尽后失败") { engine.tasks.first?.status == "error" }
        let task = try XCTUnwrap(engine.tasks.first)
        XCTAssertEqual(task.statusText, "下载失败")
        XCTAssertEqual(server.requestCount, 3, "首次 + 2 次重试")
        XCTAssertTrue(events.contains { if case .failed(_, let message) = $0 { message.contains("500") } else { false } })
    }

    // MARK: - pause / resume / cancel / remove

    @MainActor
    func testPauseAndResume() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data((0..<24576).map { UInt8($0 % 233) })
        server.handler = { request in
            self.rangedResponse(body: payload, request: request, chunkSize: 512, chunkDelay: 0.01)
        }

        let engine = DownloadEngine(maxConcurrent: 1)
        let id = engine.enqueue(makeRequest(url: server.songURL, fileName: "暂停续传", fileExtension: "zip"))

        await waitUntil("开始下载") { engine.tasks.first?.progressDownloaded ?? 0 > 0 }
        engine.pause(id: id)
        await waitUntil("状态变为暂停") { engine.tasks.first?.status == "pause" }
        let pausedTask = try XCTUnwrap(engine.tasks.first)
        XCTAssertEqual(pausedTask.statusText, "已暂停")
        let pausedSize = (try? FileManager.default.attributesOfItem(atPath: pausedTask.filePath)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(pausedSize, 0)
        XCTAssertLessThan(pausedSize, Int64(payload.count))

        engine.resume(id: id)
        await waitUntil("续传完成") { engine.tasks.first?.isCompleted == true }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: pausedTask.filePath)), payload)
        XCTAssertTrue(server.requests.contains { $0.rangeHeader != nil }, "resume 必须使用 Range 续传")
    }

    @MainActor
    func testCancelRemovesPartialFile() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data(repeating: 0x7E, count: 32768)
        server.handler = { request in
            self.rangedResponse(body: payload, request: request, chunkSize: 512, chunkDelay: 0.01)
        }

        let engine = DownloadEngine(maxConcurrent: 1)
        var events: [DownloadEvent] = []
        engine.eventHandler = { events.append($0) }
        let id = engine.enqueue(makeRequest(url: server.songURL, fileName: "取消", fileExtension: "zip"))
        await waitUntil("开始下载") { engine.tasks.first?.progressDownloaded ?? 0 > 0 }
        let path = try XCTUnwrap(engine.tasks.first?.filePath)

        engine.cancel(id: id)
        await waitUntil("状态变为失败/取消") { engine.tasks.first?.status == "error" }
        XCTAssertEqual(engine.tasks.first?.statusText, "已取消")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "取消后应删除未完成文件")
        XCTAssertFalse(events.contains { if case .completed = $0 { return true } else { return false } })
        XCTAssertFalse(events.contains { if case .failed = $0 { return true } else { return false } }, "取消只发 statusChanged，不发 failed")
    }

    @MainActor
    func testRemoveTaskFromList() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data(repeating: 0x6C, count: 65536)
        server.handler = { request in
            self.rangedResponse(body: payload, request: request, chunkSize: 512, chunkDelay: 0.01)
        }

        let engine = DownloadEngine(maxConcurrent: 1)
        let id = engine.enqueue(makeRequest(url: server.songURL, fileName: "移除", fileExtension: "zip"))
        await waitUntil("开始下载") { engine.tasks.first?.progressDownloaded ?? 0 > 0 }
        let path = try XCTUnwrap(engine.tasks.first?.filePath)

        engine.remove(id: id)
        await waitUntil("任务从列表移除") { engine.tasks.isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "移除未完成任务应删除部分文件")
    }

    // MARK: - 同名跳过 / 空闲超时 / 去重

    @MainActor
    func testSkipExistingFileWithoutNetworkRequest() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        server.handler = { _ in TestHTTPServer.Response(status: 500) }

        let existing = tempDirectory.appendingPathComponent("已存在.zip")
        try Data(repeating: 0x01, count: 500).write(to: existing)

        let engine = DownloadEngine(maxConcurrent: 1)
        var events: [DownloadEvent] = []
        engine.eventHandler = { events.append($0) }
        engine.enqueue(makeRequest(url: server.songURL, fileName: "已存在", fileExtension: "zip"))

        await waitUntil("同名文件跳过") { engine.tasks.first?.status == "error" }
        XCTAssertEqual(engine.tasks.first?.statusText, "存在同名文件，跳过下载")
        XCTAssertEqual(server.requestCount, 0, "同名跳过不应发起网络请求")
        XCTAssertEqual(try Data(contentsOf: existing), Data(repeating: 0x01, count: 500), "已存在文件不能被覆盖")
        XCTAssertTrue(events.contains { if case .failed(_, let message) = $0 { message.contains("同名") } else { false } })
    }

    @MainActor
    func testIdleTimeoutFailsTask() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        server.handler = { _ in TestHTTPServer.Response(hang: true) }

        // 测试注入较短的看门狗时间与 0 重试
        let engine = DownloadEngine(maxConcurrent: 1, idleTimeout: 0.4, retryLimit: 0)
        var events: [DownloadEvent] = []
        engine.eventHandler = { events.append($0) }
        let startTime = Date()
        engine.enqueue(makeRequest(url: server.songURL, fileName: "超时", fileExtension: "zip"))

        await waitUntil(timeout: 6, "空闲超时失败") { engine.tasks.first?.status == "error" }
        XCTAssertLessThan(Date().timeIntervalSince(startTime), 6)
        XCTAssertTrue(events.contains { if case .failed(_, let message) = $0 { message.contains("超时") } else { false } })
    }

    @MainActor
    func testDuplicateEnqueueReturnsSameTaskID() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        server.handler = { _ in TestHTTPServer.Response(hang: true) }

        let engine = DownloadEngine(maxConcurrent: 1, idleTimeout: 60, retryLimit: 0)
        let request = makeRequest(url: server.songURL, fileName: "去重", fileExtension: "zip")
        let first = engine.enqueue(request)
        let second = engine.enqueue(request)
        XCTAssertEqual(first, second)
        XCTAssertEqual(engine.tasks.count, 1)
        engine.cancel(id: first)
        await waitUntil("清理") { engine.tasks.first?.status == "error" }
    }

    @MainActor
    func testResumeAfterFailureRetriesFromScratchAfter416() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data((0..<16384).map { UInt8($0 % 177) })
        server.handler = { request in
            if request.rangeHeader != nil {
                // 模拟服务器返回 416：引擎应删除文件并从头重下
                return TestHTTPServer.Response(status: 416)
            }
            return self.rangedResponse(body: payload, request: request, chunkSize: 512, chunkDelay: 0.01)
        }

        let engine = DownloadEngine(maxConcurrent: 1)
        engine.retryDelay = 0.01
        // 第一次正常下载到一半后暂停，再 resume 触发 Range（服务器回 416）
        let id = engine.enqueue(makeRequest(url: server.songURL, fileName: "416", fileExtension: "zip"))
        await waitUntil("开始下载") { engine.tasks.first?.progressDownloaded ?? 0 > 0 }
        engine.pause(id: id)
        await waitUntil("暂停") { engine.tasks.first?.status == "pause" }
        engine.resume(id: id)

        await waitUntil("416 后重下成功") { engine.tasks.first?.isCompleted == true }
        let path = try XCTUnwrap(engine.tasks.first?.filePath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), payload)
        XCTAssertTrue(server.requests.contains { $0.rangeHeader != nil })
    }
    @MainActor
    func testMaxConcurrentDownloadsLimitsRunningTasks() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        server.handler = { _ in TestHTTPServer.Response(hang: true) }

        let engine = DownloadEngine(maxConcurrent: 3, idleTimeout: 60, retryLimit: 0)
        var ids: [String] = []
        for index in 0..<5 {
            ids.append(engine.enqueue(makeRequest(
                url: server.songURL,
                fileName: "并发\(index)",
                fileExtension: "zip",
                music: makeMusic(id: "kw_concurrent_\(index)")
            )))
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(engine.tasks.filter { $0.status == "run" }.count, 3, "最多 3 个并发下载")
        XCTAssertEqual(engine.tasks.filter { $0.status == "waiting" }.count, 2)
        XCTAssertEqual(engine.tasks.map(\.position), [0, 1, 2, 3, 4])

        for id in ids { engine.cancel(id: id) }
        await waitUntil("并发任务清理") { engine.tasks.allSatisfy { $0.status == "error" } }
    }
    // MARK: - 失败残留清理 / 终态事件顺序

    @MainActor
    func testPermanentFailureRemovesZeroByteFile() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        server.handler = { _ in TestHTTPServer.Response(status: 500) }

        let engine = DownloadEngine(maxConcurrent: 1, idleTimeout: 20, retryLimit: 0)
        var events: [DownloadEvent] = []
        engine.eventHandler = { events.append($0) }
        engine.enqueue(makeRequest(url: server.songURL, fileName: "空文件", fileExtension: "zip"))

        await waitUntil("任务失败") { engine.tasks.first?.status == "error" }
        let path = try XCTUnwrap(engine.tasks.first?.filePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "失败后不应残留 0 字节文件")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
            .filter { $0.contains("空文件") }
        XCTAssertTrue(leftovers.isEmpty, "0 字节残留：\(leftovers)")
        XCTAssertTrue(events.contains { if case .failed = $0 { return true } else { return false } })
    }

    @MainActor
    func testPermanentFailureKeepsPartialFileForResume() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data((0..<8192).map { UInt8($0 % 211) })
        // 每次请求只发前 512 字节就断连，重试 0 次后任务失败
        server.handler = { _ in
            TestHTTPServer.Response(
                status: 200,
                headers: ["Accept-Ranges": "bytes"],
                body: payload,
                chunkSize: 512,
                chunkDelay: 0.002,
                truncateAfter: 512
            )
        }

        let engine = DownloadEngine(maxConcurrent: 1, idleTimeout: 20, retryLimit: 0)
        let id = engine.enqueue(makeRequest(url: server.songURL, fileName: "部分文件", fileExtension: "zip"))
        await waitUntil("任务失败") { engine.tasks.first?.status == "error" }
        let path = try XCTUnwrap(engine.tasks.first?.filePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let fileSize = try XCTUnwrap((attributes[.size] as? NSNumber)?.int64Value)
        XCTAssertGreaterThan(fileSize, 0, ">0 字节的部分文件应保留用于断点续传")
        XCTAssertLessThan(fileSize, Int64(payload.count))

        // remove 未完成任务时清理部分文件
        engine.remove(id: id)
        await waitUntil("任务移除") { engine.tasks.isEmpty }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    @MainActor
    func testCompletedEventFollowsStatusChanged() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data(repeating: 0x33, count: 2048)
        server.handler = { _ in TestHTTPServer.Response(status: 200, headers: ["Accept-Ranges": "bytes"], body: payload) }

        let engine = DownloadEngine(maxConcurrent: 1)
        var events: [DownloadEvent] = []
        engine.eventHandler = { events.append($0) }
        engine.enqueue(makeRequest(url: server.songURL, fileName: "事件顺序", fileExtension: "zip"))
        await waitUntil("下载完成") { engine.tasks.first?.isCompleted == true }
        try await Task.sleep(nanoseconds: 50_000_000)

        let completedIndexes = events.indices.filter { index in
            if case .completed = events[index] { return true }
            return false
        }
        XCTAssertEqual(completedIndexes.count, 1, "completed 事件只发一次")
        let statusIndex = try XCTUnwrap(events.lastIndex { event in
            if case .statusChanged(_, let status) = event { return status == "completed" }
            return false
        })
        XCTAssertLessThan(statusIndex, completedIndexes[0], "statusChanged(completed) 必须先于 completed 事件")
        XCTAssertFalse(events.contains { if case .failed = $0 { return true } else { return false } })
    }

    @MainActor
    func testFailedEventFollowsStatusChanged() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        server.handler = { _ in TestHTTPServer.Response(status: 500) }

        let engine = DownloadEngine(maxConcurrent: 1, idleTimeout: 20, retryLimit: 0)
        var events: [DownloadEvent] = []
        engine.eventHandler = { events.append($0) }
        engine.enqueue(makeRequest(url: server.songURL, fileName: "失败事件顺序", fileExtension: "zip"))
        await waitUntil("下载失败") { engine.tasks.first?.status == "error" }
        try await Task.sleep(nanoseconds: 50_000_000)

        let failedIndexes = events.indices.filter { index in
            if case .failed = events[index] { return true }
            return false
        }
        XCTAssertEqual(failedIndexes.count, 1, "failed 事件只发一次")
        let statusIndex = try XCTUnwrap(events.lastIndex { event in
            if case .statusChanged(_, let status) = event { return status == "error" }
            return false
        })
        XCTAssertLessThan(statusIndex, failedIndexes[0], "statusChanged(error) 必须先于 failed 事件")
        XCTAssertFalse(events.contains { if case .completed = $0 { return true } else { return false } })
    }
    // MARK: - 重启恢复（restore）

    @MainActor
    func testRestorePausedTaskThenResumeUsesRange() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data((0..<32768).map { UInt8($0 % 241) })
        server.handler = { request in
            self.rangedResponse(body: payload, request: request, chunkSize: 512, chunkDelay: 0.01)
        }

        let firstEngine = DownloadEngine(maxConcurrent: 1)
        let id = firstEngine.enqueue(makeRequest(url: server.songURL, fileName: "恢复续传", fileExtension: "zip"))
        await waitUntil("开始下载") { firstEngine.tasks.first?.progressDownloaded ?? 0 > 0 }
        firstEngine.pause(id: id)
        await waitUntil("暂停") { firstEngine.tasks.first?.status == "pause" }
        let snapshot = firstEngine.tasks
        XCTAssertEqual(snapshot.count, 1)
        let partialSize = (try? FileManager.default.attributesOfItem(atPath: snapshot[0].filePath)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(partialSize, 100, "续传需要 >100 字节的部分文件（同名跳过阈值）")

        // 模拟重启：新引擎从持久化快照恢复
        let restoredEngine = DownloadEngine(maxConcurrent: 1)
        restoredEngine.restore(tasks: snapshot)
        XCTAssertEqual(restoredEngine.tasks.count, 1)
        let restored = restoredEngine.tasks[0]
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.status, "pause")
        XCTAssertEqual(restored.statusText, "已暂停（恢复自上次运行）")
        XCTAssertEqual(restored.fileName, snapshot[0].fileName)
        XCTAssertEqual(restored.filePath, snapshot[0].filePath)
        XCTAssertEqual(restored.quality, snapshot[0].quality)
        XCTAssertEqual(restored.ext, snapshot[0].ext)
        XCTAssertEqual(restored.url, snapshot[0].url)
        XCTAssertEqual(restored.musicInfo, snapshot[0].musicInfo)
        XCTAssertEqual(restored.progressDownloaded, snapshot[0].progressDownloaded, "恢复时保留进度字段")
        XCTAssertFalse(restored.isCompleted)
        XCTAssertEqual(restored.position, 0)

        // 不自动开始下载
        let requestsBefore = server.requestCount
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(restoredEngine.tasks[0].status, "pause")
        XCTAssertEqual(server.requestCount, requestsBefore, "restore 不应自动发起请求")

        // 用户手动 resume → Range 断点续传
        restoredEngine.resume(id: id)
        await waitUntil("恢复后续传完成") { restoredEngine.tasks.first?.isCompleted == true }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restored.filePath)), payload)
        XCTAssertTrue(
            server.requests.dropFirst().contains { $0.rangeHeader != nil },
            "resume 恢复任务应使用 Range 续传"
        )
    }

    @MainActor
    func testRestoreMissingFileWaitsThenResumesFromScratch() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data((0..<4096).map { UInt8($0 % 197) })
        server.handler = { _ in
            TestHTTPServer.Response(status: 200, headers: ["Accept-Ranges": "bytes"], body: payload)
        }

        let missingPath = tempDirectory.appendingPathComponent("restore-missing.zip").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingPath))
        let task = DownloadTaskInfo(
            id: "kw_restore_missing_zip",
            isCompleted: false,
            status: "error",
            statusText: "下载失败",
            progressDownloaded: 512,
            progressTotal: 4096,
            url: server.songURL.absoluteString,
            quality: "320k",
            ext: "zip",
            fileName: "restore-missing.zip",
            filePath: missingPath,
            musicInfo: makeMusic(id: "kw_restore_missing"),
            position: 0
        )

        let engine = DownloadEngine(maxConcurrent: 1)
        engine.restore(tasks: [task])
        let restored = engine.tasks[0]
        XCTAssertEqual(restored.status, "waiting", "文件缺失应恢复为 waiting（从头下载）")
        XCTAssertEqual(restored.statusText, "已恢复，等待继续")
        XCTAssertEqual(restored.progressDownloaded, 512, "恢复时保留进度字段")
        XCTAssertEqual(restored.progressTotal, 4096)

        // 不自动开始
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine.tasks[0].status, "waiting")
        XCTAssertEqual(server.requestCount, 0, "restore 不应自动发起请求")

        engine.resume(id: task.id)
        await waitUntil("从头下载完成") { engine.tasks.first?.isCompleted == true }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: missingPath)), payload)
        XCTAssertTrue(server.requests.allSatisfy { $0.rangeHeader == nil }, "文件缺失时应从头下载，不带 Range")
    }

    @MainActor
    func testRestoreSkipsCompletedExistingAndIsIdempotentOrdered() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        server.handler = { _ in TestHTTPServer.Response(hang: true) }

        let engine = DownloadEngine(maxConcurrent: 3, idleTimeout: 60, retryLimit: 0)
        let existingID = engine.enqueue(makeRequest(
            url: server.songURL,
            fileName: "已存在",
            fileExtension: "zip",
            music: makeMusic(id: "kw_existing")
        ))
        await waitUntil("既有任务开始") { engine.tasks.first?.status == "run" }
        let existingSnapshot = engine.tasks[0]

        func restoredTask(id: String, position: Int, completed: Bool = false, status: String = "run") -> DownloadTaskInfo {
            DownloadTaskInfo(
                id: id,
                isCompleted: completed,
                status: status,
                statusText: "",
                progressDownloaded: 0,
                progressTotal: 100,
                url: server.songURL.absoluteString,
                quality: "320k",
                ext: "zip",
                fileName: "\(id).zip",
                filePath: tempDirectory.appendingPathComponent("\(id).zip").path,
                musicInfo: makeMusic(id: "music_\(id)"),
                position: position
            )
        }

        let completedTask = restoredTask(id: "dl_completed", position: 0, completed: true, status: "completed")
        let taskA = restoredTask(id: "dl_a", position: 2)
        let taskB = restoredTask(id: "dl_b", position: 0)
        let taskC = restoredTask(id: "dl_c", position: 1)

        engine.restore(tasks: [taskA, completedTask, taskC, taskB, existingSnapshot, taskB])
        let ids = engine.tasks.map(\.id)
        XCTAssertEqual(ids, [existingID, "dl_b", "dl_c", "dl_a"], "跳过已完成/已存在，恢复任务按 position 排序追加")
        XCTAssertEqual(engine.tasks.map(\.position), [0, 1, 2, 3])
        XCTAssertFalse(engine.tasks.contains { $0.id == "dl_completed" }, "已完成任务不 restore")
        for restored in engine.tasks.dropFirst() {
            XCTAssertEqual(restored.status, "waiting")
            XCTAssertEqual(restored.statusText, "已恢复，等待继续")
            XCTAssertEqual(restored.progressTotal, 100)
            XCTAssertEqual(restored.fileName, "\(restored.id).zip")
        }

        // restore 不自动开始：只有手动 enqueue 的那一次请求
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertEqual(engine.tasks.filter { $0.status == "run" }.count, 1)

        // 重复 restore 幂等
        engine.restore(tasks: [taskA, taskB, taskC, existingSnapshot])
        XCTAssertEqual(engine.tasks.map(\.id), ids)
        XCTAssertEqual(engine.tasks.count, 4)

        // 清理
        engine.cancel(id: existingID)
        for restoredID in ["dl_a", "dl_b", "dl_c"] { engine.cancel(id: restoredID) }
    }
    // MARK: - 速度 / ETA

    @MainActor
    func testSpeedEtaFilledDuringDownloadAndClearedAfterCompletion() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data(repeating: 0x5A, count: 262_144)
        // 限速：每 8192 字节间隔 50ms → 约 160KB/s
        server.handler = { request in
            self.rangedResponse(body: payload, request: request, chunkSize: 8192, chunkDelay: 0.05)
        }

        let engine = DownloadEngine(maxConcurrent: 1)
        engine.enqueue(makeRequest(url: server.songURL, fileName: "速度测试", fileExtension: "zip"))

        await waitUntil("产生速度/ETA 估算") {
            guard let task = engine.tasks.first else { return false }
            return (task.speedBytesPerSecond ?? 0) > 0 && (task.etaSeconds ?? 0) > 0
        }
        let first = try XCTUnwrap(engine.tasks.first)
        let speed = try XCTUnwrap(first.speedBytesPerSecond)
        let eta = try XCTUnwrap(first.etaSeconds)
        XCTAssertGreaterThan(speed, 10_000, "限速服务器下应有可观速度")
        XCTAssertLessThan(speed, 2_000_000)
        XCTAssertGreaterThan(eta, 0, "未完成时应给出剩余时间")
        XCTAssertLessThan(first.progressDownloaded, first.progressTotal)
        // ETA 与「剩余字节 / 速度」应同量级（宽松）
        let estimated = Double(first.progressTotal - first.progressDownloaded) / speed
        XCTAssertLessThan(abs(eta - estimated), max(3.0, eta * 1.5))

        // 进度推进后 ETA 应递减（宽松轮询）
        var decreased = false
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let task = engine.tasks.first,
               let latestETA = task.etaSeconds,
               task.progressDownloaded > first.progressDownloaded {
                if latestETA < eta {
                    decreased = true
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(decreased, "ETA 应随下载进度递减")

        await waitUntil(timeout: 20, "下载完成") { engine.tasks.first?.isCompleted == true }
        let completed = try XCTUnwrap(engine.tasks.first)
        XCTAssertNil(completed.speedBytesPerSecond, "完成后 speed 置 nil")
        XCTAssertNil(completed.etaSeconds, "完成后 eta 置 nil")
    }

    @MainActor
    func testSpeedEtaNilWhileWaitingAndPaused() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data(repeating: 0x22, count: 131_072)
        server.handler = { request in
            self.rangedResponse(body: payload, request: request, chunkSize: 8192, chunkDelay: 0.05)
        }
        let engine = DownloadEngine(maxConcurrent: 1)
        engine.enqueue(makeRequest(url: server.songURL, fileName: "暂停速度", fileExtension: "zip"))
        await waitUntil("产生速度") { (engine.tasks.first?.speedBytesPerSecond ?? 0) > 0 }
        engine.pause(id: try XCTUnwrap(engine.tasks.first?.id))
        await waitUntil("暂停") { engine.tasks.first?.status == "pause" }
        let paused = try XCTUnwrap(engine.tasks.first)
        XCTAssertNil(paused.speedBytesPerSecond, "暂停后 speed 置 nil")
        XCTAssertNil(paused.etaSeconds, "暂停后 eta 置 nil")
    }

    // MARK: - .lrc 歌词文件

    private func decodeGB18030(_ data: Data) -> String? {
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        var bytes = [UInt8](data)
        return bytes.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress,
                  let cfString = CFStringCreateWithBytes(
                      kCFAllocatorDefault, base, data.count, cfEncoding, false
                  ) else { return nil }
            return cfString as String
        }
    }

    private func lrcURL(forAudioPath path: String) -> URL {
        URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("lrc")
    }

    @MainActor
    func testLrcFileUTF8WithBOMAndContent() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data((0..<2048).map { UInt8($0 % 251) })
        server.handler = { _ in TestHTTPServer.Response(status: 200, headers: ["Accept-Ranges": "bytes"], body: payload) }

        let engine = DownloadEngine(maxConcurrent: 1)
        let taskID = engine.enqueue(makeRequest(url: server.songURL, fileName: "歌词UTF8", fileExtension: "zip"))
        let content = "[ti:测试]\n[00:00.00]第一行歌词\n[00:01.50]第二行歌词"
        engine.setLrcFile(taskID: taskID, content: content, encoding: "utf8")

        await waitUntil("下载完成") { engine.tasks.first?.isCompleted == true }
        let audioPath = try XCTUnwrap(engine.tasks.first?.filePath)
        let lrcFile = lrcURL(forAudioPath: audioPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lrcFile.path), ".lrc 应与音频同目录同名")
        let data = try Data(contentsOf: lrcFile)
        XCTAssertEqual([UInt8](data.prefix(3)), [0xEF, 0xBB, 0xBF], "utf8 应写 BOM（与原版 iconv addBOM 一致）")
        XCTAssertEqual(String(data: Data(data.dropFirst(3)), encoding: .utf8), content)
        // 音频本身不受影响
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: audioPath)), payload)
    }

    @MainActor
    func testLrcFileGBKEncoding() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data(repeating: 0x11, count: 1024)
        server.handler = { _ in TestHTTPServer.Response(status: 200, headers: ["Accept-Ranges": "bytes"], body: payload) }

        let engine = DownloadEngine(maxConcurrent: 1)
        let taskID = engine.enqueue(makeRequest(url: server.songURL, fileName: "歌词GBK", fileExtension: "zip"))
        let content = "[ti:标题]\n[00:00.00]中文歌词，测试 GBK 转码"
        engine.setLrcFile(taskID: taskID, content: content, encoding: "gbk")

        await waitUntil("下载完成") { engine.tasks.first?.isCompleted == true }
        let audioPath = try XCTUnwrap(engine.tasks.first?.filePath)
        let data = try Data(contentsOf: lrcURL(forAudioPath: audioPath))
        XCTAssertFalse([UInt8](data.prefix(3)) == [0xEF, 0xBB, 0xBF], "GBK 不应写 UTF-8 BOM")
        XCTAssertNotEqual(data, Data(content.utf8), "GBK 字节应与 UTF-8 不同")
        XCTAssertEqual(decodeGB18030(data), content, "GBK 字节应能解码回原文")
    }

    @MainActor
    func testLrcFileUnknownTaskAndSetAfterCompletion() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data(repeating: 0x33, count: 512)
        server.handler = { _ in TestHTTPServer.Response(status: 200, headers: ["Accept-Ranges": "bytes"], body: payload) }

        let engine = DownloadEngine(maxConcurrent: 1)
        // 未知任务：只告警，不崩溃
        engine.setLrcFile(taskID: "not_exists", content: "x", encoding: "utf8")

        let taskID = engine.enqueue(makeRequest(url: server.songURL, fileName: "完成后歌词", fileExtension: "zip"))
        await waitUntil("下载完成") { engine.tasks.first?.isCompleted == true }
        let audioPath = try XCTUnwrap(engine.tasks.first?.filePath)
        let lrcFile = lrcURL(forAudioPath: audioPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lrcFile.path))

        // 完成后再调用 setLrcFile：立即落盘
        engine.setLrcFile(taskID: taskID, content: "[00:00.00]完成后补写", encoding: "utf8")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lrcFile.path), "已完成任务 setLrcFile 应立即写入")
        let data = try Data(contentsOf: lrcFile)
        XCTAssertEqual([UInt8](data.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(String(data: Data(data.dropFirst(3)), encoding: .utf8), "[00:00.00]完成后补写")
    }

    @MainActor
    func testLrcFileWriteFailureDoesNotAffectDownloadCompletion() async throws {
        let server = try TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let payload = Data(repeating: 0x44, count: 4096)
        server.handler = { _ in TestHTTPServer.Response(status: 200, headers: ["Accept-Ranges": "bytes"], body: payload) }

        let fileName = "lrc写入失败"
        // 先用同名目录占住 .lrc 路径，让写文件失败（EISDIR）
        let lrcPath = tempDirectory.appendingPathComponent("\(fileName).lrc", isDirectory: true)
        try FileManager.default.createDirectory(at: lrcPath, withIntermediateDirectories: true)

        let engine = DownloadEngine(maxConcurrent: 1)
        var events: [DownloadEvent] = []
        engine.eventHandler = { events.append($0) }
        let taskID = engine.enqueue(makeRequest(url: server.songURL, fileName: fileName, fileExtension: "zip"))
        engine.setLrcFile(taskID: taskID, content: "[00:00.00]写不进去", encoding: "utf8")

        await waitUntil("下载完成（歌词写失败不影响）") { engine.tasks.first?.isCompleted == true }
        let audioPath = try XCTUnwrap(engine.tasks.first?.filePath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: audioPath)), payload)
        XCTAssertTrue(events.contains { if case .completed = $0 { return true } else { return false } })
        // 路径仍是目录（写入被拒绝，没有被替换成文件）
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: lrcPath.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
