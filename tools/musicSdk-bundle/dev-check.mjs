// 开发期 Node 验证脚本（不参与 App 构建）：
// 用 Node fetch/crypto 模拟 Swift 侧 __meloNative 桥，直接加载 bundle 验证
// adapter 逻辑与真实平台接口可用性。
//
// 用法：
//   node dev-check.mjs            # 离线（prepare/排行榜/排序/参数校验）
//   node dev-check.mjs --online   # 额外执行真实：kw 热搜 + 「周杰伦」搜索
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  createHash, randomBytes as nodeRandomBytes, createCipheriv, createDecipheriv,
  publicEncrypt, constants as nodeConstants,
} from 'node:crypto'

const here = path.dirname(fileURLToPath(import.meta.url))
const bundlePath = path.resolve(here, '../../Resources/js/musicSdk.bundle.js')
const online = process.argv.includes('--online')

// bundle 的 globals.js 会覆盖 console；开发脚本统一走 stdout 直写
const out = (...args) => {
  const text = args.map(arg => {
    if (typeof arg === 'string') return arg
    try { return JSON.stringify(arg) } catch { return String(arg) }
  }).join(' ')
  process.stdout.write(text + '\n')
}

const realSetTimeout = globalThis.setTimeout
const realClearTimeout = globalThis.clearTimeout
const realSetInterval = globalThis.setInterval
const realClearInterval = globalThis.clearInterval
const controllers = new Map()
const timers = new Map()

globalThis.__meloNative = {
  log(level, message) {
    if (process.env.MELO_VERBOSE || level === 'error' || level === 'warn') {
      process.stderr.write(`[js][${level}] ${message}\n`)
    }
  },
  http(id, url, optionsJSON) {
    const options = JSON.parse(optionsJSON)
    const controller = new AbortController()
    controllers.set(id, controller)
    const headers = { ...(options.headers || {}) }
    let body
    const method = String(options.method || 'get').toUpperCase()
    if (options.body !== undefined && options.body !== null) {
      if (typeof options.body === 'string') body = options.body
      else {
        body = JSON.stringify(options.body)
        if (!headers['Content-Type'] && !headers['content-type']) headers['Content-Type'] = 'application/json'
      }
    } else if (options.form && typeof options.form === 'object') {
      body = new URLSearchParams(Object.entries(options.form).map(([key, value]) => [key, String(value)])).toString()
      if (!headers['Content-Type'] && !headers['content-type']) headers['Content-Type'] = 'application/x-www-form-urlencoded'
    }
    if (process.env.MELO_HTTP_DEBUG && String(url).includes('musics.fcg')) {
      process.stderr.write(`[node-http] ${method} ${String(url).slice(0, 200)}\nBODY ${body ? String(body).slice(0, 200) : '-'}\n`)
    }
    const timeout = Number(options.timeout) || 15000
    const timer = realSetTimeout(() => controller.abort(new Error('timeout')), timeout + 5000)
    fetch(url, { method, headers, body, signal: controller.signal, redirect: 'follow' })
      .then(async response => {
        const buffer = Buffer.from(await response.arrayBuffer())
        const responseHeaders = {}
        response.headers.forEach((value, key) => { responseHeaders[key] = value })
        globalThis.__meloNativeHttpResponse(id, null, JSON.stringify({
          statusCode: response.status,
          statusMessage: response.statusText,
          headers: responseHeaders,
          bytes: buffer.length,
          bodyBase64: buffer.toString('base64'),
        }))
      })
      .catch(error => {
        const message = error && error.name === 'AbortError' ? 'aborted' : String(error && error.message || error)
        globalThis.__meloNativeHttpResponse(id, message, null)
      })
      .finally(() => {
        realClearTimeout(timer)
        controllers.delete(id)
      })
  },
  httpCancel(id) {
    controllers.get(id)?.abort()
  },
  hash(algorithm, bytes) {
    return createHash(String(algorithm)).update(Buffer.from(bytes)).digest('hex')
  },
  aesEncrypt(bytes, mode, key, iv) {
    const cipher = createCipheriv(mode, Buffer.from(key), iv && iv.length ? Buffer.from(iv) : null)
    return Array.from(Buffer.concat([cipher.update(Buffer.from(bytes)), cipher.final()]))
  },
  aesDecrypt(bytes, mode, key, iv) {
    const decipher = createDecipheriv(mode, Buffer.from(key), iv && iv.length ? Buffer.from(iv) : null)
    return Array.from(Buffer.concat([decipher.update(Buffer.from(bytes)), decipher.final()]))
  },
  rsaEncrypt(bytes, pem) {
    const blockSize = 128
    const padded = Buffer.concat([Buffer.alloc(blockSize - bytes.length), Buffer.from(bytes)])
    return Array.from(publicEncrypt({ key: pem, padding: nodeConstants.RSA_NO_PADDING }, padded))
  },
  randomBytes(size) {
    return Array.from(nodeRandomBytes(size))
  },
  timerStart(id, callback, delay, repeat) {
    const timer = repeat
      ? realSetInterval(callback, Math.max(Number(delay) || 0, 1))
      : realSetTimeout(callback, Number(delay) || 0)
    timers.set(id, timer)
  },
  timerCancel(id) {
    const timer = timers.get(id)
    if (timer) {
      realClearTimeout(timer)
      realClearInterval(timer)
      timers.delete(id)
    }
  },
}

