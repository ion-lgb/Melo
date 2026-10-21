// 用真实网络验证 musicSdk JSC bundle（Node 侧模拟 __meloNative 桥）。
// 用法: node Scripts/verify-musicsdk-bundle.mjs [关键词]
// 注意：会向音乐平台发少量真实请求，仅用于开发验证。

// 真实网络验证：内置 5 源搜索/榜单/歌单/歌词（少量请求）
const nodeProcess = process
const fs = require('fs')
const https = require('https'), http = require('http'), crypto = require('crypto')
const { URL } = require('url')
const log = (...a) => fs.appendFileSync('/tmp/melo-meta-net3.log', a.join(' ') + '\n')
fs.writeFileSync('/tmp/melo-meta-net3.log', 'start\n')
const timers = new Map()
function request(id, urlStr, optsJson) {
  let url
  try { url = new URL(urlStr) } catch (e) { respond(id, 'bad url'); return }
  const opts = JSON.parse(optsJson || '{}')
  const headers = Object.assign({}, opts.headers || {})
  let body = null
  if (opts.body != null) { body = typeof opts.body === 'string' ? opts.body : JSON.stringify(opts.body); headers['content-type'] = headers['content-type'] || 'application/json' }
  else if (opts.form) { body = new URLSearchParams(opts.form).toString(); headers['content-type'] = headers['content-type'] || 'application/x-www-form-urlencoded' }
  const client = url.protocol === 'https:' ? https : http
  const req = client.request(url, { method: (opts.method || 'get').toUpperCase(), headers }, (res) => {
    const chunks = []
    res.on('data', c => chunks.push(c))
    res.on('end', () => {
      const buf = Buffer.concat(chunks)
      const h = {}
      for (const [k, v] of Object.entries(res.headers)) h[k] = Array.isArray(v) ? v.join(', ') : String(v ?? '')
      globalThis.__meloNativeHttpResponse(id, null, JSON.stringify({ statusCode: res.statusCode || 0, statusMessage: res.statusMessage || '', headers: h, bodyBase64: buf.toString('base64'), bytes: buf.length }))
    })
  })
  req.on('error', (err) => respond(id, err.code || err.message))
  if (body) req.write(body)
  req.end()
}
function respond(id, msg) { globalThis.__meloNativeHttpResponse(id, String(msg), null) }
globalThis.navigator = { userAgent: 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36' }
globalThis.__meloNative = {
  log: (...a) => log('JSLOG', a.join(' ').slice(0, 200)),
  timerStart: (id, cb, ms, repeat) => { timers.set(id, (repeat ? setInterval : setTimeout)(cb, ms)); return id },
  timerCancel: (id) => { const t = timers.get(id); if (t) { clearTimeout(t); clearInterval(t); timers.delete(id) } },
  http: request, httpCancel: (id) => respond(id, 'aborted'),
  hash: (algo, bytes) => crypto.createHash(algo).update(Buffer.from(bytes)).digest('hex'),
  aesEncrypt: (bytes, mode, key, iv) => { const m = /^aes-(128|192|256)-(cbc|ecb)$/.exec(String(mode).toLowerCase()); const c = crypto.createCipheriv(`aes-${m[1]}-${m[2]}`, Buffer.from(key), iv && iv.length ? Buffer.from(iv) : null); return [...Buffer.concat([c.update(Buffer.from(bytes)), c.final()])] },
  aesDecrypt: (bytes, mode, key, iv) => { const m = /^aes-(128|192|256)-(cbc|ecb)$/.exec(String(mode).toLowerCase()); const d = crypto.createDecipheriv(`aes-${m[1]}-${m[2]}`, Buffer.from(key), iv && iv.length ? Buffer.from(iv) : null); return [...Buffer.concat([d.update(Buffer.from(bytes)), d.final()])] },
  randomBytes: (n) => [...crypto.randomBytes(n)],
  rsaEncrypt: (bytes, pem) => { const pub = crypto.createPublicKey(pem); const padded = Buffer.alloc(128); Buffer.from(bytes).copy(padded, 128 - bytes.length); return [...crypto.publicEncrypt({ key: pub, padding: crypto.constants.RSA_NO_PADDING }, padded)] },
}
try {
  const vm = require('vm')
  vm.runInThisContext(fs.readFileSync(require('path').join(__dirname, '../Resources/js/musicSdk.bundle.js'), 'utf8'), { filename: 'musicSdk.bundle.js' })
  const mm = globalThis.MeloMetadata
  const report = { ok: true, sources: {}, leaderboards: {}, songlist: {}, lyric: {} }
  ;(async () => {
    // 1) 五源搜索
    for (const source of ['kw', 'kg', 'tx', 'wy', 'mg']) {
      try {
        const t0 = Date.now()
        const r = await mm.searchMusic({ keyword: '周杰伦', source, page: 1, limit: 3 })
        report.sources[source] = { ok: true, ms: Date.now() - t0, total: r.total, count: r.list.length, sample: r.list.slice(0, 2).map(m => `${m.name}-${m.singer}`) }
      } catch (e) { report.sources[source] = { ok: false, error: e.message } }
      log('search', source, JSON.stringify(report.sources[source]).slice(0, 300))
    }
    // 2) 榜单
    for (const source of ['kw', 'kg', 'tx', 'wy', 'mg']) {
      try {
        const boards = await mm.leaderboards(source)
        let sample = null
        if (boards.length) {
          const page = await mm.leaderboardMusics({ boardId: boards[0].id, page: 1, limit: 3 })
          sample = { board: boards[0].name, count: page.list.length, first: page.list[0] ? `${page.list[0].name}-${page.list[0].singer}` : null }
        }
        report.leaderboards[source] = { ok: true, boards: boards.length, sample }
      } catch (e) { report.leaderboards[source] = { ok: false, error: e.message } }
      log('board', source, JSON.stringify(report.leaderboards[source]).slice(0, 300))
    }
    // 3) 歌单（kw）
    try {
      const sorts = await mm.songListSorts('kw')
      const tags = await mm.songListTags('kw')
      const page = await mm.songLists({ source: 'kw', tagId: '', sortId: sorts[0]?.id || 'new', page: 1, limit: 3 })
      let detail = null
      if (page.list.length) {
        const d = await mm.songListDetail({ id: page.list[0].id, source: 'kw', page: 1, limit: 3 })
        detail = { info: d.info.name, count: d.page.list.length, first: d.page.list[0] ? `${d.page.list[0].name}-${d.page.list[0].singer}` : null }
      }
      report.songlist.kw = { ok: true, sorts: sorts.length, tagGroups: tags.groups.length, hot: tags.hot.length, listCount: page.list.length, detail }
    } catch (e) { report.songlist.kw = { ok: false, error: e.message } }
    log('songlist', JSON.stringify(report.songlist.kw).slice(0, 400))
    // 4) 歌词（用 kw 搜索第一首的 MusicInfo）
    try {
      const r = await mm.searchMusic({ keyword: '晴天 周杰伦', source: 'kw', page: 1, limit: 1 })
      const music = r.list[0]
      const lyric = await mm.lyric({ source: 'kw', musicInfo: music })
      report.lyric.kw = { ok: true, name: music.name, hasLyric: !!(lyric && lyric.lyric), len: lyric && lyric.lyric ? lyric.lyric.length : 0, hasWord: !!(lyric && lyric.lxlyric) }
    } catch (e) { report.lyric.kw = { ok: false, error: e.message } }
    log('lyric', JSON.stringify(report.lyric.kw).slice(0, 300))
    fs.writeFileSync('/tmp/melo-meta-net-report3.json', JSON.stringify(report, null, 2))
    nodeProcess.exit(0)
  })()
} catch (e) {
  fs.writeFileSync('/tmp/melo-meta-net-report3.json', JSON.stringify({ ok: false, error: e.message, stack: (e.stack || '').split('\n').slice(0, 4) }))
  nodeProcess.exit(1)
}
