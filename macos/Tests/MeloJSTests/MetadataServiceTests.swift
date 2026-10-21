import XCTest
import Foundation
import MeloCore
@testable import MeloJS

/// JSMetadataService 测试：
/// - 离线：真实 bundle 的 prepare/排行榜/排序（静态数据，不发网络请求）
/// - 桩 bundle：JSON 解析、错误、超时、缺少资源
/// - 在线：默认跳过，设置 MELO_ONLINE_TESTS=1 才执行（CI 不依赖网络）
final class MetadataServiceTests: XCTestCase {

    private static var macosRoot: URL {
        URL(fileURLWithPath: #filePath) // Tests/MeloJSTests/xxx.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var resourcesDirectory: URL {
        macosRoot.appendingPathComponent("Resources", isDirectory: true)
    }

    private static var stubBundleURL: URL {
        // 桩 bundle 放在 tools 构建工程内（避免成为测试 target 的 unhandled resource）
        macosRoot
            .appendingPathComponent("tools/musicSdk-bundle/fixtures/stub-metadata-bundle.js")
    }

    /// 把桩 bundle 放进临时 Resources/js/musicSdk.bundle.js，模拟 App 资源目录结构
    @MainActor
    private func makeStubService() throws -> (service: JSMetadataService, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-metadata-tests-\(UUID().uuidString)", isDirectory: true)
        let jsDirectory = root.appendingPathComponent("js", isDirectory: true)
        try FileManager.default.createDirectory(at: jsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Self.stubBundleURL,
            to: jsDirectory.appendingPathComponent("musicSdk.bundle.js")
        )
        return (JSMetadataService(resourcesDirectory: root), root)
    }

    // MARK: - 离线：真实 bundle

    @MainActor
    func testPrepareAndBuiltinSources() async throws {
        let service = JSMetadataService(resourcesDirectory: Self.resourcesDirectory)
        XCTAssertFalse(service.isReady)
        XCTAssertEqual(service.sources.map(\.id), ["kw", "kg", "tx", "wy", "mg"])

        try await service.prepare()
        XCTAssertTrue(service.isReady)
        XCTAssertEqual(service.sources.map(\.id), ["kw", "kg", "tx", "wy", "mg"])
        XCTAssertEqual(service.sources.first?.name, "酷我音乐")

        // 幂等
        try await service.prepare()
        XCTAssertTrue(service.isReady)
    }

    @MainActor
    func testBundleProvidesMissingBrowserGlobals() async throws {
        let service = JSMetadataService(resourcesDirectory: Self.resourcesDirectory)
        try await service.prepare()
        // wy 的 form 请求依赖 URLSearchParams（JSC 原生缺失，bundle globals.js 提供 polyfill）
        XCTAssertEqual(service.evaluateForTesting("typeof URLSearchParams"), "function")
        XCTAssertEqual(service.evaluateForTesting("typeof URL"), "function")
        XCTAssertEqual(service.evaluateForTesting("typeof TextEncoder"), "function")
        XCTAssertEqual(service.evaluateForTesting("typeof TextDecoder"), "function")
        XCTAssertEqual(service.evaluateForTesting("typeof Buffer"), "function")
        XCTAssertEqual(service.evaluateForTesting("typeof setTimeout"), "function")
        // 实际构造一次，确保 polyfill 可用
        XCTAssertEqual(service.evaluateForTesting("new URLSearchParams({a:'1',b:'2'}).toString()"), "a=1&b=2")
    }

    @MainActor
    func testBundleExposesCommentMethods() async throws {
        let service = JSMetadataService(resourcesDirectory: Self.resourcesDirectory)
        try await service.prepare()
        XCTAssertEqual(service.evaluateForTesting("typeof MeloMetadata.comments"), "function")
        XCTAssertEqual(service.evaluateForTesting("typeof MeloMetadata.hotComments"), "function")
    }

    @MainActor
    func testOfflineLeaderboardsAreStatic() async throws {
        let service = JSMetadataService(resourcesDirectory: Self.resourcesDirectory)
        try await service.prepare()
        let expectedCounts: [String: Int] = ["kw": 43, "kg": 51, "tx": 25, "wy": 42, "mg": 10]
        for source in ["kw", "kg", "tx", "wy", "mg"] {
            let boards = try await service.leaderboards(source: source)
            XCTAssertEqual(boards.count, expectedCounts[source], "\(source) 排行榜数量")
            XCTAssertTrue(boards.allSatisfy { $0.id.hasPrefix(source + "__") && !$0.name.isEmpty })
        }
        let kwFirst = try await service.leaderboards(source: "kw").first
        XCTAssertEqual(kwFirst?.id, "kw__93")
        XCTAssertEqual(kwFirst?.name, "飙升榜")
    }

    @MainActor
    func testOfflineSongListSortsAreStatic() async throws {
        let service = JSMetadataService(resourcesDirectory: Self.resourcesDirectory)
        try await service.prepare()
        let kwSorts = try await service.songListSorts(source: "kw")
        XCTAssertEqual(kwSorts.map(\.id), ["new", "hot"])
        XCTAssertEqual(kwSorts.map(\.name), ["最新", "最热"])
        let kgSorts = try await service.songListSorts(source: "kg")
        XCTAssertEqual(kgSorts.count, 5)
        for source in ["kw", "kg", "tx", "wy", "mg"] {
            let sorts = try await service.songListSorts(source: source)
            XCTAssertFalse(sorts.isEmpty, "\(source) 排序为空")
        }
    }

    // MARK: - 桩 bundle：解析 / 错误 / 超时

    @MainActor
    func testStubDecodingAllMethods() async throws {
        let (service, root) = try makeStubService()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.prepare()
        XCTAssertTrue(service.isReady)
        XCTAssertEqual(service.sources.map(\.id), ["stub"])

        let stubHot = try await service.hotSearch(source: "stub")
        XCTAssertEqual(stubHot, ["stub-hot-1", "stub-hot-2", "stub"])

        let musicPage = try await service.searchMusic(keyword: "x", source: "stub", page: 1, limit: 30)
        XCTAssertEqual(musicPage.total, 1)
        XCTAssertEqual(musicPage.list.first?.name, "Stub 歌曲")
        XCTAssertEqual(musicPage.list.first?.meta["albumName"]?.stringValue, "Stub 专辑")
        XCTAssertEqual(musicPage.list.first?.qualitys.first?.type, "128k")

        let songListPage = try await service.searchSongList(keyword: "x", source: "stub", page: 1, limit: 20)
        XCTAssertEqual(songListPage.list.first?.name, "Stub 歌单")
        XCTAssertEqual(songListPage.list.first?.playCount, "100")

        let boards = try await service.leaderboards(source: "stub")
        XCTAssertEqual(boards.first?.id, "stub__1")
        let boardMusics = try await service.leaderboardMusics(boardId: "stub__1", page: 1, limit: 100)
        XCTAssertEqual(boardMusics.list.first?.name, "Stub 歌曲")

        let sorts = try await service.songListSorts(source: "stub")
        XCTAssertEqual(sorts.first?.id, "new")
        let tags = try await service.songListTags(source: "stub")
        XCTAssertEqual(tags.groups.first?.name, "Stub 分类")
        XCTAssertEqual(tags.hot.first?.id, "hot1")

        let lists = try await service.songLists(source: "stub", tagId: "t", sortId: "new", page: 1, limit: 20)
        XCTAssertEqual(lists.list.first?.id, "sl_2")
        let detail = try await service.songListDetail(id: "sl_3", source: "stub", page: 1, limit: 200)
        XCTAssertEqual(detail.info.name, "Stub 歌单详情")
        XCTAssertEqual(detail.page.list.count, 1)

        let lyric = try await service.lyric(musicInfo: MusicInfo(
            id: "stub_1", name: "Stub", singer: "Stub", source: "stub",
            interval: "00:10", meta: .object(["songId": .string("1")])
        ))
        XCTAssertEqual(lyric?.lyric, "[00:00.00]stub lyric")
        XCTAssertEqual(lyric?.lxlyric, "[00:00.00]<0,10>stub")
    }

    @MainActor
    func testStubCommentsDecoding() async throws {
        let (service, root) = try makeStubService()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.prepare()

        let music = MusicInfo(
            id: "stub_1", name: "Stub 歌曲", singer: "Stub 歌手", source: "stub",
            interval: "00:10", meta: .object(["songId": .string("1")])
        )
        let page = try await service.comments(musicInfo: music, page: 1, limit: 10)
        XCTAssertEqual(page.source, "stub")
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.page, 1)
        XCTAssertEqual(page.limit, 10)
        XCTAssertEqual(page.maxPage, 1)
        XCTAssertEqual(page.comments.count, 2)

        let first = try XCTUnwrap(page.comments.first)
        XCTAssertEqual(first.id, "1001")               // 数字 id → String
        XCTAssertEqual(first.text, "第一条评论")
        XCTAssertEqual(first.time, 1_700_000_000)      // 秒级时间戳
        XCTAssertEqual(first.timeStr, "2023-11-15 06:13")
        XCTAssertEqual(first.location, "广东")
        XCTAssertEqual(first.userName, "用户A")
        XCTAssertEqual(first.avatar, "https://example.com/a.jpg")
        XCTAssertEqual(first.userId, "42")             // 数字 userId → String
        XCTAssertEqual(first.likedCount, 7)            // 字符串 likedCount → Int
        let reply = try XCTUnwrap(first.reply)
        XCTAssertEqual(reply.id, "r1")
        XCTAssertEqual(reply.text, "回复内容")
        XCTAssertEqual(reply.userName, "用户B")
        XCTAssertNil(reply.avatar)
        XCTAssertEqual(reply.userId, "88")
        XCTAssertEqual(reply.likedCount, 2)
        XCTAssertEqual(reply.location, "北京")

        let second = page.comments[1]
        XCTAssertEqual(second.id, "1002")
        XCTAssertNil(second.time)
        XCTAssertNil(second.timeStr)
        XCTAssertNil(second.location)
        XCTAssertNil(second.reply)                     // 空 reply 数组 → nil
        XCTAssertEqual(second.likedCount, 0)

        let hot = try await service.hotComments(musicInfo: music, limit: 5)
        XCTAssertEqual(hot.source, "stub")
        XCTAssertEqual(hot.total, 1)
        XCTAssertEqual(hot.page, 1)
        XCTAssertEqual(hot.limit, 5)
        let hotFirst = try XCTUnwrap(hot.comments.first)
        XCTAssertEqual(hotFirst.id, "h1")
        XCTAssertEqual(hotFirst.likedCount, 99)
        XCTAssertEqual(hotFirst.reply?.id, "hr")       // reply 数组 → 取首条
        XCTAssertEqual(hotFirst.reply?.likedCount, 3)
    }