const code = fs.readFileSync(bundlePath, 'utf8')
;(0, eval)(code)

// bundle 的 globals.js 会覆盖 Node 全局定时器；Node 的 undici(fetch) 依赖原生定时器对象，
// 开发脚本在 bundle 加载后恢复（App 内由 JSC + Swift native timer 提供等价能力）。
globalThis.setTimeout = realSetTimeout
globalThis.clearTimeout = realClearTimeout
globalThis.setInterval = realSetInterval
globalThis.clearInterval = realClearInterval

const metadata = globalThis.MeloMetadata
if (!metadata) {
  out('bundle 未暴露 globalThis.MeloMetadata')
  process.exit(1)
}
out('bundle loaded, size =', code.length, 'bytes')

const call = async (method, ...args) => {
  try {
    return await metadata[method](...args)
  } catch (error) {
    if (process.env.MELO_DEBUG) process.stderr.write(`[debug] ${method} failed:\n${error && error.stack}\n`)
    return { __error: String((error && error.message) || error) }
  }
}

out('\n== prepare ==')
out(JSON.stringify(await call('prepare'), null, 2))
out('sources =', JSON.stringify(metadata.sources))

out('\n== 离线：排行榜（静态列表，不发网络请求）==')
for (const source of ['kw', 'kg', 'tx', 'wy', 'mg']) {
  const boards = await call('leaderboards', source)
  out(source, Array.isArray(boards) ? `${boards.length} boards, first=${JSON.stringify(boards[0])}` : boards)
}

out('\n== 离线：歌单排序（静态）==')
for (const source of ['kw', 'kg', 'tx', 'wy', 'mg']) {
  const sorts = await call('songListSorts', source)
  out(source, JSON.stringify(sorts))
}

out('\n== 离线：参数/错误路径 ==')
out('searchMusic 空关键词 =', JSON.stringify(await call('searchMusic', { keyword: '', source: 'all' })))
out('leaderboardMusics 非法 id =', JSON.stringify(await call('leaderboardMusics', { boardId: 'bad' })))
out('comments 方法存在 =', typeof metadata.comments, '/ hotComments =', typeof metadata.hotComments)
out('comments 未知音源错误 =', JSON.stringify(await call('comments', { source: 'not-a-source' })))

