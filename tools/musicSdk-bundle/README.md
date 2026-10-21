# musicSdk → JavaScriptCore bundle

把上游 LX Music Desktop v2.12.6 的内置元数据源（`src/renderer/utils/musicSdk` 的
kw/kg/tx/wy/mg，不含 bd）打包成单文件 IIFE bundle，供 macOS App 的
`MeloJS.JSMetadataService` 在独立 JavaScriptCore 中运行。

App 运行不依赖 Node/npm；仓库内保留生成产物 `Resources/js/musicSdk.bundle.js`
（约 235 KiB / 240,822 bytes，63 modules）。

## 重新生成

本仓库不包含上游源码。重新生成 bundle 需要先拉取上游 v2.12.6 源码（Apache-2.0）：

```bash
# 仓库根目录
bash Scripts/fetch-upstream-source.sh   # 下载上游源码 -> tools/musicSdk-bundle/upstream/src

cd tools/musicSdk-bundle
npm install          # 仅开发依赖：esbuild / pako / buffer（node_modules 已被 gitignore）
npm run build        # = node bundle.mjs -> Resources/js/musicSdk.bundle.js
```

`upstream/` 与 `node_modules/` 均不提交。

## 结构

- `entry.js`：导入各源 musicSearch/leaderboard/songList/hotSearch/lyric/pic/comment，
  组装 `globalThis.MeloMetadata`（搜索/榜单/歌单/歌词/评论 + Swift 轮询胶水 `__meloCall`）；
- `shims/globals.js`：Buffer/navigator/document/process/console/timers 以及 JSC 缺失的
  URLSearchParams/URL/TextEncoder/TextDecoder 最小 polyfill；
- `shims/request-shim.js`：替代 `src/renderer/utils/request.js`/needle，底层调用
  Swift 注入的 `__meloNative.http`；body/form 在 JS 侧定型（QQ 音乐等需要原始 body 校验 sign）；
- `shims/crypto-shim.js`：Node crypto 语义（md5/sha1、AES CBC/ECB encrypt/decrypt、
  RSA_NO_PADDING、randomBytes），底层调 `__meloNative.hash/aesEncrypt/aesDecrypt/rsaEncrypt`；
- `shims/zlib-shim.js`：pako 实现的 inflate/deflate/inflateRaw/deflateRaw（含 Z_SYNC_FLUSH 容错）；
- `shims/renderer-utils-shim.js`：formatPlayTime/sizeFormate/decodeName/dateFormat/toMD5 等；
- `shims/dns-shim.js`、`shims/renderer-store-shim.js`：未使用的 Node/store 依赖 stub；
- `shims/music-info.js`：原版 `toNewMusicInfo` / `toOldMusicInfo` 逻辑副本；
- `fixtures/stub-metadata-bundle.js`：Tests/MeloJSTests 离线 JSON/错误/超时测试桩；
- `dev-check.mjs`：Node 开发期验证（`node dev-check.mjs [--online]`），模拟 `__meloNative`。

## Swift 侧

- `Sources/MeloJS/JSMetadataRuntime.swift`：JSContext 宿主 + `__meloNative` 原生桥；
- `Sources/MeloJS/JSMetadataService.swift`：`MetadataService` 协议实现（20s 超时/MetadataError）。

## 已知限制

- mg 歌词不可用：原版 v2.12.6 `mg/musicInfo.js` 自身 bug（`Promise.all(createGetMusicInfosTask(...))`
  把 Promise 传给 `Promise.all`）+ 2026 接口漂移；mg 搜索/歌单正常。
- kw/wy 未提供逐字歌词（上游返回无 lxlyric）；tx/kg 逐字可用。
- 真实平台接口可能随上游变化；单源失败在聚合搜索中被隔离为空结果。
