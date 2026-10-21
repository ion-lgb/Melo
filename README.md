# Melo for macOS

> **LX Music Desktop 的 macOS 原生 Swift 移植** —— 保留原版的数据格式、主题、语言包与自定义源脚本生态，用 SwiftUI + AppKit 重写为仅 macOS 的原生应用。

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)](#系统要求)
[![Swift](https://img.shields.io/badge/Swift-6.4-orange)](https://swift.org)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-292-brightgreen)](#测试)

**Melo 是非官方移植项目，与 LX Music Desktop 官方无关。** 本项目不内置任何第三方音源脚本或 API Key；自定义源由用户自行导入，仅供学习与个人使用，请遵守当地法律及各音乐平台的服务条款。

---

## 目录

- [特性](#特性)
- [截图](#截图)
- [系统要求](#系统要求)
- [快速开始](#快速开始)
- [功能说明](#功能说明)
- [项目架构](#项目架构)
- [数据兼容](#数据兼容)
- [自定义源兼容](#自定义源兼容)
- [开发](#开发)
- [已知限制](#已知限制)
- [许可证与致谢](#许可证与致谢)

## 特性

- **纯原生**：SwiftUI + AppKit，无 Electron、无 WKWebView、无第三方 Swift 依赖；仅支持 macOS 14+。
- **直接复用落雪自定义源**：内置 JavaScriptCore 运行时，按原版 `preload.js` 语义注入 `lx` API；用户像原版一样导入 `.js` 源即可，不重写、不内置源脚本。
- **数据零迁移**：直接读写原版 `LxDatas`（SQLite 原 DDL、`config_v2.json`、`user_api.json`、`theme.json`、`hot_key.json`、`data.json`），可与 LX Music Desktop 共用同一数据目录。
- **完整播放能力**：AVPlayer 流播放 + 音效引擎（10 段 EQ、变速变调、真实 IR 卷积混响、3D 环绕、音频可视化）、播放队列/模式、定时暂停、播放进度记忆、错误自动切歌。
- **元数据与曲库**：酷我/酷狗/QQ 音乐/网易云/咪咕 五平台搜索、热搜、榜单、歌单广场/详情、歌词、评论；用户列表 CRUD、导入导出、排序、在线列表更新、不喜欢歌曲规则。
- **下载与本地音乐**：断点续传/重试、并发队列、MP3/FLAC 标签与封面写入、`.lrc` 歌词文件（UTF-8/GBK）、下载历史；本地音乐扫描导入、封面提取。
- **外观与歌词**：15 套内置主题 + 主题编辑器、明暗自适应；桌面歌词窗口（逐字/翻译/罗马音、样式与快捷键）、歌词偏移、本地歌词关联。
- **系统集成**：全局快捷键、媒体键与 Now Playing、`lxmusic://` Scheme URL、菜单栏常驻、窗口状态记忆、音频输出设备选择、开机自启。
- **开放 API**：兼容原版 LX 开放 API 协议（本机/局域网、SSE 状态订阅），并扩展自定义 token 接口。
- **备份恢复**：兼容原版 `.lxmc`（gzip JSON）全部数据/列表/设置导入导出。

## 截图

| 主界面 | 搜索 |
| --- | --- |
| ![主界面](docs/screenshots/main-playing.png) | ![搜索](docs/screenshots/search-real.png) |

| 播放详情（逐字歌词） | 桌面歌词 |
| --- | --- |
| ![逐字歌词](docs/screenshots/lyric-karaoke.png) | ![桌面歌词](docs/screenshots/desktop-lyric-styled.png) |

| 设置 | 主题编辑器 |
| --- | --- |
| ![设置](docs/screenshots/settings.png) | ![主题编辑器](docs/screenshots/theme-editor.png) |

| 音效（EQ/卷积混响/3D） | 音频可视化 |
| --- | --- |
| ![音效](docs/screenshots/effects-playing.png) | ![音频可视化](docs/screenshots/audio-visualization.png) |

| 下载管理 | 在线列表更新 |
| --- | --- |
| ![下载](docs/screenshots/download-page.png) | ![列表更新](docs/screenshots/list-update.png) |

更多截图见 [`docs/screenshots/`](docs/screenshots/)。

## 系统要求

| 项 | 要求 |
| --- | --- |
| 系统 | macOS 14.0+（Sonoma 及以上） |
| 构建工具 | Xcode 26+ / Swift 6.4（SwiftPM 工程，无第三方 Swift 依赖） |
| 可选 | Node.js 18+（仅开发期重新生成内置元数据 bundle 时需要） |
| 硬件 | Apple Silicon / Intel Mac |

## 快速开始

### 构建并运行

```bash
git clone https://github.com/ion-lgb/Melo.git
cd Melo
./Scripts/build-app.sh debug --run     # 构建并启动 build/Melo.app
# 或
./Scripts/build-app.sh release --run   # release 构建
```

构建产物：`build/Melo.app`。也可直接 `open build/Melo.app`。当前为 ad-hoc 签名（未公证），首次打开若被 Gatekeeper 拦截，请在 **系统设置 → 隐私与安全性** 中选择「仍要打开」。

开发期直接运行（不含 `.app` 包）：

```bash
MELO_RESOURCES="$PWD/Resources" swift run Melo
```

### 首次使用

1. **数据目录**：默认读写原版路径 `~/Library/Application Support/lx-music-desktop/LxDatas/`。首次使用建议先备份该目录；**不要同时运行原版 LX Music**（SQLite 单写者）。
   使用其他数据目录：
   ```bash
   MELO_DATA_DIR="/path/to/userData" build/Melo.app/Contents/MacOS/Melo
   ```
2. **导入自定义源**：设置 → 自定义源 →「导入源文件…」或「从链接导入…」，导入后自动激活。
3. **播放**：搜索/榜单/歌单中双击歌曲；没有可用源时播放会提示先导入自定义源。

### 运行测试

```bash
swift test                                        # 292 项单元/集成测试
swift run MeloSmoke --metadata-only --online      # 五平台在线元数据冒烟（需联网）
bash Scripts/smoke-test.sh                        # 本地 demo server 端到端冒烟
```

## 功能说明

- **播放与音效**：播放/暂停、上一首/下一首、随机/列表/单曲/顺序模式、播放队列管理、倍速、音量、定时暂停、启动自动播放、记住进度、播放错误自动切歌。
- **音效引擎**：10 段均衡器、变速变调、13 组真实录音 IR 卷积混响、3D 环绕声像、输出设备选择；仅在使用音效/可视化时启用（普通播放走 AVPlayer 流式）。
- **歌词**：LRC 解析、逐字歌词、翻译/罗马音、桌面歌词（置顶/锁定/样式/偏移/暂停隐藏）、歌词手动偏移、本地 `.lrc` 关联。
- **下载**：并发下载、断点续传、失败重试、标签/封面写入、歌词文件保存（UTF-8 BOM / GBK）、下载历史与任务恢复。
- **列表**：试听/收藏/临时/用户列表、多选与拖拽排序、复制/排序/重命名、文本与 CSV 导出、在线源歌单同步、`.lxmc` 备份恢复、不喜欢歌曲过滤。
- **主题与语言**：读取原版 `themes.json` + 用户主题、主题编辑器、背景图/模糊/透明度；原版四语言资源（中/繁/英/韩）与运行时切换。
- **系统**：全局快捷键、媒体键、Now Playing、菜单栏、`lxmusic://`、开机自启、窗口状态记忆。
- **开放 API**：兼容原版 LX 开放 API（状态/播放控制/歌词/SSE 订阅），支持局域网绑定与 Token 鉴权。

## 项目架构

SwiftPM 多 target 工程（无外部依赖）：

| Target | 职责 |
| --- | --- |
| `MeloCore` | 模型、协议、设置、主题、i18n、歌词解析、`AppModel`（UI 唯一入口） |
| `MeloData` | SQLite（兼容原版 DDL）、下载引擎、标签写入、本地音乐扫描、缓存 |
| `MeloAudio` | AVPlayer 播放、音效引擎（EQ/卷积/3D/可视化）、输出设备、Now Playing |
| `MeloJS` | JavaScriptCore 自定义源运行时、musicSdk 元数据 bundle、HTTP、开放 API 服务 |
| `MeloUI` | SwiftUI 视图（仅依赖 MeloCore） |
| `MeloApp` | `@main` 入口、服务装配、AppKit 窗口/菜单/Scheme |
| `MeloSmoke` | 端到端冒烟 CLI |

```
.
├── Package.swift
├── Sources/           # 7 个 target（见上表）
├── Resources/         # 主题/语言/图片/SoundEffect/musicSdk.bundle.js/default-settings.json
├── Tests/             # XCTest（Core/Data/Audio/JS）
├── TestAssets/        # 仅开发测试：示例自定义源与测试音频元数据（不进 App bundle）
├── Scripts/           # build-app.sh / smoke-test.sh / make-test-data.py / demo-server.mjs / fetch-upstream-source.sh
├── tools/             # musicSdk-bundle 生成工具（开发期）
├── docs/              # 结项报告与截图
├── Info.plist
└── ARCHITECTURE.md    # 架构与设计决策
```

依赖方向：`MeloApp → {MeloCore, MeloData, MeloAudio, MeloJS, MeloUI}`，`MeloUI → MeloCore`，其余模块 → `MeloCore`。

## 数据兼容

- 数据目录：`~/Library/Application Support/lx-music-desktop/LxDatas/`（`MELO_DATA_DIR` 可覆盖）。
- `lx.data.db`：原版 9 表 + 3 索引 DDL、WAL 模式、`db_info.version=2`；不迁移、不重建。
- `config_v2.json`：`{ "setting": { ... } }`，保留未知顶层键。
- `user_api.json`：`{ "userApis": [{ "script": "gz_<base64(zlib)>", ... }] }`，与原版互通。
- `theme.json`、`hot_key.json`、`data.json`（`playInfo` / `listUpdateInfo`）、`lyric`（`raw`/`edited`）、`download_list`、`dislike_list` 均按原版格式读写。
- 备份文件：原版 `.lxmc`（gzip JSON：`allData_v2` / `playList_v2` / `setting_v2`）。

## 自定义源兼容

- 自定义源脚本在独立 JavaScriptCore 中运行；`lx.on`/`lx.send`/`lx.request`/`lx.utils`（buffer/crypto/zlib）/`lx.EVENT_NAMES`/`lx.env`/`lx.version` 等按原版 `user_api/renderer/preload.js` 语义实现。
- 兼容原版 `user_api.json` 存储与导入流程；旧版 musicInfo 结构会自动转换。
- **本仓库不包含、不内置任何自定义源脚本或 API Key**；测试用源位于 `TestAssets/`（仅本地 demo，不会被 App 打包运行）。自定义源版权与合规责任归其作者/使用者。

## 开发

```bash
# 编译
swift build

# 单元/集成测试
swift test

# App 打包（ad-hoc 签名）
./Scripts/build-app.sh debug

# 本地 test server + 生成的 LxDatas 测试数据 + MeloSmoke
bash Scripts/smoke-test.sh
```

### 重新生成内置元数据 bundle（可选）

`Resources/js/musicSdk.bundle.js` 由上游 LX Music Desktop v2.12.6 的 `musicSdk` 模块（Apache-2.0）在开发期打包生成，App 运行不依赖 Node：

```bash
bash Scripts/fetch-upstream-source.sh     # 下载上游源码到 tools/musicSdk-bundle/upstream/
cd tools/musicSdk-bundle
npm install
npm run build                             # 产物写回 Resources/js/musicSdk.bundle.js
```

上游源码与 `node_modules/` 均不提交（见 `tools/musicSdk-bundle/README.md`）。

### 调试

常用环境变量：`MELO_DATA_DIR`（数据目录）、`MELO_RESOURCES`（资源目录）、`MELO_VERBOSE=1`（详细日志）、`MELO_ROUTE=settings`（启动页）等；完整列表见 [STATUS.md](STATUS.md#开发期环境变量)。

架构细节与设计决策见 [ARCHITECTURE.md](ARCHITECTURE.md)；目标达成情况与验证记录见 [docs/PORT-COMPLETION.md](docs/PORT-COMPLETION.md)。

## 已知限制

- 数据同步（客户端/服务端）尚未实现。
- 无 Developer ID，当前为 ad-hoc 签名，未公证、未接入自动更新。
- i18n 架构与资源已兼容、核心静态文案已多语言，部分自定义/插值文案仍为中文。
- 音频可视化仅音效引擎播放时可用；开启可视化会强制走音效引擎（远程歌曲首次需缓存）。
- 网络代理仅覆盖自定义源/内置元数据的 HTTP(S) 请求，AVPlayer 媒体流不受影响；不支持 SOCKS/PAC。
- 音效卷积混响为离线渲染（切换 IR 有一次处理延迟）；3D 环绕为立体声 pan（非 HRTF）。
- 评论为只读（原版接口无点赞/回复）；AVFoundation 无法解码的格式（如 APE）不支持。
- 仅支持 macOS 14+；Windows/Linux 不再维护。

## 许可证与致谢

本项目以 [Apache License 2.0](LICENSE) 发布。

- 感谢 **lyswhut** 及 **LX Music Desktop** 贡献者：<https://github.com/lyswhut/lx-music-desktop>。
- 本移植复用上游的数据格式、主题、语言包、音效资源与自定义源生态；原项目版权归其作者所有，详见 [NOTICE](NOTICE)。
- `Resources/js/musicSdk.bundle.js` 由上游源码在开发期生成；仓库不包含上游源码。
- 自定义源脚本由各自作者提供，本项目不提供、不内置任何音源。

## 免责声明

本项目为个人学习与技术研究用途的非官方移植，不提供任何音乐内容或音源。使用者应自行确保其行为符合当地法律法规及各音乐平台的服务条款；因使用第三方自定义源产生的任何问题与责任由使用者自行承担。
