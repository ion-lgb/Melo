import Foundation
import MeloCore
import MeloData

/// 把 MeloData.CacheManager 适配成 MeloCore.CacheManaging（MeloCore 不依赖数据层）。
@MainActor
final class MeloCacheService: CacheManaging {
    private let manager: CacheManager

    init(dataDirectory: URL) {
        self.manager = CacheManager(dataDirectory: dataDirectory)
    }

    func cacheCategories() -> [CacheCategoryInfo] {
        manager.categories().map {
            CacheCategoryInfo(id: $0.id, name: $0.name, sizeBytes: $0.sizeBytes, fileCount: $0.fileCount)
        }
    }

    func clearCache(categoryID: String) throws -> Int {
        try manager.clear(categoryID: categoryID)
    }

    var totalCacheSizeBytes: Int64 { manager.totalSizeBytes() }
}