    @MainActor
    func testStubCommentsErrorMapping() async throws {
        let (service, root) = try makeStubService()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.prepare()

        let throwMusic = MusicInfo(
            id: "stub_throw", name: "Throw", singer: "x", source: "throw",
            interval: nil, meta: .object([:])
        )
        do {
            _ = try await service.comments(musicInfo: throwMusic, page: 1, limit: 5)
            XCTFail("JS 抛错应转为 MetadataError")
        } catch let error as MetadataError {
            guard case .scriptError(let message) = error else {
                return XCTFail("应为 scriptError，实际：\(error)")
            }
            XCTAssertTrue(message.contains("获取评论失败"), "错误信息：\(message)")
        }

        let unsupportedMusic = MusicInfo(
            id: "stub_unsupported", name: "Unsupported", singer: "x", source: "unsupported",
            interval: nil, meta: .object([:])
        )
        do {
            _ = try await service.comments(musicInfo: unsupportedMusic, page: 1, limit: 5)
            XCTFail("不支持评论的音源应抛出 unsupported")
        } catch let error as MetadataError {
            guard case .unsupported(let message) = error else {
                return XCTFail("应为 unsupported，实际：\(error)")
            }
            XCTAssertTrue(message.contains("不支持评论"), "错误信息：\(message)")
        }

        do {
            _ = try await service.hotComments(musicInfo: throwMusic, limit: 5)
            XCTFail("热门评论 JS 抛错应转为 MetadataError")
        } catch let error as MetadataError {
            XCTAssertTrue(error.localizedDescription.contains("热门评论"), "错误信息：\(error.localizedDescription)")
        }
    }

