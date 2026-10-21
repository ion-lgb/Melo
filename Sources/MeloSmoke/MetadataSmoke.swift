import Foundation
import MeloCore
import MeloJS

/// 内置元数据源的 Swift 侧真实网络冒烟测试（独立于 UI）：
/// JSMetadataService（JavaScriptCore + 原生 HTTP/crypto 桥）→ 真实平台搜索/榜单/歌词。
/// 用于验证「Swift 桥 + musicSdk bundle + 真实网络」全链路。
struct MetadataSmokeResult {
    var lines: [String] = []
    var failures: [String] = []
}

@MainActor
final class MetadataSmokeRunner {
    let query: String
    let resources: URL
    private let service: JSMetadataService
    private let box: SmokeBox
    private var report = MetadataSmokeResult()

    init(query: String, resources: URL, box: SmokeBox) {
        self.query = query
        self.resources = resources
        self.box = box
        self.service = JSMetadataService(resourcesDirectory: resources)
    }

    func run() async throws {
        do {
            try await service.prepare()
            check(service.isReady, "JSMetadataService.prepare() 就绪")
            check(service.sources.count == 5, "内置源数量 = \(service.sources.count): \(service.sources.map(\.id).joined(separator: "/"))")
        } catch {
            throw SmokeError("内置音源初始化失败：\(error.localizedDescription)")
        }

        // 1. 热搜
        do {
            let words = try await service.hotSearch(source: "kw")
            check(!words.isEmpty, "kw 热搜词 \(words.count) 个（前 3: \(words.prefix(3).joined(separator: ", "))）")
        } catch {
            report.failures.append("kw 热搜失败：\(error.localizedDescription)")
        }

        // 2. 五源搜索
        var kwFirst: MusicInfo?
        for source in ["kw", "kg", "tx", "wy", "mg"] {
            do {
                let started = Date()
                let page = try await service.searchMusic(keyword: query, source: source, page: 1, limit: 5)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let sample = page.list.prefix(2).map { "\($0.name)-\($0.singer)" }.joined(separator: " / ")
                check(!page.list.isEmpty, "\(source) 搜索「\(query)」→ \(page.list.count) 条 / total \(page.total) / \(ms)ms / \(sample)")
                if source == "kw" { kwFirst = page.list.first }
            } catch {
                report.failures.append("\(source) 搜索失败：\(error.localizedDescription)")
                report.lines.append("FAIL \(source) 搜索：\(error.localizedDescription)")
            }
        }

        // 3. 榜单
        do {
            let boards = try await service.leaderboards(source: "kg")
            check(boards.count > 20, "kg 榜单 \(boards.count) 个（首个: \(boards.first?.name ?? "-")）")
            if let board = boards.first {
                let page = try await service.leaderboardMusics(boardId: board.id, page: 1, limit: 10)
                check(!page.list.isEmpty, "kg 榜单「\(board.name)」首页 \(page.list.count) 首")
            }
        } catch {
            report.failures.append("kg 榜单失败：\(error.localizedDescription)")
        }

        // 4. 歌单广场
        do {
            let sorts = try await service.songListSorts(source: "kg")
            let tags = try await service.songListTags(source: "kg")
            check(!sorts.isEmpty && !tags.isEmpty, "kg 歌单广场 sorts \(sorts.count) / tagGroups \(tags.groups.count) / hot \(tags.hot.count)")
            if let sort = sorts.first {
                let page = try await service.songLists(source: "kg", tagId: "", sortId: sort.id, page: 1, limit: 10)
                check(!page.list.isEmpty, "kg 歌单列表 \(page.list.count) 个（首个: \(page.list.first?.name ?? "-") id=\(page.list.first?.id ?? "-")）")
                if let first = page.list.first {
                    let detail = try await service.songListDetail(id: first.id, source: "kg", page: 1, limit: 10)
                    check(!detail.page.list.isEmpty, "kg 歌单详情「\(detail.info.name)」\(detail.page.list.count) 首")
                }
            }
        } catch {
            report.failures.append("kg 歌单失败：\(error.localizedDescription)")
        }

        // 5. 歌词
        if let music = kwFirst {
            do {
                let lyric = try await service.lyric(musicInfo: music)
                let document = LyricParser.parse(lyric?.lyric ?? "", translated: lyric?.tlyric, roman: lyric?.rlyric, wordByWord: lyric?.lxlyric)
                check(!document.isEmpty, "kw 歌词「\(music.name)」\(document.lines.count) 行" + ((lyric?.lxlyric?.isEmpty == false) ? "（含逐字）" : ""))
            } catch {
                report.failures.append("kw 歌词失败：\(error.localizedDescription)")
            }
        }

        box.check(report.failures.isEmpty, "MeloSmoke 元数据检查全部通过（失败 \(report.failures.count) 项）")
        for line in report.lines { box.lines.append(line) }
        if !report.failures.isEmpty {
            throw SmokeError("\(report.failures.count) 项元数据检查失败")
        }
    }

    private func check(_ condition: Bool, _ message: String) {
        if condition {
            report.lines.append("OK  \(message)")
        } else {
            report.failures.append(message)
            report.lines.append("FAIL \(message)")
        }
    }
}
