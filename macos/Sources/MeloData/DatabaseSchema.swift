import Foundation

// MARK: - 原版数据库结构（与 src/main/worker/dbService/tables.ts 逐字对齐）
//
// 兼容性约束：
// 1. DDL 的顺序、表名/索引名、引号、列类型必须与原版一致（原版 verifyDB 会去掉空白/分号/行注释后做字面比对）。
// 2. 首次建库 = 12 条 DDL（9 张表 + 3 个索引，按 tables.ts 的 Map 插入顺序）+ db_info(version='2') 记录。
// 3. 用户已有数据库绝不因字段差异重建；仅按原版 migrate.ts 从 version '1' 升级。

/// 原版 SQLite 结构校验结果（归 compares 归一化后的字面比对）。
public struct DatabaseSchemaVerification: Equatable, Sendable {
    /// 所有预期表/索引都存在且 DDL 与原版一致
    public let isValid: Bool
    /// 缺失的表/索引名
    public let missingItems: [String]
    /// 存在但 DDL 不一致的表/索引名
    public let mismatchedItems: [String]

    public init(isValid: Bool, missingItems: [String], mismatchedItems: [String]) {
        self.isValid = isValid
        self.missingItems = missingItems
        self.mismatchedItems = mismatchedItems
    }

    public var summary: String {
        if isValid { return "数据库结构与原版一致" }
        var parts: [String] = []
        if !missingItems.isEmpty { parts.append("缺少 \(missingItems.joined(separator: ", "))") }
        if !mismatchedItems.isEmpty { parts.append("结构不一致 \(mismatchedItems.joined(separator: ", "))") }
        return parts.joined(separator: "；")
    }
}

enum DatabaseSchema {
    /// 原版 `DB_VERSION`
    static let version = "2"

    enum ItemKind {
        case table
        case index
    }

    struct Item {
        let name: String
        let kind: ItemKind
        let sql: String
    }

    // MARK: DDL（逐字复制 tables.ts，仅去掉类型标注）

    private static let dbInfoSQL = """
      CREATE TABLE "db_info" (
        "id" INTEGER NOT NULL UNIQUE,
        "field_name" TEXT,
        "field_value" TEXT,
        PRIMARY KEY("id" AUTOINCREMENT)
      );
    """

    private static let myListSQL = """
      CREATE TABLE "my_list" (
        "id" TEXT NOT NULL,
        "name" TEXT NOT NULL,
        "source" TEXT,
        "sourceListId" TEXT,
        "position" INTEGER NOT NULL,
        "locationUpdateTime" INTEGER,
        PRIMARY KEY("id")
      );
    """

    private static let myListMusicInfoSQL = """
      CREATE TABLE "my_list_music_info" (
        "id" TEXT NOT NULL,
        "listId" TEXT NOT NULL,
        "name" TEXT NOT NULL,
        "singer" TEXT NOT NULL,
        "source" TEXT NOT NULL,
        "interval" TEXT,
        "meta" TEXT NOT NULL,
        UNIQUE("id","listId")
      );
    """

    private static let myListMusicInfoIndexSQL = """
      CREATE INDEX "index_my_list_music_info" ON "my_list_music_info" (
        "id",
        "listId"
      );
    """

    private static let myListMusicInfoOrderSQL = """
      CREATE TABLE "my_list_music_info_order" (
        "listId" TEXT NOT NULL,
        "musicInfoId" TEXT NOT NULL,
        "order" INTEGER NOT NULL
      );
    """

    private static let myListMusicInfoOrderIndexSQL = """
      CREATE INDEX "index_my_list_music_info_order" ON "my_list_music_info_order" (
        "listId",
        "musicInfoId"
      );
    """

    private static let musicInfoOtherSourceSQL = """
      CREATE TABLE "music_info_other_source" (
        "source_id" TEXT NOT NULL,
        "id" TEXT NOT NULL,
        "source" TEXT NOT NULL,
        "name" TEXT NOT NULL,
        "singer" TEXT NOT NULL,
        "meta" TEXT NOT NULL,
        "order" INTEGER NOT NULL,
        UNIQUE("source_id","id")
      );
    """

    private static let musicInfoOtherSourceIndexSQL = """
      CREATE INDEX "index_music_info_other_source" ON "music_info_other_source" (
        "source_id",
        "id"
      );
    """

    private static let lyricSQL = """
      -- TODO  "meta" TEXT NOT NULL,
      CREATE TABLE "lyric" (
        "id" TEXT NOT NULL,
        "source" TEXT NOT NULL,
        "type" TEXT NOT NULL,
        "text" TEXT NOT NULL
      );
    """

