import MeloCore
import MeloData

/// MeloData.AppDataFileStore 与 MeloCore.AppDataStore 协议签名一致，直接桥接。
extension AppDataFileStore: AppDataStore {}