    @MainActor
    func testCommentsRequireReadyAndKnownSource() async throws {
        let notReady = JSMetadataService(resourcesDirectory: Self.resourcesDirectory)
        let music = MusicInfo(
            id: "stub_1", name: "Stub", singer: "Stub", source: "stub",
            interval: "00:10", meta: .object(["songId": .string("1")])
        )
        do {
            _ = try await notReady.comments(musicInfo: music, page: 1, limit: 5)
            XCTFail("未 prepare 应抛 notReady")
        } catch let error as MetadataError {
            guard case .notReady = error else {
                return XCTFail("应为 notReady，实际：\(error)")
            }
        }

        let (service, root) = try makeStubService()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.prepare()
        let unknownSource = MusicInfo(
            id: "unknown_1", name: "未知", singer: "x", source: "",
            interval: nil, meta: .object([:])
        )
        do {
            _ = try await service.comments(musicInfo: unknownSource, page: 1, limit: 5)
            XCTFail("无法识别音源应抛 unsupported")
        } catch let error as MetadataError {
            guard case .unsupported(let message) = error else {
                return XCTFail("应为 unsupported，实际：\(error)")
            }
            XCTAssertTrue(message.contains("无法确定"), "错误信息：\(message)")
        }
    }

    @MainActor
    func testStubErrorMapping() async throws {
        let (service, root) = try makeStubService()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.prepare()
        do {
            _ = try await service.hotSearch(source: "throw")
            XCTFail("桩抛出错误应转为 MetadataError")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stub failure"), "错误信息：\(error.localizedDescription)")
            XCTAssertTrue(error is MetadataError)
        }
    }