    private static let musicURLSQL = """
      CREATE TABLE "music_url" (
        "id" TEXT NOT NULL,
        "url" TEXT NOT NULL
      );
    """

    private static let downloadListSQL = """
      CREATE TABLE "download_list" (
        "id" TEXT NOT NULL,
        "isComplate" INTEGER NOT NULL,
        "status" TEXT NOT NULL,
        "statusText" TEXT NOT NULL,
        "progress_downloaded" INTEGER NOT NULL,
        "progress_total" INTEGER NOT NULL,
        "url" TEXT,
        "quality" TEXT NOT NULL,
        "ext" TEXT NOT NULL,
        "fileName" TEXT NOT NULL,
        "filePath" TEXT NOT NULL,
        "musicInfo" TEXT NOT NULL,
        "position" INTEGER NOT NULL,
        PRIMARY KEY("id")
      );
    """

    private static let dislikeListSQL = """
      CREATE TABLE "dislike_list" (
        "type" TEXT NOT NULL,
        "content" TEXT NOT NULL,
        "meta" TEXT
      );
    """

    /// 顺序与 `tables.ts` 中 `tables.set(...)` 的插入顺序完全一致。
    static let items: [Item] = [
        Item(name: "db_info", kind: .table, sql: dbInfoSQL),
        Item(name: "my_list", kind: .table, sql: myListSQL),
        Item(name: "my_list_music_info", kind: .table, sql: myListMusicInfoSQL),
        Item(name: "index_my_list_music_info", kind: .index, sql: myListMusicInfoIndexSQL),
        Item(name: "my_list_music_info_order", kind: .table, sql: myListMusicInfoOrderSQL),
        Item(name: "index_my_list_music_info_order", kind: .index, sql: myListMusicInfoOrderIndexSQL),
        Item(name: "music_info_other_source", kind: .table, sql: musicInfoOtherSourceSQL),
        Item(name: "index_music_info_other_source", kind: .index, sql: musicInfoOtherSourceIndexSQL),
        Item(name: "lyric", kind: .table, sql: lyricSQL),
        Item(name: "music_url", kind: .table, sql: musicURLSQL),
        Item(name: "download_list", kind: .table, sql: downloadListSQL),
        Item(name: "dislike_list", kind: .table, sql: dislikeListSQL),
    ]

    static var tableNames: [String] { items.filter { $0.kind == .table }.map(\.name) }
    static var indexNames: [String] { items.filter { $0.kind == .index }.map(\.name) }

    static func item(named name: String) -> Item? {
        items.first { $0.name == name }
    }

    /// 首次建库（对应原版 `initTables`：全量 DDL + 写入 db_info.version）。
    static var initializationSQL: String {
        items.map(\.sql).joined(separator: "\n") +
            "\nINSERT INTO \"main\".\"db_info\" (\"field_name\", \"field_value\") VALUES ('version', '\(version)');\n"
    }

    // MARK: 校验（对齐原版 verifyDB.ts）

    /// 归一化：去掉空白、分号与 `--` 行注释，然后再做字面比对。
    static func normalize(_ sql: String) -> String {
        var result = ""
        result.reserveCapacity(sql.count)
        var index = sql.startIndex
        while index < sql.endIndex {
            let character = sql[index]
            if character.isWhitespace {
                index = sql.index(after: index)
                continue
            }
            if character == ";" {
                index = sql.index(after: index)
                continue
            }
            if character == "-" {
                let next = sql.index(after: index)
                if next < sql.endIndex, sql[next] == "-" {
                    index = sql.index(after: next)
                    while index < sql.endIndex, sql[index] != "\n" {
                        index = sql.index(after: index)
                    }
                    continue
                }
            }
            result.append(character)
            index = sql.index(after: index)
        }
        return result
    }

    /// 查询 sqlite_master 并逐项比对预期结构。
    static func verify(_ database: SQLiteDatabase) throws -> DatabaseSchemaVerification {
        let statement = try database.prepare(
            "SELECT \"type\", \"name\", \"tbl_name\", \"sql\" FROM \"main\".sqlite_master WHERE \"sql\" NOT NULL;"
        )
        var stored: [String: String] = [:]
        while try statement.step() {
            guard let name = statement.text(1), let sql = statement.text(3) else { continue }
            stored[name] = normalize(sql)
        }
        var missing: [String] = []
        var mismatched: [String] = []
        for item in items {
            guard let storedSQL = stored[item.name] else {
                missing.append(item.name)
                continue
            }
            if storedSQL != normalize(item.sql) { mismatched.append(item.name) }
        }
        return DatabaseSchemaVerification(
            isValid: missing.isEmpty && mismatched.isEmpty,
            missingItems: missing,
            mismatchedItems: mismatched
        )
    }
}
