import Foundation
import ServiceManagement
import MeloCore

/// 开机自启（macOS 13+ SMAppService；未签名/非 Applications 目录时可能注册失败，仅记录警告）
@MainActor
enum AutoLaunchManager {
    static func apply(enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return }
                try service.register()
                MeloLog.info("开机自启已开启")
            } else {
                guard service.status == .enabled || service.status == .requiresApproval else { return }
                try service.unregister()
                MeloLog.info("开机自启已关闭")
            }
        } catch {
            MeloLog.warn("设置开机自启失败：\(error.localizedDescription)")
        }
    }

    static func syncFromSettings() {
        apply(enabled: AppDelegate.model?.openAtLogin ?? false)
    }

    static var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }
}