if (online) {
  out('\n== 在线：kw 热搜 ==')
  const hot = await call('hotSearch', 'kw')
  out(JSON.stringify(Array.isArray(hot) ? hot.slice(0, 10) : hot, null, 2))

  out('\n== 在线：kw 搜索「周杰伦」==')
  const result = await call('searchMusic', { keyword: '周杰伦', source: 'kw', page: 1, limit: 10 })
  if (result && result.__error) {
    out('FAILED:', result.__error)
  } else {
    out('total =', result.total, 'allPage =', result.allPage, 'source =', result.source)
    for (const item of (result.list || []).slice(0, 3)) {
      out(JSON.stringify({
        id: item.id, name: item.name, singer: item.singer, source: item.source,
        interval: item.interval, songId: item.meta && item.meta.songId,
        albumName: item.meta && item.meta.albumName,
        qualitys: item.meta && item.meta.qualitys,
      }, null, 2))
    }
  }

  out('\n== 在线：tx 搜索「周杰伦」==')
  const txResult = await call('searchMusic', { keyword: '周杰伦', source: 'tx', page: 1, limit: 5 })
  out(txResult && txResult.__error ? `FAILED: ${txResult.__error}` : `total=${txResult.total} first=${txResult.list?.[0]?.name} / ${txResult.list?.[0]?.singer}`)

  out('\n== 在线：wy 搜索「周杰伦」==')
  const wyResult = await call('searchMusic', { keyword: '周杰伦', source: 'wy', page: 1, limit: 5 })
  out(wyResult && wyResult.__error ? `FAILED: ${wyResult.__error}` : `total=${wyResult.total} first=${wyResult.list?.[0]?.name} / ${wyResult.list?.[0]?.singer}`)

  out('\n== 在线：kg 搜索「周杰伦」==')
  const kgResult = await call('searchMusic', { keyword: '周杰伦', source: 'kg', page: 1, limit: 5 })
  out(kgResult && kgResult.__error ? `FAILED: ${kgResult.__error}` : `total=${kgResult.total} first=${kgResult.list?.[0]?.name} / ${kgResult.list?.[0]?.singer}`)

  out('\n== 在线：mg 搜索「周杰伦」==')
  const mgResult = await call('searchMusic', { keyword: '周杰伦', source: 'mg', page: 1, limit: 5 })
  out(mgResult && mgResult.__error ? `FAILED: ${mgResult.__error}` : `total=${mgResult.total} first=${mgResult.list?.[0]?.name} / ${mgResult.list?.[0]?.singer}`)

  out('\n== 在线：kw 排行榜歌曲（kw__16，page 1 limit 10）==')
  const boardMusics = await call('leaderboardMusics', { boardId: 'kw__16', page: 1, limit: 10 })
  out(boardMusics && boardMusics.__error
    ? `FAILED: ${boardMusics.__error}`
    : `total=${boardMusics.total} page=${boardMusics.page} allPage=${boardMusics.allPage} list=${(boardMusics.list || []).slice(0, 3).map(item => `${item.name}/${item.singer}`).join(' | ')}`)

  out('\n== 在线：kw 歌单标签/列表/详情 ==')
  const kwTags = await call('songListTags', 'kw')
  out(kwTags && kwTags.__error ? `tags FAILED: ${kwTags.__error}` : `tags groups=${kwTags.groups.length}, hot=${kwTags.hot.length}`)
  const kwLists = await call('songLists', { source: 'kw', tagId: '', sortId: 'new', page: 1, limit: 5 })
  if (kwLists && kwLists.__error) {
    out('songLists FAILED:', kwLists.__error)
  } else {
    out('songLists total =', kwLists.total, 'sample =', (kwLists.list || []).slice(0, 3).map(item => `${item.name}(${item.playCount || '-'})`).join(' | '))
    const firstId = kwLists.list?.[0]?.id
    if (firstId) {
      const detail = await call('songListDetail', { id: firstId, source: 'kw', page: 1, limit: 10 })
      out('songListDetail =', detail && detail.__error ? detail.__error : `info=${detail.info.name}, listLen=${detail.page.list.length}, total=${detail.page.total}`)
    }
  }

  out('\n== 在线：歌词（晴天/周杰伦，5 源）==')
  for (const source of ['kw', 'tx', 'wy', 'kg', 'mg']) {
    const page = await call('searchMusic', { keyword: '晴天 周杰伦', source, page: 1, limit: 3 })
    const first = page && page.list?.[0]
    if (!first) { out(`${source} lyric: 无搜索结果`); continue }
    const info = await call('lyric', { source, musicInfo: first })
    out(`${source} lyric:`, info && info.__error ? `FAILED: ${info.__error}` : `len=${(info && info.lyric || '').length}, lxlyric=${(info && info.lxlyric || '').length}`)
  }

  out('\n== 在线：5 源歌曲评论（晴天 周杰伦）==')
  for (const source of ['kw', 'kg', 'tx', 'wy', 'mg']) {
    const search = await call('searchMusic', { keyword: '晴天 周杰伦', source, page: 1, limit: 5 })
    if (search && search.__error) {
      out(`${source} comments: 搜索失败 ${search.__error}`)
      continue
    }
    const exact = (search.list || []).find(item => (item.name || '').includes('晴天') && (item.singer || '').includes('周杰伦'))
    const hit = exact || (search.list || []).find(item => item.meta && item.meta.songId) || (search.list || [])[0]
    if (!hit) {
      out(`${source} comments: 无搜索结果`)
      continue
    }
    out(`${source} comment song = ${hit.name} / ${hit.singer} (songId=${hit.meta && hit.meta.songId})`)
    const page = await call('comments', { source, musicInfo: hit, page: 1, limit: 3 })
    if (page && page.__error) out(`${source} comments FAILED: ${page.__error}`)
    else out(`${source} comments: total=${page.total} page=${page.page} limit=${page.limit} maxPage=${page.maxPage} returned=${page.comments.length} first=${page.comments[0] ? page.comments[0].userName + ': ' + String(page.comments[0].text).slice(0, 24) : '-'}`)
    const hot = await call('hotComments', { source, musicInfo: hit, limit: 3 })
    if (hot && hot.__error) out(`${source} hotComments FAILED: ${hot.__error}`)
    else out(`${source} hotComments: total=${hot.total} returned=${hot.comments.length} first=${hot.comments[0] ? hot.comments[0].userName + ': ' + String(hot.comments[0].text).slice(0, 24) : '-'}`)
  }
}

process.exit(0)
