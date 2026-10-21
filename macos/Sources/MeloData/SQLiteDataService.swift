import Foundation
import MeloCore

// MARK: - 数据层错误

/// MeloData 对外错误（LocalizedError，便于 UI 直接展示）。
public enum MeloDataError: LocalizedError, Equatable {
    case notBootstrapped
    case databaseOpenFailed(String)
    case incompatibleDatabase(String)
    case invalidListName
    case invalidArgument(String)
    case listNotFound(String)
    case corruptedData(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .notBootstrapped:
            return "数据库尚未初始化"
        case .databaseOpenFailed(let message):
            return "打开数据库失败：\(message)"
        case .incompatibleDatabase(let message):
            return "数据库结构与原版不兼容：\(message)"
        case .invalidListName:
            return "列表名称不能为空"
        case .invalidArgument(let message):
            return "参数无效：\(message)"
        case .listNotFound(let id):
            return "列表不存在：\(id)"
        case .corruptedData(let message):
            return "数据损坏：\(message)"
        case .ioError(let message):
            return "文件读写失败：\(message)"
        }
    }
}

// MARK: - 数据服务实现

/// SQLite 数据层：直接读写原版 LX Music 的 `LxDatas/lx.data.db`。
///
/// 设计要点（与原版 `src/main/worker/dbService` 对齐）：
/// - 原版 DDL：9 张表 + 3 个索引（`DatabaseSchema`），`db_info.version='2'`，WAL 模式；
/// - 老库（version '1'）按原版 `migrate.ts` 补齐 `dislike_list` 后升级 version，绝不重建用户库；
/// - 列表/歌曲/排序表语义与 `modules/list` 一致（order 算法、UNIQUE 去重、级联删除、事务）；
/// - 歌词 `text` 列与原版一致地存 base64(UTF-8)，对外 API 收发明文；
/// - URL 缓存 id 为 `${musicId}_${quality}`，保存用「先删后插」；
/// - `meta` 列用 `JSONValue` 承载，未知字段原样读写，不丢原版字段。
///
/// 线程模型：整个类 `@MainActor`（协议即 `@MainActor`），所有 SQL 串行执行。
@MainActor
public final class SQLiteDataService: DataService {
    /// 原版 `LxDatas` 目录（数据库就放在这里）
    public let dataDirectory: URL

    /// 数据库文件路径：`<LxDatas>/lx.data.db`
    public var databasePath: URL {
        dataDirectory.appendingPathComponent("lx.data.db", isDirectory: false)
    }

    /// 最近一次 bootstrap 的结构校验结果（nil 表示尚未成功初始化）
    public private(set) var verification: DatabaseSchemaVerification?

    private var database: SQLiteDatabase?

    /// 是否已完成 `bootstrap()`（数据库已打开）
    public var isBootstrapped: Bool { database != nil }

    /// - Parameter dataDirectory: 原版 `LxDatas` 目录；默认 `<userData>/lx-music-desktop/LxDatas`
    public init(dataDirectory: URL? = nil) {
        self.dataDirectory = dataDirectory
            ?? ResourceLocator.lxDatasDirectory(in: ResourceLocator.defaultDataDirectory())
    }

    // MARK: - 初始化 / 迁移

    public func bootstrap() throws {
        guard database == nil else { return }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        } catch {
            throw MeloDataError.databaseOpenFailed(
                "无法创建数据目录 \(dataDirectory.path)：\(error.localizedDescription)"
            )
        }

        let opened: SQLiteDatabase
        do {
            opened = try SQLiteDatabase(path: databasePath.path)
        } catch {
            throw MeloDataError.databaseOpenFailed(error.localizedDescription)
        }

        do {
            let hasDatabaseInfo = try opened.tableExists("db_info")
            let shouldInitialize: Bool
            if hasDatabaseInfo {
                shouldInitialize = false
            } else if try opened.hasAnyUserTables() {
                // 有表却没有 db_info：既不是原版库也不是空库，绝不重建用户数据，直接报错。
                throw MeloDataError.incompatibleDatabase("缺少 db_info 表，且库中已有其他数据表")
            } else {
                // 首次启动，或上次启动失败留下的 0 字节/空数据库文件。
                shouldInitialize = true
            }

            if shouldInitialize {
                do {
                    try opened.execute(DatabaseSchema.initializationSQL)
                } catch {
                    // 刚创建/空库初始化失败：清掉半成品文件，避免下次启动被误判为「结构不兼容」。
                    // 此路径不存在用户数据，删除安全。
                    opened.close()
                    Self.removeDatabaseFiles(at: databasePath)
                    throw MeloDataError.databaseOpenFailed("初始化数据库失败：\(error.localizedDescription)")
                }
            }

            try opened.execute("PRAGMA journal_mode = WAL;")

            if !shouldInitialize {
                try migrateIfNeeded(in: opened)
                // 与原版一致：老库打开后执行 PRAGMA optimize（新库跳过）
                try? opened.execute("PRAGMA optimize;")
            }
        } catch {
            opened.close()
            if let dataError = error as? MeloDataError { throw dataError }
            throw MeloDataError.databaseOpenFailed(error.localizedDescription)
        }

        database = opened

