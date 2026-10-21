// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeloMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Melo", targets: ["MeloApp"]),
    ],
    targets: [
        // 共享模型 / 协议 / 设置 / 主题 / 国际化 / 根 AppModel
        .target(name: "MeloCore", path: "Sources/MeloCore"),

        // 数据层：SQLite（兼容原版 lx.data.db）+ JSON 存储
        .target(
            name: "MeloData",
            dependencies: ["MeloCore"],
            path: "Sources/MeloData",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // 音频层：AVPlayer 流播放 + 系统媒体键 + 歌词时间轴
        .target(
            name: "MeloAudio",
            dependencies: ["MeloCore"],
            path: "Sources/MeloAudio",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("MediaPlayer"),
            ]
        ),

        // JS 运行时：JavaScriptCore 承载落雪自定义源脚本（不重写、不内置源）
        .target(
            name: "MeloJS",
            dependencies: ["MeloCore"],
            path: "Sources/MeloJS",
            linkerSettings: [
                .linkedFramework("JavaScriptCore"),
                .linkedFramework("Security"),
                .linkedFramework("Network"),
            ]
        ),

        // UI 层：SwiftUI 视图（仅依赖 MeloCore）
        .target(name: "MeloUI", dependencies: ["MeloCore"], path: "Sources/MeloUI"),

        // 可执行入口：装配服务 + 窗口
        .executableTarget(
            name: "MeloApp",
            dependencies: ["MeloCore", "MeloData", "MeloAudio", "MeloJS", "MeloUI"],
            path: "Sources/MeloApp"
        ),

        // 无界面端到端冒烟测试（数据 + 自定义源 + 播放器 + 歌词）
        .executableTarget(
            name: "MeloSmoke",
            dependencies: ["MeloCore", "MeloData", "MeloAudio", "MeloJS"],
            path: "Sources/MeloSmoke"
        ),

        .testTarget(name: "MeloCoreTests", dependencies: ["MeloCore"], path: "Tests/MeloCoreTests"),
        .testTarget(name: "MeloDataTests", dependencies: ["MeloData", "MeloCore"], path: "Tests/MeloDataTests"),
        .testTarget(name: "MeloJSTests", dependencies: ["MeloJS", "MeloCore"], path: "Tests/MeloJSTests"),
        .testTarget(name: "MeloAudioTests", dependencies: ["MeloAudio", "MeloCore"], path: "Tests/MeloAudioTests"),
    ],
    swiftLanguageModes: [.v5]
)
