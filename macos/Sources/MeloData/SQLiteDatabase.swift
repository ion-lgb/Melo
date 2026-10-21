import Foundation
import SQLite3

// MARK: - 低层 SQLite 封装（系统 SQLite3，无第三方依赖）
//
// 说明：
// - 只封装数据层用到的能力：打开/关闭、多语句执行、prepared statement、参数绑定、行读取、事务。
// - 字符串绑定统一使用 `SQLITE_TRANSIENT`，由 SQLite 立即拷贝，避免 Swift 字符串作用域结束后悬垂指针。
// - 所有调用都发生在 `@MainActor`（SQLiteDataService 内），本层不做额外加锁；连接本身使用 FULLMUTEX。

/// `SQLITE_TRANSIENT` 在 Swift 中没有导出，按 C API 约定用 -1 位模式构造。
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite 底层错误（保留错误码与出错 SQL 上下文，便于日志定位）。
struct SQLiteError: LocalizedError, CustomStringConvertible {
    let code: Int32
    let message: String
    let context: String

    var errorDescription: String? {
        "\(context)：\(message)（SQLite code \(code)）"
    }

    var description: String { errorDescription ?? message }
}

/// 绑定参数/读取写入用的轻量值类型。
enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    static func int(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }
    static func optInteger(_ value: Int64?) -> SQLiteValue { value.map(SQLiteValue.integer) ?? .null }
    static func optText(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
}

// MARK: - 数据库连接

final class SQLiteDatabase {
    private var handle: OpaquePointer?
    let path: String
    private var transactionDepth = 0

    init(path: String) throws {
        self.path = path
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &database, flags, nil)
        guard code == SQLITE_OK, let opened = database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库文件"
            if let database { sqlite3_close_v2(database) }
            throw SQLiteError(code: code, message: message, context: "打开数据库 \(path)")
        }
        sqlite3_busy_timeout(opened, 5_000)
        self.handle = opened
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    var rawHandle: OpaquePointer? { handle }

    var isOpen: Bool { handle != nil }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    /// `sqlite3_changes`：最近一条 INSERT/UPDATE/DELETE 影响的行数。
    var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    // MARK: 执行

    /// 执行一条或多条 SQL（不带参数），用于建表 / PRAGMA / 事务控制。
    func execute(_ sql: String) throws {
        guard let handle else { throw closedError(context: "执行 SQL") }
        guard !sql.contains("?") else {
            throw SQLiteError(
                code: SQLITE_MISUSE,
                message: "execute() 不支持参数绑定，请使用 prepare + bind/execute(values)",
                context: "执行 SQL 失败"
            )
        }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard code == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            if let errorPointer { sqlite3_free(errorPointer) }
            throw SQLiteError(code: code, message: message, context: "执行 SQL 失败")
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(database: self, sql: sql)
    }

    /// 查询单个文本值（第一行第一列）。
    func scalarText(_ sql: String, _ values: [SQLiteValue] = []) throws -> String? {
        let statement = try prepare(sql)
        try statement.bind(values)
        guard try statement.step() else { return nil }
        return statement.text(0)
    }

    /// 查询单个整数值（第一行第一列）。
    func scalarInt(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64? {
        let statement = try prepare(sql)
        try statement.bind(values)
        guard try statement.step() else { return nil }
        return statement.int64(0)
    }

    // MARK: 结构查询

    func objectNames(type: String) throws -> [String] {
        let statement = try prepare("SELECT \"name\" FROM \"main\".sqlite_master WHERE \"type\"=? ORDER BY \"name\" ASC;")
        try statement.bind([.text(type)])
        var names: [String] = []
        while try statement.step() {
            if let name = statement.text(0) { names.append(name) }
        }
        return names
    }

    func tableExists(_ name: String) throws -> Bool {
        let value = try scalarInt(
            "SELECT COUNT(*) FROM \"main\".sqlite_master WHERE \"type\"='table' AND \"name\"=?;",
            [.text(name)]
        )
        return (value ?? 0) > 0
    }

    func hasAnyUserTables() throws -> Bool {
        let names = try objectNames(type: "table")
        return names.contains { !$0.hasPrefix("sqlite_") }
    }

    // MARK: 事务

    /// 事务执行；嵌套调用时直接并入外层事务（与原版 better-sqlite3 的调用路径一致）。
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            return try body()
        }
        try execute("BEGIN IMMEDIATE;")
        transactionDepth += 1
        do {
            let result = try body()
            transactionDepth -= 1
            try execute("COMMIT;")
            return result
        } catch {
            transactionDepth -= 1
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func closedError(context: String) -> SQLiteError {
        SQLiteError(code: SQLITE_MISUSE, message: "数据库连接已关闭", context: context)
    }
}

