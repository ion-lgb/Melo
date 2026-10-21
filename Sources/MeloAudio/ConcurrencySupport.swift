import Foundation

/// 把 AVFoundation 的回调安全地切回主线程 / MainActor。
///
/// - 已经在主线程时同步执行，保证事件顺序（进度回调等）；
/// - 否则异步跳回 MainActor（KVO / NotificationCenter 不保证投递线程）。
@inline(__always)
func onMainActor(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        Task { @MainActor in body() }
    }
}

/// Audio 模块共享的运行环境判断。
enum AudioEnvironment {
    /// 是否运行在 XCTest 进程。
    ///
    /// 测试进程默认不注册全局媒体键 / 不写系统 Now Playing（避免抢占用户系统的媒体控制），
    /// 测试需要时可用 `systemIntegrationEnabled = true` 显式开启。
    static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        if NSClassFromString("XCTestCase") != nil { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }
}
