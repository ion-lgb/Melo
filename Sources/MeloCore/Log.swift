import Foundation
import os

/// 统一日志入口。开发期输出到 stderr / Console.app；后续可写入数据目录日志文件。
public enum MeloLog {
    private static let logger = Logger(subsystem: "cn.melo.mac", category: "app")
    public static var isVerbose: Bool = ProcessInfo.processInfo.environment["MELO_VERBOSE"] == "1"

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        if isVerbose { FileHandle.standardError.write(("[Melo] " + message + "\n").data(using: .utf8)!) }
    }

    public static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        if isVerbose { FileHandle.standardError.write(("[Melo][warn] " + message + "\n").data(using: .utf8)!) }
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FileHandle.standardError.write(("[Melo][error] " + message + "\n").data(using: .utf8)!)
    }
}