// MARK: - Prepared statement

final class SQLiteStatement {
    private let database: SQLiteDatabase
    private var handle: OpaquePointer?
    let sql: String

    init(database: SQLiteDatabase, sql: String) throws {
        guard let databaseHandle = database.rawHandle else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "数据库连接已关闭", context: "准备 SQL")
        }
        self.database = database
        self.sql = sql
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(databaseHandle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let prepared = statement else {
            let message = String(cString: sqlite3_errmsg(databaseHandle))
            if let statement { sqlite3_finalize(statement) }
            throw SQLiteError(code: code, message: message, context: "SQL 预处理失败：\(Self.briefSQL(sql))")
        }
        self.handle = prepared
    }

    deinit {
        finalize()
    }

    func finalize() {
        guard let handle else { return }
        sqlite3_finalize(handle)
        self.handle = nil
    }

    // MARK: 绑定

    func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            try bind(value, at: Int32(offset + 1))
        }
    }

    func bind(_ value: SQLiteValue, at index: Int32) throws {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "语句已关闭", context: "绑定参数") }
        let code: Int32
        switch value {
        case .null:
            code = sqlite3_bind_null(handle, index)
        case .integer(let number):
            code = sqlite3_bind_int64(handle, index, number)
        case .real(let number):
            code = sqlite3_bind_double(handle, index, number)
        case .text(let string):
            code = string.withCString { pointer in
                sqlite3_bind_text(handle, index, pointer, -1, sqliteTransient)
            }
        }
        guard code == SQLITE_OK else {
            let message = database.rawHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "绑定参数失败"
            throw SQLiteError(code: code, message: message, context: "绑定第 \(index) 个参数：\(Self.briefSQL(sql))")
        }
    }

    // MARK: 执行

    /// 绑定参数并执行一次（内部会先 reset）；返回是否还有数据行。
    @discardableResult
    func execute(_ values: [SQLiteValue] = []) throws -> Bool {
        reset()
        try bind(values)
        return try step()
    }

    func reset() {
        guard let handle else { return }
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    /// 步进一行：true=SQLITE_ROW，false=SQLITE_DONE。
    @discardableResult
    func step() throws -> Bool {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "语句已关闭", context: "执行 SQL") }
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            let message = database.rawHandle.map { String(cString: sqlite3_errmsg($0)) } ?? "执行失败"
            throw SQLiteError(code: code, message: message, context: "执行 SQL：\(Self.briefSQL(sql))")
        }
    }

    // MARK: 列读取

    var columnCount: Int32 {
        guard let handle else { return 0 }
        return sqlite3_column_count(handle)
    }

    func isNull(_ index: Int32) -> Bool {
        guard let handle else { return true }
        return sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    func text(_ index: Int32) -> String? {
        guard let handle, sqlite3_column_type(handle, index) != SQLITE_NULL,
              let bytes = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: bytes)
    }

    func int64(_ index: Int32) -> Int64 {
        guard let handle else { return 0 }
        return sqlite3_column_int64(handle, index)
    }

    func int(_ index: Int32) -> Int {
        Int(int64(index))
    }

    func double(_ index: Int32) -> Double {
        guard let handle else { return 0 }
        return sqlite3_column_double(handle, index)
    }

    // MARK: 辅助

    private static func briefSQL(_ sql: String) -> String {
        let firstLine = sql.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? sql
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }
}