        // 结构校验：原版 verifyDB 失败会拒绝启动；这里只记录告警，绝不重建/删除用户数据。
        do {
            let result = try DatabaseSchema.verify(opened)
            verification = result
            if result.isValid {
                MeloLog.info("数据库就绪：\(databasePath.path)")
            } else {
                MeloLog.error("数据库结构与原版 DDL 不一致（保留用户数据不重建）：\(result.summary)")
            }
        } catch {
            MeloLog.error("数据库结构校验失败（保留用户数据不重建）：\(error.localizedDescription)")
        }
    }

    /// 对齐原版 `migrate.ts`：version '1' → 补齐 dislike_list 表并升级到 '2'。
    private func migrateIfNeeded(in database: SQLiteDatabase) throws {
        guard let version = try database.scalarText(
            "SELECT \"field_value\" FROM \"main\".\"db_info\" WHERE \"field_name\" = ? LIMIT 1;",
            [.text("version")]
        ) else {
            throw MeloDataError.incompatibleDatabase("db_info 表缺少 version 记录")
        }
        switch version {
        case "1":
            if try !database.tableExists("dislike_list") {
                guard let item = DatabaseSchema.item(named: "dislike_list") else {
                    throw MeloDataError.incompatibleDatabase("缺少 dislike_list 建表语句")
                }
                try database.execute(item.sql)
            }
            try database.execute(
                "UPDATE \"main\".\"db_info\" SET \"field_value\"='\(DatabaseSchema.version)' WHERE \"field_name\"='version';"
            )
            MeloLog.info("数据库已从 v1 迁移到 v\(DatabaseSchema.version)")
        default:
            // '2' 或未知版本：与原版一致，不做额外处理
            break
        }
    }

    // MARK: - 诊断（内部/测试用）

    /// 当前库中所有表名（不含 sqlite 内部表）。
    internal func databaseTableNames() throws -> [String] {
        let database = try requireDatabase()
        return try database.objectNames(type: "table").filter { !$0.hasPrefix("sqlite_") }
    }

    /// 当前库中所有索引名（不含 sqlite 自动索引）。
    internal func databaseIndexNames() throws -> [String] {
        let database = try requireDatabase()
        return try database.objectNames(type: "index").filter { !$0.hasPrefix("sqlite_autoindex_") }
    }

    /// `db_info` 中的版本号。
    internal func databaseVersion() throws -> String? {
        try requireDatabase().scalarText(
            "SELECT \"field_value\" FROM \"main\".\"db_info\" WHERE \"field_name\"='version' LIMIT 1;"
        )
    }

    internal func databaseJournalMode() throws -> String {
        try requireDatabase().scalarText("PRAGMA journal_mode;") ?? ""
    }

    /// 在 service 的连接上执行任意 SQL（测试夹具用）。
    internal func withRawDatabase<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        try body(try requireDatabase())
    }

    // MARK: - 用户列表

    public func loadUserLists() throws -> [ListInfo] {
        let database = try requireDatabase()
        let statement = try database.prepare("""
            SELECT "id", "name", "source", "sourceListId", "position", "locationUpdateTime"
            FROM "main"."my_list"
            ORDER BY "position" ASC
            """)
        var lists: [ListInfo] = []
        while try statement.step() {
            guard let id = statement.text(0) else { continue }
            lists.append(ListInfo(
                id: id,
                name: statement.text(1) ?? "",
                source: statement.text(2),
                sourceListId: Self.fixLegacySourceListID(statement.text(3)),
                position: statement.int(4),
                locationUpdateTime: statement.isNull(5) ? nil : statement.int64(5)
            ))
        }
        return lists
    }

    @discardableResult
    public func createList(name: String) throws -> ListInfo {
        let database = try requireDatabase()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MeloDataError.invalidListName }

        // 原版：新列表追加到末尾，position = 最后一个列表的原始 position + 1（空列表时为 0）
        let lists = try loadUserLists()
        let position = (lists.last?.position ?? -1) + 1

        // 原版 id 规则：`userlist_${Date.now()}`；同毫秒内多次创建时递增时间戳避免主键冲突
        var timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var identifier = "userlist_\(timestamp)"
        while try listExists(id: identifier, in: database) {
            timestamp += 1
            identifier = "userlist_\(timestamp)"
        }

        let statement = try database.prepare("""
            INSERT INTO "main"."my_list" ("id", "name", "source", "sourceListId", "position", "locationUpdateTime")
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        try statement.execute([
            .text(identifier),
            .text(trimmedName),
            .null,
            .null,
            .int(position),
            .null,
        ])

        return ListInfo(id: identifier, name: trimmedName, position: position)
    }

    public func renameList(id: String, name: String) throws {
        let database = try requireDatabase()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw MeloDataError.invalidListName }
        guard !ListIDs.isBuiltin(id) else {
            throw MeloDataError.invalidArgument("内置列表不支持重命名：\(id)")
        }
        let statement = try database.prepare("""
            UPDATE "main"."my_list" SET "name"=? WHERE "id"=?
            """)
        try statement.execute([.text(trimmedName), .text(id)])
        guard database.changes > 0 else { throw MeloDataError.listNotFound(id) }
    }

    public func removeList(id: String) throws {
        let database = try requireDatabase()
        guard !ListIDs.isBuiltin(id) else {
            throw MeloDataError.invalidArgument("内置列表不支持删除：\(id)")
        }
        // 对齐原版 deleteUserLists：列表 + 列表内歌曲 + 排序记录级联删除（同一事务）
        try database.withTransaction {
            let deleteList = try database.prepare("DELETE FROM \"main\".\"my_list\" WHERE \"id\"=?")
            try deleteList.execute([.text(id)])
            let deleteMusics = try database.prepare("DELETE FROM \"main\".\"my_list_music_info\" WHERE \"listId\"=?")
            try deleteMusics.execute([.text(id)])
            let deleteOrders = try database.prepare("DELETE FROM \"main\".\"my_list_music_info_order\" WHERE \"listId\"=?")
            try deleteOrders.execute([.text(id)])
        }
    }

    public func updateListPosition(id: String, position: Int) throws {
        let database = try requireDatabase()
        // 对齐原版 updateUserListsPosition：取出被移动的列表 → 插到目标位置（越界收敛）→ 全量重排 position
        try database.withTransaction {
            var lists = try loadUserLists()
            guard let currentIndex = lists.firstIndex(where: { $0.id == id }) else {
                throw MeloDataError.listNotFound(id)
            }
            let moved = lists.remove(at: currentIndex)
            let target = min(max(position, 0), lists.count)
            lists.insert(moved, at: target)

            let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            try database.execute("DELETE FROM \"main\".\"my_list\"")
            let insert = try database.prepare("""
                INSERT INTO "main"."my_list" ("id", "name", "source", "sourceListId", "position", "locationUpdateTime")
                VALUES (?, ?, ?, ?, ?, ?)
                """)
            for (index, list) in lists.enumerated() {
                try insert.execute([
                    .text(list.id),
                    .text(list.name),
                    .optText(list.source),
                    .optText(list.sourceListId),
                    .int(index),
                    list.id == id ? .integer(timestamp) : .optInteger(list.locationUpdateTime),
                ])
            }
        }
    }

    // MARK: - 列表内歌曲

    public func loadMusics(listId: String) throws -> [MusicInfo] {
        let database = try requireDatabase()
        // 与原版 createMusicInfoQueryStatement 完全一致（LEFT JOIN 排序表，按 order 升序）
        let statement = try database.prepare("""
            SELECT mInfo."id", mInfo."name", mInfo."singer", mInfo."source", mInfo."interval", mInfo."meta"
            FROM my_list_music_info mInfo
            LEFT JOIN my_list_music_info_order O
            ON mInfo.id=O.musicInfoId AND O.listId=?
            WHERE mInfo.listId=?
            ORDER BY O."order" ASC
            """)
        try statement.bind([.text(listId), .text(listId)])
        var musics: [MusicInfo] = []
        while try statement.step() {
            musics.append(Self.makeMusicInfo(
                id: statement.text(0) ?? "",
                name: statement.text(1) ?? "",
                singer: statement.text(2) ?? "",
                source: statement.text(3) ?? "",
                interval: statement.text(4),
                metaText: statement.text(5) ?? "{}"
            ))
        }
        return musics
    }

    public func loadMusicCounts() throws -> [String: Int] {
        let database = try requireDatabase()
        let statement = try database.prepare("""
            SELECT "listId", COUNT(*) FROM "main"."my_list_music_info" GROUP BY "listId"
            """)
        var counts: [String: Int] = [:]
        while try statement.step() {
            guard let listId = statement.text(0) else { continue }
            counts[listId] = statement.int(1)
        }
        return counts
    }

    public func addMusic(_ music: MusicInfo, to listId: String, location: AddMusicLocationType) throws {
        let database = try requireDatabase()
        guard !listId.isEmpty else { throw MeloDataError.invalidArgument("列表 id 不能为空") }
        guard !music.id.isEmpty else { throw MeloDataError.invalidArgument("歌曲 id 不能为空") }

        try database.withTransaction {
            let existing = try loadMusics(listId: listId)
            // 对齐原版 musicsAdd：已存在（或重复）的歌曲直接忽略
            guard !existing.contains(where: { $0.id == music.id }) else { return }

            switch location {
            case .top:
                // 原版 insertMusicInfoListAndRefreshOrder：清空排序表 → 新歌 order 0..n-1 → 旧歌 order n.. 顺延
                let deleteOrders = try database.prepare(
                    "DELETE FROM \"main\".\"my_list_music_info_order\" WHERE \"listId\"=?"
                )
                try deleteOrders.execute([.text(listId)])
                try insertMusicInfo(music, listId: listId, in: database)
                let insertOrder = try database.prepare("""
                    INSERT INTO "main"."my_list_music_info_order" ("listId", "musicInfoId", "order")
                    VALUES (?, ?, ?)
                    """)
                try insertOrder.execute([.text(listId), .text(music.id), .int(0)])
                for (index, info) in existing.enumerated() {
                    try insertOrder.execute([.text(listId), .text(info.id), .int(index + 1)])
                }
            case .bottom:
                // 原版：order = 最后一首歌的原始 order + 1；空列表为 0（取不到 order 时回退为 count + 1）
                let offset: Int
                if let lastMusic = existing.last {
                    let lastOrder = try musicOrder(listId: listId, musicId: lastMusic.id, in: database)
                    offset = (lastOrder ?? existing.count) + 1
                } else {
                    offset = 0
                }
                try insertMusicInfo(music, listId: listId, in: database)
                try insertMusicOrder(listId: listId, musicId: music.id, order: offset, in: database)
            }
        }
    }

    public func removeMusic(ids: [String], from listId: String) throws {
        guard !ids.isEmpty else { return }
        let database = try requireDatabase()
        try database.withTransaction {
            let deleteMusic = try database.prepare(
                "DELETE FROM \"main\".\"my_list_music_info\" WHERE \"id\"=? AND \"listId\"=?"
            )
            let deleteOrder = try database.prepare(
                "DELETE FROM \"main\".\"my_list_music_info_order\" WHERE \"musicInfoId\"=? AND \"listId\"=?"
            )
            for identifier in ids {
                try deleteMusic.execute([.text(identifier), .text(listId)])
                try deleteOrder.execute([.text(identifier), .text(listId)])
            }
        }
    }

    public func isMusicExist(id: String, in listId: String) throws -> Bool {
        let database = try requireDatabase()
        let statement = try database.prepare("""
            SELECT 1 FROM "main"."my_list_music_info" WHERE "id"=? AND "listId"=? LIMIT 1
            """)
        try statement.bind([.text(id), .text(listId)])
        return try statement.step()
    }

    public func clearList(listId: String) throws {
        let database = try requireDatabase()
        try database.withTransaction {
            let deleteMusics = try database.prepare("DELETE FROM \"main\".\"my_list_music_info\" WHERE \"listId\"=?")
            try deleteMusics.execute([.text(listId)])
            let deleteOrders = try database.prepare("DELETE FROM \"main\".\"my_list_music_info_order\" WHERE \"listId\"=?")
            try deleteOrders.execute([.text(listId)])
        }
    }

    public func overwriteList(listId: String, musics: [MusicInfo]) throws {
        let database = try requireDatabase()
        // 对齐原版 overwriteMusicInfo：先删该列表的全部歌曲与排序，再按数组下标写 order
        // 与原版上层一致地过滤 id/name 为空与重复项，避免 UNIQUE(id,listId) 冲突
        let filtered = MeloUtils.filterMusicList(musics)
        try database.withTransaction {
            let deleteMusics = try database.prepare("DELETE FROM \"main\".\"my_list_music_info\" WHERE \"listId\"=?")
            try deleteMusics.execute([.text(listId)])
            let deleteOrders = try database.prepare("DELETE FROM \"main\".\"my_list_music_info_order\" WHERE \"listId\"=?")
            try deleteOrders.execute([.text(listId)])

            let insertInfo = try database.prepare("""
                INSERT INTO "main"."my_list_music_info" ("id", "listId", "name", "singer", "source", "interval", "meta")
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            let insertOrder = try database.prepare("""
                INSERT INTO "main"."my_list_music_info_order" ("listId", "musicInfoId", "order")
                VALUES (?, ?, ?)
                """)
            for (index, music) in filtered.enumerated() {
                try insertInfo.execute(Self.musicInfoValues(music, listId: listId))
                try insertOrder.execute([.text(listId), .text(music.id), .int(index)])
            }
        }
    }

    public func updateMusicOrder(in listId: String, orderedMusicIDs: [String]) throws {
        let database = try requireDatabase()
        guard !listId.isEmpty else { throw MeloDataError.invalidArgument("列表 id 不能为空") }

        try database.withTransaction {
            // 校验 listId：内置列表（default/love/temp）始终有效；自建列表必须存在于 my_list。
            if !ListIDs.isBuiltin(listId), try !listExists(id: listId, in: database) {
                throw MeloDataError.listNotFound(listId)
            }

            // 以传入顺序为准；未传入/不存在的旧歌按原相对顺序追加到末尾，避免丢歌。
            let current = try loadMusics(listId: listId)
            let existingIDs = current.map(\.id)
            let existingSet = Set(existingIDs)
            var seen = Set<String>()
            var ordered: [String] = []
            ordered.reserveCapacity(existingIDs.count)
            for identifier in orderedMusicIDs where existingSet.contains(identifier) && seen.insert(identifier).inserted {
                ordered.append(identifier)
            }
            for identifier in existingIDs where seen.insert(identifier).inserted {
                ordered.append(identifier)
            }

            // 对齐原版 updateMusicInfoOrder：清空该列表排序后按 0..n-1 重写（事务内保证原子性）。
            let deleteOrders = try database.prepare(
                "DELETE FROM \"main\".\"my_list_music_info_order\" WHERE \"listId\"=?"
            )
            try deleteOrders.execute([.text(listId)])
            let insertOrder = try database.prepare("""
                INSERT INTO "main"."my_list_music_info_order" ("listId", "musicInfoId", "order")
                VALUES (?, ?, ?)
                """)
            for (index, identifier) in ordered.enumerated() {
                try insertOrder.execute([.text(listId), .text(identifier), .int(index)])
            }
        }
    }

    // MARK: - 本地音乐扫描（只读，不写库）

    /// 扫描本地文件/文件夹（目录递归），生成 `source = "local"` 的 `MusicInfo`。
    /// 不依赖数据库打开状态，也不写数据库；不存在的路径/无权限文件静默跳过。
    public func scanLocalMusic(at urls: [URL]) throws -> [MusicInfo] {
        LocalMusicScanner.scan(
            at: urls,
            coversDirectory: dataDirectory.appendingPathComponent("covers", isDirectory: true)
        )
    }

    // MARK: - 列表备份导出 / 导入（供 MeloCore.BackupService 组装 .lxmc）

    /// 导出列表备份数组：default（试听列表）+ love（我的收藏）+ 所有用户列表（按 position），不含 temp。
    /// 每个元素：`{id, name, source, sourceListId, locationUpdateTime, list:[MusicInfo]}`，歌曲按 order 排序。
    public func exportPlaylistsBackup() throws -> JSONValue {
        var entries: [JSONValue] = []
        entries.append(try makePlaylistBackupEntry(
            id: ListIDs.default,
            name: ListIDs.defaultName(ListIDs.default),
            source: nil,
            sourceListID: nil,
            locationUpdateTime: nil
        ))
        entries.append(try makePlaylistBackupEntry(
            id: ListIDs.love,
            name: ListIDs.defaultName(ListIDs.love),
            source: nil,
            sourceListID: nil,
            locationUpdateTime: nil
        ))
        for list in try loadUserLists() {
            entries.append(try makePlaylistBackupEntry(
                id: list.id,
                name: list.name,
                source: list.source,
                sourceListID: list.sourceListId,
                locationUpdateTime: list.locationUpdateTime
            ))
        }
        return .array(entries)
    }

    /// 导入列表备份：default/love 覆盖；用户列表按 id 更新（不存在则创建，position = 当前最大值 + 1）；
    /// 歌曲兼容新结构（含 meta，JSONDecoder）与旧结构（`MusicInfo(legacyJSON:)`）。
    /// 每个列表独立事务，单个列表失败继续；全部失败时抛错。返回统计（sourceType 由 BackupService 填）。
    public func importPlaylistsBackup(_ lists: JSONValue) throws -> BackupImportSummary {
        let database = try requireDatabase()
        guard let elements = lists.arrayValue else {
            throw MeloDataError.invalidArgument("列表备份内容不是数组")
        }

        var summary = BackupImportSummary()
        var succeeded = 0
        var failed = 0

        for element in elements {
            guard let object = element.objectValue,
                  let listID = Self.backupString(object["id"]), !listID.isEmpty,
                  listID != ListIDs.temp, listID != ListIDs.download else {
                continue // 无效元素 / 临时列表 / download 特殊 id：跳过
            }
            let isBuiltin = ListIDs.isBuiltin(listID)
            let name = Self.backupString(object["name"])
                ?? (isBuiltin ? ListIDs.defaultName(listID) : "导入列表")
            let source = Self.backupString(object["source"])
            let sourceListID = Self.backupString(object["sourceListId"])
            let locationUpdateTime = object["locationUpdateTime"]
                .flatMap { $0.isNull ? nil : $0.intValue }
                .map { Int64($0) }
            let musics = Self.decodeBackupMusics(object["list"])

            do {
                try database.withTransaction {
                    if isBuiltin {
                        // default/love：整列表覆盖（overwriteList 内部会先清空再按顺序写）
                        try overwriteList(listId: listID, musics: musics)
                    } else {
                        try upsertUserListFromBackup(
                            id: listID,
                            name: name,
                            source: source,
                            sourceListID: sourceListID,
                            locationUpdateTime: locationUpdateTime,
                            in: database
                        )
                        try overwriteList(listId: listID, musics: musics)
                    }
                }
                summary.lists += 1
                summary.musics += (try loadMusics(listId: listID)).count
                succeeded += 1
            } catch {
                failed += 1
                MeloLog.warn("导入列表备份失败（listId=\(listID)），已跳过：\(error.localizedDescription)")
            }
        }

        if succeeded == 0, failed > 0 {
            throw MeloDataError.corruptedData("导入列表备份失败：\(failed) 个列表均无法导入")
        }
        summary.sourceType = "" // 由 BackupService 按备份 type 填充
        return summary
    }

    private func makePlaylistBackupEntry(
        id: String,
        name: String,
        source: String?,
        sourceListID: String?,
        locationUpdateTime: Int64?
    ) throws -> JSONValue {
        let musics = try loadMusics(listId: id)
        return .object([
            "id": .string(id),
            "name": .string(name),
            "source": source.map { .string($0) } ?? .null,
            "sourceListId": sourceListID.map { .string($0) } ?? .null,
            "locationUpdateTime": locationUpdateTime.map { .int($0) } ?? .null,
            "list": .array(musics.map(\.jsonObject)),
        ])
    }

    /// 按 id 更新或创建用户列表（导入备份用）。新行 position = 当前最大 position + 1。
    private func upsertUserListFromBackup(
        id: String,
        name: String,
        source: String?,
        sourceListID: String?,
        locationUpdateTime: Int64?,
        in database: SQLiteDatabase
    ) throws {
        let existingCount = try database.scalarInt(
            "SELECT COUNT(*) FROM \"main\".\"my_list\" WHERE \"id\"=?;",
            [.text(id)]
        ) ?? 0
        let locationValue = locationUpdateTime.map { SQLiteValue.integer($0) } ?? .null
        if existingCount > 0 {
            let update = try database.prepare("""
                UPDATE "main"."my_list"
                SET "name"=?, "source"=?, "sourceListId"=?, "locationUpdateTime"=?
                WHERE "id"=?
                """)
            try update.execute([
                .text(name), .optText(source), .optText(sourceListID), locationValue, .text(id),
            ])
        } else {
            let insert = try database.prepare("""
                INSERT INTO "main"."my_list" ("id", "name", "source", "sourceListId", "position", "locationUpdateTime")
                VALUES (?, ?, ?, ?, (SELECT COALESCE(MAX("position"), -1) + 1 FROM "main"."my_list"), ?)
                """)
            try insert.execute([
                .text(id), .text(name), .optText(source), .optText(sourceListID), locationValue,
            ])
        }
    }

    /// 宽松解析备份里的歌曲数组：新结构（含 meta）走 JSONDecoder，旧结构走 `MusicInfo(legacyJSON:)`；无效项跳过。
    private static func decodeBackupMusics(_ value: JSONValue?) -> [MusicInfo] {
        guard let items = value?.arrayValue else { return [] }
        var musics: [MusicInfo] = []
        for item in items {
            guard let object = item.objectValue else { continue }
            if object["meta"] != nil {
                guard let data = item.jsonData(),
                      let decoded = try? JSONDecoder().decode(MusicInfo.self, from: data) else {
                    continue
                }
                musics.append(decoded)
            } else if let legacy = MusicInfo(legacyJSON: item) {
                musics.append(legacy)
            }
        }
        return musics
    }

    private static func backupString(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull, let text = value.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 歌词（DB 内 text 存 base64，对外收发明文）

    public func getLyric(musicId: String, source: String, type: String) throws -> String? {
        let database = try requireDatabase()
        let statement = try database.prepare("""
            SELECT "text" FROM "main"."lyric"
            WHERE "id"=? AND "source"=? AND "type"=?
            ORDER BY rowid DESC LIMIT 1
            """)
        try statement.bind([.text(musicId), .text(source), .text(type)])
        guard try statement.step() else { return nil }
        return Self.decodeLyricText(statement.text(0) ?? "")
    }

    public func saveLyric(musicId: String, source: String, type: String, text: String) throws {
        let database = try requireDatabase()
        // 对齐原版「先删后插」/ editedLyricUpdateAddAndUpdate 的最终状态：同一个 (id, source, type) 只保留一行
        let encoded = Data(text.utf8).base64EncodedString()
        try database.withTransaction {
            let delete = try database.prepare("""
                DELETE FROM "main"."lyric" WHERE "id"=? AND "source"=? AND "type"=?
                """)
            try delete.execute([.text(musicId), .text(source), .text(type)])
            let insert = try database.prepare("""
                INSERT INTO "main"."lyric" ("id", "source", "type", "text") VALUES (?, ?, ?, ?)
                """)
            try insert.execute([.text(musicId), .text(source), .text(type), .text(encoded)])
        }
    }

    /// 删除某首歌指定 source/type 的歌词缓存（AppModel 歌词偏移重置会删除 edited 歌词以回退 raw）。
    /// - 不存在时静默成功；空参数抛 `invalidArgument`；单条 DELETE 为原子操作。
    public func removeLyric(musicId: String, source: String, type: String) throws {
        guard !musicId.isEmpty, !source.isEmpty, !type.isEmpty else {
            throw MeloDataError.invalidArgument("删除歌词参数不能为空（musicId/source/type）")
        }
        let database = try requireDatabase()
        let delete = try database.prepare("""
            DELETE FROM "main"."lyric" WHERE "id"=? AND "source"=? AND "type"=?
            """)
        try delete.execute([.text(musicId), .text(source), .text(type)])
    }

    // MARK: - 歌曲 URL 缓存（id = `${musicId}_${quality}`）

    public func getMusicURL(musicId: String, quality: String) throws -> String? {
        let database = try requireDatabase()
        let statement = try database.prepare("""
            SELECT "url" FROM "main"."music_url" WHERE "id"=? ORDER BY rowid ASC LIMIT 1
            """)
        try statement.bind([.text(Self.musicURLIdentifier(musicId: musicId, quality: quality))])
        guard try statement.step() else { return nil }
        return statement.text(0)
    }

    public func saveMusicURL(musicId: String, quality: String, url: String) throws {
        let database = try requireDatabase()
        let identifier = Self.musicURLIdentifier(musicId: musicId, quality: quality)
        // 对齐原版 insertMusicUrl：同一 id 先删后插，避免出现多条缓存
        try database.withTransaction {
            let delete = try database.prepare("DELETE FROM \"main\".\"music_url\" WHERE \"id\"=?")
            try delete.execute([.text(identifier)])
            let insert = try database.prepare("INSERT INTO \"main\".\"music_url\" (\"id\", \"url\") VALUES (?, ?)")
            try insert.execute([.text(identifier), .text(url)])
        }
    }

    // MARK: - 下载任务

    public func loadDownloadTasks() throws -> [DownloadTaskInfo] {
        let database = try requireDatabase()
        let statement = try database.prepare("""
            SELECT "id", "isComplate", "status", "statusText", "progress_downloaded", "progress_total",
                   "url", "quality", "ext", "fileName", "filePath", "musicInfo", "position"
            FROM "main"."download_list"
            ORDER BY "position" ASC
            """)
        var tasks: [DownloadTaskInfo] = []
        while try statement.step() {
            let identifier = statement.text(0) ?? ""
            let musicInfo = try Self.decodeDownloadMusicInfo(
                statement.text(11) ?? "",
                taskID: identifier
            )
            tasks.append(DownloadTaskInfo(
                id: identifier,
                isCompleted: statement.int(1) == 1,
                status: statement.text(2) ?? "",
                statusText: statement.text(3) ?? "",
                progressDownloaded: statement.int64(4),
                progressTotal: statement.int64(5),
                url: statement.text(6),
                quality: statement.text(7) ?? "",
                ext: statement.text(8) ?? "",
                fileName: statement.text(9) ?? "",
                filePath: statement.text(10) ?? "",
                musicInfo: musicInfo,
                position: statement.int(12)
            ))
        }
        return tasks
    }

    /// 保存/更新下载任务（UPSERT `download_list`）。
    /// - 已有 id：保留原 position，其余字段全量覆盖；
    /// - 新 id：position = 当前最大值 + 1；
    /// - 重复保存幂等（同一状态多次写入结果一致）。
    public func saveDownloadTask(_ task: DownloadTaskInfo) throws {
        let database = try requireDatabase()
        guard !task.id.isEmpty else { throw MeloDataError.invalidArgument("下载任务 id 不能为空") }
        let musicInfoJSON = try Self.encodeDownloadMusicInfo(task.musicInfo, taskID: task.id)

        // INSERT 时用子查询取下一个 position；冲突走 UPDATE 且不触碰 position（保留原值）。
        let statement = try database.prepare("""
            INSERT INTO "main"."download_list" (
                "id", "isComplate", "status", "statusText", "progress_downloaded", "progress_total",
                "url", "quality", "ext", "fileName", "filePath", "musicInfo", "position"
            ) VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                (SELECT COALESCE(MAX("position"), -1) + 1 FROM "main"."download_list")
            )
            ON CONFLICT("id") DO UPDATE SET
                "isComplate"=excluded."isComplate",
                "status"=excluded."status",
                "statusText"=excluded."statusText",
                "progress_downloaded"=excluded."progress_downloaded",
                "progress_total"=excluded."progress_total",
                "url"=excluded."url",
                "quality"=excluded."quality",
                "ext"=excluded."ext",
                "fileName"=excluded."fileName",
                "filePath"=excluded."filePath",
                "musicInfo"=excluded."musicInfo"
            """)
        try statement.execute([
            .text(task.id),
            .int(task.isCompleted ? 1 : 0),
            .text(task.status),
            .text(task.statusText),
            .integer(task.progressDownloaded),
            .integer(task.progressTotal),
            .optText(task.url),
            .text(task.quality),
            .text(task.ext),
            .text(task.fileName),
            .text(task.filePath),
            .text(musicInfoJSON),
        ])
    }

    /// 按 id 批量删除下载任务（空数组直接返回）。
    public func removeDownloadTasks(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let database = try requireDatabase()
        try database.withTransaction {
            let delete = try database.prepare("DELETE FROM \"main\".\"download_list\" WHERE \"id\"=?")
            for identifier in ids {
                try delete.execute([.text(identifier)])
            }
        }
    }

    /// 清空已完成（isComplate=1）的下载任务，未完成任务保留。
    public func clearCompletedDownloadTasks() throws {
        let database = try requireDatabase()
        let statement = try database.prepare("DELETE FROM \"main\".\"download_list\" WHERE \"isComplate\"=1")
        try statement.execute()
    }

    // MARK: - 不喜欢列表

    public func loadDislikes() throws -> [DislikeInfo] {
        let database = try requireDatabase()
        let statement = try database.prepare("""
            SELECT "type", "content", "meta" FROM "main"."dislike_list" ORDER BY rowid ASC
            """)
        var dislikes: [DislikeInfo] = []
        while try statement.step() {
            let metaText = statement.text(2)
            let meta: JSONValue?
            if let metaText, !metaText.isEmpty {
                meta = JSONValue(jsonString: metaText)
            } else {
                meta = nil
            }
            dislikes.append(DislikeInfo(
                type: statement.text(0) ?? "",
                content: statement.text(1) ?? "",
                meta: meta
            ))
        }
        return dislikes
    }

    /// 原版 dislike_list 行的 type 值。
    /// 注：`src/main/worker/dbService/modules/dislike_list/statements.ts` 实际写入 `'music'`，查询也是
    /// `WHERE "type"='music'`；为与原版 App 直接互读，这里同样写 `'music'`（而不是空串）。
    private static let dislikeRowType = "music"

    /// 覆盖全部不喜欢规则：账号下所有规则文本（每行一条）原样入库（trim/跳空行，不做 @/# 转换）。
    public func saveDislikeRulesText(_ text: String) throws {
        let database = try requireDatabase()
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        try database.withTransaction {
            let delete = try database.prepare("DELETE FROM \"main\".\"dislike_list\"")
            try delete.execute()
            let insert = try database.prepare("""
                INSERT INTO "main"."dislike_list" ("type", "content", "meta") VALUES (?, ?, NULL)
                """)
            for line in lines {
                try insert.execute([.text(Self.dislikeRowType), .text(line)])
            }
        }
    }

    /// 追加一条不喜欢规则（name+singer → `name@singer`；仅 name → `name`；仅 singer → `@singer`；都空不插入）。
    public func addDislikeMusic(name: String, singer: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSinger = singer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty || !trimmedSinger.isEmpty else { return }

        let content: String
        if trimmedName.isEmpty {
            content = "@\(trimmedSinger)"
        } else if trimmedSinger.isEmpty {
            content = trimmedName
        } else {
            content = "\(trimmedName)@\(trimmedSinger)"
        }
        let database = try requireDatabase()
        let insert = try database.prepare("""
            INSERT INTO "main"."dislike_list" ("type", "content", "meta") VALUES (?, ?, NULL)
            """)
        try insert.execute([.text(Self.dislikeRowType), .text(content)])
    }

    /// 清空全部不喜欢规则。
    public func clearDislikes() throws {
        let database = try requireDatabase()
        try database.execute("DELETE FROM \"main\".\"dislike_list\"")
    }

    // MARK: - 内部工具

    /// 删除数据库主文件及 WAL/SHM 附属文件（仅用于清理无用户数据的半成品库）。
    private static func removeDatabaseFiles(at url: URL) {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? manager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    private func requireDatabase() throws -> SQLiteDatabase {
        guard let database else { throw MeloDataError.notBootstrapped }
        return database
    }

    private func listExists(id: String, in database: SQLiteDatabase) throws -> Bool {
        let count = try database.scalarInt(
            "SELECT COUNT(*) FROM \"main\".\"my_list\" WHERE \"id\"=? LIMIT 1;",
            [.text(id)]
        )
        return (count ?? 0) > 0
    }

    private func musicOrder(listId: String, musicId: String, in database: SQLiteDatabase) throws -> Int? {
        let statement = try database.prepare("""
            SELECT "order" FROM "main"."my_list_music_info_order"
            WHERE "listId"=? AND "musicInfoId"=? LIMIT 1
            """)
        try statement.bind([.text(listId), .text(musicId)])
        guard try statement.step() else { return nil }
        return statement.int(0)
    }

    private func insertMusicInfo(_ music: MusicInfo, listId: String, in database: SQLiteDatabase) throws {
        let statement = try database.prepare("""
            INSERT INTO "main"."my_list_music_info" ("id", "listId", "name", "singer", "source", "interval", "meta")
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        try statement.execute(Self.musicInfoValues(music, listId: listId))
    }

    private func insertMusicOrder(listId: String, musicId: String, order: Int, in database: SQLiteDatabase) throws {
        let statement = try database.prepare("""
            INSERT INTO "main"."my_list_music_info_order" ("listId", "musicInfoId", "order")
            VALUES (?, ?, ?)
            """)
        try statement.execute([.text(listId), .text(musicId), .int(order)])
    }

    private static func musicInfoValues(_ music: MusicInfo, listId: String) -> [SQLiteValue] {
        [
            .text(music.id),
            .text(listId),
            .text(music.name),
            .text(music.singer),
            .text(music.source),
            .optText(music.interval),
            .text(metaText(music.meta)),
        ]
    }

    /// 与原版 `JSON.stringify(meta)` 等价的文本表示（未知字段原样保留）。
    private static func metaText(_ meta: JSONValue) -> String {
        meta.jsonString() ?? "{}"
    }

    /// 与原版一致：读取时把历史版本写入的数字类型 sourceListId 末尾的 `.0` 去掉。
    private static func fixLegacySourceListID(_ value: String?) -> String? {
        guard let value, value.hasSuffix(".0") else { return value }
        return String(value.dropLast(2))
    }

    /// 原版 `lyric.text` 为 base64 文本；解码失败时原样返回，避免旧数据/脏数据直接丢失。
    private static func decodeLyricText(_ encoded: String) -> String {
        if encoded.isEmpty { return "" }
        guard let data = Data(base64Encoded: encoded, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return encoded
        }
        return text
    }

    private static func musicURLIdentifier(musicId: String, quality: String) -> String {
        "\(musicId)_\(quality)"
    }

    private static func makeMusicInfo(
        id: String,
        name: String,
        singer: String,
        source: String,
        interval: String?,
        metaText: String
    ) -> MusicInfo {
        var meta: JSONValue = .object([:])
        if let parsed = JSONValue(jsonString: metaText) {
            meta = parsed
        } else {
            MeloLog.warn("歌曲 \(id) 的 meta 不是有效 JSON，已按空对象处理")
        }
        return MusicInfo(id: id, name: name, singer: singer, source: source, interval: interval, meta: meta)
    }

    private static func decodeDownloadMusicInfo(_ json: String, taskID: String) throws -> MusicInfo {
        guard !json.isEmpty, let data = json.data(using: .utf8) else {
            throw MeloDataError.corruptedData("下载任务 \(taskID) 的 musicInfo 为空")
        }
        if let info = try? JSONDecoder().decode(MusicInfo.self, from: data) {
            return info
        }
        guard let value = JSONValue(jsonString: json) else {
            throw MeloDataError.corruptedData("下载任务 \(taskID) 的 musicInfo 不是有效 JSON")
        }
        return MusicInfo(
            id: value["id"]?.stringValue ?? "",
            name: value["name"]?.stringValue ?? "",
            singer: value["singer"]?.stringValue ?? "",
            source: value["source"]?.stringValue ?? "",
            interval: value["interval"]?.stringValue,
            meta: value["meta"] ?? .object([:])
        )
    }

    /// 与原版 `JSON.stringify(musicInfo)` 等价的 JSON 文本（meta 未知字段原样保留）。
    private static func encodeDownloadMusicInfo(_ musicInfo: MusicInfo, taskID: String) throws -> String {
        do {
            let data = try JSONEncoder().encode(musicInfo)
            guard let text = String(data: data, encoding: .utf8) else {
                throw MeloDataError.corruptedData("下载任务 \(taskID) 的 musicInfo 序列化失败")
            }
            return text
        } catch let error as MeloDataError {
            throw error
        } catch {
            throw MeloDataError.corruptedData("下载任务 \(taskID) 的 musicInfo 序列化失败：\(error.localizedDescription)")
        }
    }
}
