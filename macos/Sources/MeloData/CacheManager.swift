import Foundation
import MeloCore

// MARK: - 缓存类别

/// 缓存类别 id（`CacheManager.clear(categoryID:)` 使用）。
public enum CacheCategoryID: String, Sendable, CaseIterable {
    /// 本地音乐封面缓存：`<LxDatas>/covers`
    case covers = "covers"
    /// 音效/卷积混响渲染缓存：`~/Library/Caches/Melo/EffectsAudio`（可注入）
    case effectAudio = "effectAudio"
    /// 下载临时文件：`<LxDatas>/download_temp`（当前下载引擎直接写目标文件，通常不存在）
    case downloadTemp = "downloadTemp"
}

/// 单个缓存类别的统计信息。
public struct CacheCategory: Equatable, Sendable {
    /// 类别 id（见 `CacheCategoryID`，也允许未来扩展）
    public let id: String
    /// 展示名称（中文，可直接用于设置页）
    public let name: String
    /// 类别目录绝对路径
    public let path: URL
    /// 递归统计的字节数（跳过符号链接）
    public let sizeBytes: Int64
    /// 递归统计的文件数（跳过符号链接）
    public let fileCount: Int

    public init(id: String, name: String, path: URL, sizeBytes: Int64, fileCount: Int) {
        self.id = id
        self.name = name
        self.path = path
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
    }

    /// 人类可读大小（与 UI 展示/日志一致）
    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: - 错误

public enum CacheManagerError: LocalizedError, Equatable {
    case unknownCategory(String)
    case clearFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownCategory(let id):
            return "未知的缓存类别：\(id)"
        case .clearFailed(let message):
            return "清理缓存失败：\(message)"
        }
    }
}

// MARK: - 缓存管理

/// 本地缓存统计与清理（对应设置页「清除缓存」）。
///
/// 只清理**可由程序重新生成**的缓存目录内容，保留目录本身：
/// - `covers`：本地音乐封面缓存 `<LxDatas>/covers`；
/// - `effectAudio`：音效/混响渲染缓存，默认 `~/Library/Caches/Melo/EffectsAudio`（可注入）；
/// - `downloadTemp`：下载临时文件 `<LxDatas>/download_temp`（当前引擎直接写目标文件，通常不存在）。
///
/// 安全约束：核心数据（`lx.data.db`、`config_v2.json`、`user_api.json`、`theme.json`、`hot_key` 等）
/// 均不在任何缓存类别目录内，`clear` 永远不会触碰；统计/清理跳过符号链接，避免统计到外部文件或误删。
public final class CacheManager {
    public let dataDirectory: URL
    public let effectsCacheDirectory: URL

    private struct CategoryDescriptor {
        let id: String
        let name: String
        let path: URL
    }

    /// - Parameters:
    ///   - dataDirectory: 原版 `LxDatas` 目录
    ///   - effectsCacheDirectory: 音效缓存目录（测试/自定义注入）；nil 时使用默认缓存目录
    public init(dataDirectory: URL, effectsCacheDirectory: URL? = nil) {
        self.dataDirectory = dataDirectory
        if let effectsCacheDirectory {
            self.effectsCacheDirectory = effectsCacheDirectory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            self.effectsCacheDirectory = (caches ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("Melo", isDirectory: true)
                .appendingPathComponent("EffectsAudio", isDirectory: true)
        }
    }

    /// 所有缓存类别的当前统计（目录不存在时 size/fileCount 均为 0，仍会列出该类别）。
    public func categories() -> [CacheCategory] {
        descriptors.map { descriptor in
            let stats = Self.directoryStats(at: descriptor.path)
            return CacheCategory(
                id: descriptor.id,
                name: descriptor.name,
                path: descriptor.path,
                sizeBytes: stats.sizeBytes,
                fileCount: stats.fileCount
            )
        }
    }

    /// 单个类别统计；未知 id 返回 nil。
    public func category(id: String) -> CacheCategory? {
        categories().first { $0.id == id }
    }

    /// 全部缓存合计字节数。
    public func totalSizeBytes() -> Int64 {
        categories().reduce(0) { $0 + $1.sizeBytes }
    }

    /// 清理指定类别：删除目录内所有内容、保留目录本身，返回清理前统计的释放字节数。
    /// - 未知 categoryID 抛 `CacheManagerError.unknownCategory`；
    /// - 目录不存在/为空返回 0；部分文件删除失败时抛 `clearFailed`（已删除的部分不回滚）。
    @discardableResult
    public func clear(categoryID: String) throws -> Int {
        guard let descriptor = descriptors.first(where: { $0.id == categoryID }) else {
            throw CacheManagerError.unknownCategory(categoryID)
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: descriptor.path.path) else { return 0 }

        let freedBytes = Self.directoryStats(at: descriptor.path).sizeBytes
        let children = (try? fileManager.contentsOfDirectory(
            at: descriptor.path,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )) ?? []

        var failures: [String] = []
        for child in children {
            do {
                // removeItem 删除符号链接本身，不会顺着链接删除外部目标
                try fileManager.removeItem(at: child)
            } catch {
                failures.append("\(child.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw CacheManagerError.clearFailed(failures.joined(separator: "；"))
        }
        return Int(clamping: freedBytes)
    }

    // MARK: - 内部

    private var descriptors: [CategoryDescriptor] {
        [
            CategoryDescriptor(
                id: CacheCategoryID.covers.rawValue,
                name: "本地音乐封面",
                path: dataDirectory.appendingPathComponent("covers", isDirectory: true)
            ),
            CategoryDescriptor(
                id: CacheCategoryID.effectAudio.rawValue,
                name: "音效/混响缓存",
                path: effectsCacheDirectory
            ),
            CategoryDescriptor(
                id: CacheCategoryID.downloadTemp.rawValue,
                name: "下载临时文件",
                path: dataDirectory.appendingPathComponent("download_temp", isDirectory: true)
            ),
        ]
    }

    /// 递归统计目录：跳过符号链接，只统计普通文件。
    private static func directoryStats(at url: URL) -> (sizeBytes: Int64, fileCount: Int) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return (0, 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return (0, 0)
        }

        var sizeBytes: Int64 = 0
        var fileCount = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true { continue } // 不计入符号链接（也不顺着链接统计）
            guard values?.isRegularFile == true else { continue }
            fileCount += 1
            sizeBytes += Int64(values?.fileSize ?? 0)
        }
        return (sizeBytes, fileCount)
    }
}
