import Foundation
import MeloCore
import MeloData

/// 把 MeloData 的 `DownloadEngine` 适配成 MeloCore 的 `DownloadService`（避免 MeloCore 反向依赖数据层）。
@MainActor
final class MeloDownloadService: DownloadService {
    private let engine: DownloadEngine
    var onTasksChanged: (() -> Void)?

    init(maxConcurrent: Int = 3) {
        let engine = DownloadEngine(maxConcurrent: max(1, min(maxConcurrent, 10)))
        self.engine = engine
        engine.eventHandler = { [weak self] event in
            Task { @MainActor in
                if case .completed(_, let filePath) = event {
                    MeloLog.info("下载完成：\(filePath)")
                }
                self?.onTasksChanged?()
            }
        }
    }

    var tasks: [DownloadTaskInfo] { engine.tasks }

    @discardableResult
    func enqueue(music: MusicInfo, quality: String, url: URL, saveDirectory: URL,
                 fileName: String, fileExtension: String,
                 embedPicture: Bool, embedLyrics: Bool,
                 lyrics: LyricInfo?, pictureURL: URL?) -> String {
        engine.enqueue(DownloadRequest(
            music: music,
            quality: quality,
            url: url,
            saveDirectory: saveDirectory,
            fileName: fileName,
            fileExtension: fileExtension,
            embedPicture: embedPicture,
            embedLyrics: embedLyrics,
            lyrics: lyrics,
            pictureURL: pictureURL
        ))
    }

    func restore(tasks: [DownloadTaskInfo]) {
        engine.restore(tasks: tasks)
        onTasksChanged?()
    }

    func setLrcFile(taskID: String, content: String, encoding: String) {
        engine.setLrcFile(taskID: taskID, content: content, encoding: encoding)
    }

    func pause(id: String) { engine.pause(id: id) }
    func resume(id: String) { engine.resume(id: id) }
    func cancel(id: String) { engine.cancel(id: id) }
    func remove(id: String) { engine.remove(id: id) }
}