    @MainActor
    func testStubTimeout() async throws {
        let (service, root) = try makeStubService()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.prepare()
        service.requestTimeout = 0.3
        let start = Date()
        do {
            _ = try await service.hotSearch(source: "never")
            XCTFail("永不返回应超时")
        } catch let error as MetadataError {
            guard case .timeout = error else {
                return XCTFail("应为 timeout，实际：\(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.25)
        XCTAssertLessThan(elapsed, 5)
    }

    @MainActor
    func testNotReadyAndMissingBundle() async throws {
        // 资源目录不存在 bundle
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-metadata-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        let service = JSMetadataService(resourcesDirectory: emptyRoot)
        do {
            try await service.prepare()
            XCTFail("缺少 bundle 应 prepare 失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("musicSdk.bundle.js"))
        }
        do {
            _ = try await service.hotSearch(source: "kw")
            XCTFail("未 ready 应抛 notReady")
        } catch let error as MetadataError {
            guard case .notReady = error else {
                return XCTFail("应为 notReady，实际：\(error)")
            }
        }
    }

    // MARK: - 在线（默认跳过，CI 不依赖网络）

    @MainActor
    func testOnlineKwHotSearchAndSearch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MELO_ONLINE_TESTS"] == "1",
                          "需要真实网络：MELO_ONLINE_TESTS=1 swift test --filter MetadataServiceTests")
        let service = JSMetadataService(resourcesDirectory: Self.resourcesDirectory)
        service.requestTimeout = 30
        try await service.prepare()

        let hot = try await service.hotSearch(source: "kw")
        print("[online] kw 热搜 top5:", hot.prefix(5).map { $0 })
        XCTAssertFalse(hot.isEmpty)

        let page = try await service.searchMusic(keyword: "周杰伦", source: "kw", page: 1, limit: 3)
        print("[online] kw 搜索「周杰伦」 total=\(page.total) allPage=\(page.allPage) source=\(page.source ?? "-")")
        XCTAssertFalse(page.list.isEmpty)
        for (index, item) in page.list.prefix(3).enumerated() {
            print("[online]   \(index + 1). \(item.name) / \(item.singer)  id=\(item.id)  songId=\(item.meta["songId"]?.displayString ?? "-")")
            XCTAssertFalse(item.name.isEmpty)
            XCTAssertFalse(item.id.isEmpty)
            XCTAssertNotNil(item.meta["songId"]?.stringValue)
        }
    }

    @MainActor
    func testOnlineWySearchWithRetry() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MELO_ONLINE_TESTS"] == "1",
                          "需要真实网络：MELO_ONLINE_TESTS=1")
        let service = JSMetadataService(resourcesDirectory: Self.resourcesDirectory)
        service.requestTimeout = 30
        try await service.prepare()
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let page = try await service.searchMusic(keyword: "周杰伦", source: "wy", page: 1, limit: 3)
                print("[online] wy 搜索第 \(attempt) 次成功：total=\(page.total)，首条=\(page.list.first?.name ?? "-") / \(page.list.first?.singer ?? "-")")
                XCTAssertFalse(page.list.isEmpty)
                return
            } catch {
                lastError = error
                print("[online] wy 搜索第 \(attempt) 次失败：\(error.localizedDescription)")
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
        throw lastError ?? MetadataError.scriptError("wy 搜索失败")
    }

