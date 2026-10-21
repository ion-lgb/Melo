# Melo · LX Music Desktop → macOS 原生 Swift 移植结项报告

> 对应目标：把 LX Music Desktop（v2.12.6）移植成仅 macOS 的原生 Swift 应用（SwiftUI/AppKit），复用落雪自定义源 JS 运行时，兼容现有 LxDatas 数据与主题/i18n 资源，并迭代完整功能。

## 1. 目标达成情况

| 目标 | 实现 | 证据 |
| --- | --- | --- |
| 仅 macOS 原生 Swift（SwiftUI/AppKit） | SwiftPM 工程 `macos/`：MeloCore / MeloData / MeloAudio / MeloJS / MeloUI / MeloApp / MeloSmoke；无 Electron、无 WKWebView；43,587 行 Swift（含测试） | `swift build` 零错误零警告；`build/Melo.app` 可直接运行 |
| 直接复用落雪自定义源 JS 运行时 | JavaScriptCore + 复刻原版 `user_api/renderer/preload.js` 语义（request/on/send/utils.buffer/crypto/zlib/EVENT_NAMES/env/version/currentScriptInfo、inited 白名单、musicUrl/lyric/pic 返回校验）；`user_api.json` 原版 `gz_`+base64 格式；支持文件导入与在线 URL 导入；旧版 musicInfo 结构自动转换 | 真实源（聆澜音源 v8.9.1）导入→激活→取链→AVPlayer 播放真实 269.8s 音频 PASS；真实源下载 MP3/FLAC 并写入标签 |
| 兼容现有 LxDatas 数据 | SQLite 原版 9 表 + 3 索引 DDL（default/love/temp/user 列表、music_info、order、lyric raw/edited、download_list、dislike_list、music_url 等）；`config_v2.json`（`{setting:{...}}` 135 键）、`user_api.json`、`theme.json`、`hot_key.json`、`data.json`（playInfo/listUpdateInfo）、`SoundEffect/convolution/*.wav` 全部按原版格式读写 | `swift test` 数据层 108 项；真实源/本地音乐/下载/备份恢复在工作目录数据上验证 |
| 主题/i18n 资源兼容 | 读取原版 `themes.json`（15 套主题含背景图主题）+ `LxDatas/theme.json` 用户主题，支持创建/编辑/导入导出/明暗自适应；`Localizer` 直接加载原版 `Resources/lang/*.json`（zh-cn/zh-tw/en-us/ko-kr），运行时切换语言，167 处静态文案已接入 | 主题编辑器截图；en-us 界面截图（Search/Charts/Playlists/Settings 等） |
| Phase 0 骨架（主窗口/列表/源/播放/歌词窗口/设置） | 全部完成并持续增强 | 各轮截图与 STATUS.md |
| 内置音源搜索/播放列表 CRUD/音效等迭代 | 五平台搜索/热搜/榜单/歌单/歌词/评论；列表 CRUD、多选、拖拽排序、排序/复制、导入导出；10 段 EQ、变速变调、真实 IR 卷积混响、3D 环绕；下载引擎+标签+.lrc；本地音乐导入/封面；备份恢复；开放 API（原版协议+自定义）；全局/本地快捷键；Scheme URL；输出设备；Now Playing/媒体键；音频可视化；评论面板等 | `docs/screenshots/` 截图；292 项测试；在线冒烟 |

## 2. 验证证据（结项时）

- `swift test`：**292 tests / 0 failures**（Core 34 + Data 108 + Audio 60 + JS 90；6 个在线门控默认 skip）
- `MeloSmoke --user-source`（真实聆澜源）：导入→激活→搜索「晴天」→源 API 取链（~575ms）→Range 校验→AVPlayer 播放进度 2.5s/269.8s **PASS**
- `MELO_ONLINE_TESTS=1 MeloSmoke --metadata-only`：kw/kg/tx/wy/mg 搜索、kg 榜单/歌单广场/歌单详情、kw 歌词 **全部 OK**
- `swift build` 全新构建：**0 warning / 0 error**
- App 实机：真实源在线播放、下载（含 .lrc）、自定义歌词关联、音频可视化、主题编辑器、备份恢复、开放 API curl 等均有截图/日志

## 3. 已知限制 / 未实现（明确记录）

- **数据同步（客户端/服务端）**：未实现（按用户决定后置）。
- **签名/公证/自动更新**：无 Apple 开发者账号，目前 ad-hoc 签名，仅本机可用；未接入 Sparkle 更新。
- **i18n 全量**：架构与资源已兼容，167 处静态文案已多语言；约 600 条自定义/插值文案仍为中文，需补翻译资源与逐条改造。
- **音频可视化**：仅音效引擎播放时提供频谱（AVPlayer 路径无频谱）；开启可视化会强制走音效引擎（远程歌曲首次需缓存）。
- **代理**：仅自定义源/内置元数据的 HTTP(S) 请求走代理（http 直连代理 absolute-form，https URLSession），AVPlayer 媒体流不受影响；不支持 SOCKS/PAC。
- **音效**：卷积混响为离线渲染，切换 IR/增益有一次性处理延迟；3D 环绕为立体声 pan（非 HRTF）；panner 声像不影响频谱。
- 其他：评论仅只读（无点赞/回复 API）；不支持 APE 等 AVFoundation 无法解码格式；ATS 限制下非白名单 http 媒体地址可能无法直接播放。

## 4. 构建与运行

```bash
cd macos
./Scripts/build-app.sh debug --run    # 构建并运行 build/Melo.app
swift test                            # 全量测试
swift run MeloSmoke --user-source /path/to/your-source.js \
  --search "晴天 周杰伦" --source kw --quality 320k --resources Resources
```
数据目录默认 `~/Library/Application Support/lx-music-desktop`（可用 `MELO_DATA_DIR` 覆盖），可直接读取原版 LxDatas。
