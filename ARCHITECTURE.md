# Melo for macOS — 原生 Swift 移植工程

> 本目录是 **LX Music Desktop（v2.12.6）→ macOS 原生 Swift 应用** 的移植工程。
> 目标平台：**仅 macOS 14+**（iPhone/iPad 暂不做，后续可能扩展）。Windows/Linux 明确放弃。
> 编码语言/框架：Swift 5 language mode（Swift 6.4 工具链）+ SwiftUI / AppKit / AVFoundation / JavaScriptCore / SQLite3，**零第三方依赖**。

## 1. 用户决策记录（2026-10-19）

| # | 决策 | 落地方式 |
| --- | --- | --- |
| 1 | 自定义源复用现有 LX 自定义源脚本，**不重写、不内置** | JavaScriptCore 运行时（`MeloJS`）按原版 `preload.js` 语义注入 `globalThis.lx`；源脚本由用户导入，不打包进 App。测试用源放 `TestAssets/`，仅测试、不入 App bundle。 |
| 2 | UI 由工程方决定 | 全原生 SwiftUI（非 WKWebView 套壳），采用 macOS 原生导航/表格/工具栏/播放条，视觉上参考原版信息架构但不做像素级复刻。 |
| 3 | 仅 macOS | 不实现 Windows/Linux 分支；原版 Electron 工程保留作参考，不再维护。 |
| 4 | 功能取舍 | 同步（客户端/服务端）**后置**；开放 API **后置**（低成本，Phase 2）；音效/EQ/卷积 **Phase 2**；下载 **Phase 2**；桌面歌词 Phase 1；主题（15 套内置）+ 4 语言 **Yes**；托盘/全局热键/URL Scheme/媒体键 **Yes**；自动更新/签名公证待 Developer ID（暂无账号）。 |
| 5 | 必须兼容现有数据与自定义源，"直接套用它的方法" | SQLite 原 DDL + 原数据目录；`config_v2.json` 原嵌套结构；`user_api.json` 原 `gz_` deflate+base64 格式；`theme.json` 原格式；主题/语言资源直接复用原版 JSON。 |

## 2. 模块结构

```
<repo root>
├── Package.swift                 # SwiftPM，7 个 target（无外部依赖）
├── Sources/
│   ├── MeloCore/                 # 模型/协议/设置/主题/i18n/歌词解析/根 AppModel   ← Lead 所有
│   ├── MeloData/                 # SQLite（兼容原版 lx.data.db 9 表 3 索引）        ← data 队友
│   ├── MeloAudio/                # AVPlayer 流播放 + Now Playing/媒体键             ← audio 队友
│   ├── MeloJS/                   # JavaScriptCore 自定义源运行时                     ← js 队友
│   ├── MeloUI/                   # SwiftUI 视图（只依赖 MeloCore）                  ← ui 队友
│   └── MeloApp/                  # @main 入口 + 服务装配 + AppKit 窗口/菜单         ← Lead
├── Resources/                    # themes.json / lang / images / prelude.js / icon.icns / default-settings.json
├── TestAssets/                   # 仅测试用：示例自定义源、测试音频（不进 App bundle）
├── Tests/                        # XCTest
└── Scripts/build-app.sh          # 组装 Melo.app（Info.plist + Resources + ad-hoc 签名）
```

依赖方向：`MeloApp → {MeloCore, MeloData, MeloAudio, MeloJS, MeloUI}`；`MeloUI → MeloCore`；其余模块 `→ MeloCore`。

## 3. 关键接口（以 `Sources/MeloCore/Protocols.swift` 为准）

- `DataService`：曲库 SQLite 读写（列表/歌曲/歌词/URL 缓存/下载任务/不喜欢）。
- `PlayerService`：AVPlayer 播放，事件通过 `eventHandler(PlayerEvent)` 回推；媒体键下一首/上一首回调。
- `CustomSourceService`：自定义源导入/激活/取链/取歌词，`eventHandler(CustomSourceEvent)` 回推状态/日志。
- `MetadataService`：内置元数据源（Phase 1 起，通过 JSC 复用原版 `musicSdk`）。
- `AppModel`（`@MainActor @Observable`）：UI 唯一入口，持有全部状态与业务动作。

## 4. 数据兼容要点（必须遵守）

1. 数据目录：`~/Library/Application Support/lx-music-desktop/LxDatas/`（可用 `MELO_DATA_DIR` 覆盖）。
2. SQLite `lx.data.db`：
   - 建表 SQL 必须与上游 LX Music `src/main/worker/dbService/tables.ts` **逻辑一致**（原版 `verifyDB` 会做归一化字面比对；上游源码不在本仓库）；
   - WAL 模式；`db_info.version='2'`；老库 version 1 时补 `dislike_list` 并升级。
3. 设置：`config_v2.json`，结构 `{ "setting": { ... }, <其他顶层键保留> }`。
4. 自定义源：`user_api.json`，结构 `{ "userApis": [ { id,name,description,author,homepage,version,allowShowUpdateAlert,script:"gz_<base64(zlib deflate)>" } ] }`。
5. 激活源记录：`config_v2.json` 的 `common.apiSource` = `user_api_xxx`（与原版一致）。
6. 用户主题：`theme.json` → `{ "themes": [Theme] }`；背景图在 `LxDatas/theme_images/`。
7. 单写者：开发/测试时不要同时运行原版 LX Music，避免 SQLite 缓存不一致。

## 5. 构建与运行（Phase 0）

```bash
cd macos
swift build                       # 全量
Scripts/build-app.sh              # 生成 build/Melo.app（ad-hoc 签名）
open build/Melo.app
# 开发时也可直接：
MELO_RESOURCES="$PWD/Resources" MELO_DATA_DIR="$HOME/Library/Application Support/lx-music-desktop" swift run Melo
```

测试：

```bash
cd macos && swift test
# 各模块单独编译（避免并发构建锁冲突）：
swift build --target MeloData --scratch-path /tmp/melo-build-data
```

## 6. 验收标准（Phase 0 起，后续迭代见 STATUS.md）

1. App 原生窗口可启动，可切换页面（搜索/排行榜/歌单/我的列表/下载/设置）。
2. 直接读取原版 `LxDatas/lx.data.db`（或首次按原 DDL 建库），展示列表与歌曲。
3. 设置页可导入自定义源 `.js`；激活后显示源能力（source/qualitys/actions）。
4. 测试页可用活动源解析 musicUrl 并 **用 AVPlayer 播放**；播放条/进度/音量/切歌可用。
5. 歌词：可从原数据库/源脚本读取并逐行高亮显示；桌面歌词窗口可显示。
6. 15 套主题 + 4 语言可切换并持久化（写回 `config_v2.json`，不破坏原版兼容）。
7. `Scripts/build-app.sh` 可产出可双击运行的 `Melo.app`。

## 7. 编码约定

- 全部模块 `import MeloCore`；禁止跨模块反向依赖。
- 线程/并发：UI 与业务状态统一 `@MainActor`；耗时任务用 `Task { }`，回调通过 `eventHandler`。
- 网络：`URLSession`（系统）；禁止引入第三方包。
- 资源读取：`ResourceLocator`。
- 文案：新 UI 可直接中文；已有文案优先用 `Localizer.t(key)`。
- 测试资产放 `TestAssets/`，**不得打包进 App**。
- 不要修改 `../src/`（原版 Electron 源码，仅作参考）。