    @MainActor
    func testOnlineWyComments() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MELO_ONLINE_TESTS"] == "1",
                          "需要真实网络：MELO_ONLINE_TESTS=1")
        let service = JSMetadataService(resourcesDirectory: Self.resourcesDirectory)
        service.requestTimeout = 30
        try await service.prepare()

        var music: MusicInfo?
        var lastSearchError: Error?
        for attempt in 1...3 {
            do {
                let page = try await service.searchMusic(keyword: "晴天 周杰伦", source: "wy", page: 1, limit: 10)
                let sample = page.list.first.map { "\($0.name) / \($0.singer)" } ?? "-"
                print("[online] wy 评论测试搜索第 \(attempt) 次成功：\(sample)")
                let exact = page.list.first { item in
                    item.name.contains("晴天") && item.singer.contains("周杰伦")
                }
                let fallback = page.list.first(where: { $0.meta["songId"]?.stringValue != nil }) ?? page.list.first
                if let hit = exact ?? fallback {
                    music = hit
                    break
                }
            } catch {
                lastSearchError = error
                print("[online] wy 搜索第 \(attempt) 次失败：\(error.localizedDescription)")
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
        guard let music else {
            throw lastSearchError ?? MetadataError.scriptError("wy 搜索「晴天」失败")
        }
        print("[online] 评论歌曲：\(music.name) / \(music.singer) songId=\(music.meta["songId"]?.stringValue ?? "-")")

        var page: CommentPage?
        var lastCommentError: Error?
        for attempt in 1...3 {
            do {
                page = try await service.comments(musicInfo: music, page: 1, limit: 5)
                break
            } catch {
                lastCommentError = error
                print("[online] wy 评论第 \(attempt) 次失败：\(error.localizedDescription)")
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
        guard let page else {
            throw XCTSkip("wy 评论接口暂不可用：\(lastCommentError?.localizedDescription ?? "未知错误")")
        }
        print("[online] wy 评论 total=\(page.total) page=\(page.page) limit=\(page.limit) maxPage=\(page.maxPage) 返回=\(page.comments.count) 条")
        XCTAssertEqual(page.source, "wy")
        XCTAssertGreaterThan(page.total, 0)
        XCTAssertFalse(page.comments.isEmpty, "晴天应有评论")
        XCTAssertEqual(page.page, 1)
        XCTAssertEqual(page.limit, 5)
        XCTAssertGreaterThanOrEqual(page.maxPage, 1)
        for (index, item) in page.comments.prefix(3).enumerated() {
            print("[online]   评论\(index + 1): \(item.userName)（赞\(item.likedCount)）: \(item.text.prefix(30))")
            XCTAssertFalse(item.id.isEmpty)
            XCTAssertFalse(item.text.isEmpty)
            XCTAssertFalse(item.userName.isEmpty)
            XCTAssertGreaterThanOrEqual(item.likedCount, 0)
        }

        do {
            let hot = try await service.hotComments(musicInfo: music, limit: 5)
            print("[online] wy 热门评论 total=\(hot.total) page=\(hot.page) limit=\(hot.limit) 返回=\(hot.comments.count) 条")
            XCTAssertEqual(hot.source, "wy")
            XCTAssertEqual(hot.page, 1)
            XCTAssertEqual(hot.limit, 5)
            if let first = hot.comments.first {
                print("[online]   热评: \(first.userName)（赞\(first.likedCount)）: \(first.text.prefix(30))")
            }
        } catch {
            // 在线接口可能波动：热门评论失败不 fail 整个用例
            print("[online] wy 热门评论接口失败（跳过该 case）：\(error.localizedDescription)")
        }
    }
}
