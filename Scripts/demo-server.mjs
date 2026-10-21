// Melo 本地联调测试服务（仅开发/测试用，零依赖）
// 用途：
//  1) 给 TestAssets/demo-source.js 提供两段式音乐 URL 接口（含 md5 签名校验）
//  2) 提供歌词接口
//  3) 动态生成一段 20 秒 WAV 并提供 Range 流式播放
//
// 启动: node Scripts/demo-server.mjs [--port 27331]
// 输出一行 "READY <port>" 便于脚本解析。
import http from 'node:http'
import { createHash } from 'node:crypto'

const args = process.argv.slice(2)
let port = 27331
const portIndex = args.indexOf('--port')
if (portIndex >= 0 && args[portIndex + 1]) port = Number(args[portIndex + 1])

const md5 = s => createHash('md5').update(String(s)).digest('hex')

function makeWav(duration = 20, sampleRate = 44100) {
  const channels = 2
  const bps = 2
  const frames = duration * sampleRate
  const dataSize = frames * channels * bps
  const buf = Buffer.alloc(44 + dataSize)
  buf.write('RIFF', 0)
  buf.writeUInt32LE(36 + dataSize, 4)
  buf.write('WAVE', 8)
  buf.write('fmt ', 12)
  buf.writeUInt32LE(16, 16)
  buf.writeUInt16LE(1, 20)
  buf.writeUInt16LE(channels, 22)
  buf.writeUInt32LE(sampleRate, 24)
  buf.writeUInt32LE(sampleRate * channels * bps, 28)
  buf.writeUInt16LE(channels * bps, 32)
  buf.writeUInt16LE(16, 34)
  buf.write('data', 36)
  buf.writeUInt32LE(dataSize, 40)
  const chords = [261.63, 220.0, 174.61, 196.0]
  for (let i = 0; i < frames; i++) {
    const t = i / sampleRate
    const base = chords[Math.floor(t / 2) % chords.length]
    let v = Math.sin(2 * Math.PI * base * t) * 0.36
    v += Math.sin(2 * Math.PI * base * 1.25 * t) * 0.18
    v += Math.sin(2 * Math.PI * base * 1.5 * t) * 0.12
    v += Math.sin(2 * Math.PI * base * 2 * t) * 0.06
    const env = Math.min(1, t / 1.2, (duration - t) / 1.2)
    const left = v * env * 0.5
    const right = v * env * 0.45 + Math.sin(2 * Math.PI * base * 1.5 * t) * 0.04 * env
    buf.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(left * 32767))), 44 + i * 4)
    buf.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(right * 32767))), 44 + i * 4 + 2)
  }
  return buf
}

function mmss(sec) {
  const m = Math.floor(sec / 60)
  const s = sec % 60
  return `${String(m).padStart(2, '0')}:${s.toFixed(2).padStart(5, '0')}`
}

function makeLyric() {
  const lines = [
    'Melo 测试音频 · 第一行',
    '这是自定义源返回的歌词',
    '验证 Swift 与 JavaScriptCore 桥接',
    '播放地址来自本地测试服务',
    '歌词逐行高亮应正常工作',
    '桌面歌词窗口也应显示这一行',
    '你正在测试 Melo for macOS',
    '如果听到音乐说明链路已打通',
    '欢迎使用落雪自定义源',
    'Melo · Native SwiftUI',
  ]
  const lyric = []
  const tlyric = []
  const lxlyric = []
  for (let i = 0; i < lines.length; i++) {
    const t = i * 2
    lyric.push(`[${mmss(t)}]${lines[i]}`)
    tlyric.push(`[${mmss(t)}]Melo test lyric line ${i + 1}`)
    let words = ''
    let start = 0
    for (const ch of lines[i]) {
      words += `<${start},180>${ch}`
      start += 180
    }
    lxlyric.push(`[${mmss(t)}]${words}`)
  }
  return {
    lyric: lyric.join('\n'),
    tlyric: tlyric.join('\n'),
    lxlyric: lxlyric.join('\n'),
  }
}

const wav = makeWav()
const lyric = makeLyric()
const tickets = new Map()

function json(res, code, body) {
  const data = Buffer.from(JSON.stringify(body))
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': data.length,
    'Access-Control-Allow-Origin': '*',
  })
  res.end(data)
}

function serveWav(req, res) {
  const total = wav.length
  const range = req.headers.range
  const headers = {
    'Content-Type': 'audio/wav',
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'no-store',
  }
  if (req.method === 'HEAD') {
    res.writeHead(200, { ...headers, 'Content-Length': total })
    res.end()
    return
  }
  if (!range) {
    res.writeHead(200, { ...headers, 'Content-Length': total })
    res.end(wav)
    return
  }
  const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim())
  if (!match) {
    res.writeHead(416, { ...headers, 'Content-Range': `bytes */${total}` })
    res.end()
    return
  }
  const start = match[1] === '' ? total - Number(match[2] || 0) : Number(match[1])
  const end = match[1] !== '' && match[2] !== '' ? Math.min(Number(match[2]), total - 1) : total - 1
  if (start < 0 || start >= total || end < start) {
    res.writeHead(416, { ...headers, 'Content-Range': `bytes */${total}` })
    res.end()
    return
  }
  res.writeHead(206, {
    ...headers,
    'Content-Range': `bytes ${start}-${end}/${total}`,
    'Content-Length': end - start + 1,
  })
  res.end(wav.subarray(start, end + 1))
}

const server = http.createServer((req, res) => {
  const started = Date.now()
  const url = new URL(req.url || '/', `http://127.0.0.1:${port}`)
  const path = url.pathname
  let status = 200
  const done = () => console.log(`${req.method} ${path}${url.search} -> ${status} (${Date.now() - started}ms)`)
  res.on('finish', done)

  try {
    if (path === '/health') {
      return json(res, 200, { ok: true, name: 'melo-demo-server', port })
    }
    if (path === '/api/song') {
      const source = url.searchParams.get('source') || ''
      const mid = url.searchParams.get('mid') || ''
      const ts = url.searchParams.get('ts') || ''
      const sign = url.searchParams.get('sign') || ''
      const expected = md5(`${source}|${mid}|${url.searchParams.get('quality') || ''}|${ts}`)
      // demo-source.js 的 /api/song 不传 quality（两段式），因此单独校验
      const expectedNoQuality = md5(`${source}|${mid}|${ts}`)
      if (!sign || (sign !== expected && sign !== expectedNoQuality)) {
        status = 403
        return json(res, 403, { error: 'bad sign' })
      }
      if (urgentBad(mid)) {
        status = 400
        return json(res, 400, { error: 'bad music id' })
      }
      const ticket = Buffer.from(JSON.stringify({ source, mid, ts })).toString('base64url')
      tickets.set(ticket, { source, mid, ts, createdAt: Date.now() })
      return json(res, 200, { ticket })
    }
    if (path === '/api/play') {
      const ticket = url.searchParams.get('ticket') || ''
      const quality = url.searchParams.get('quality') || '128k'
      const info = tickets.get(ticket)
      if (!info) {
        status = 403
        return json(res, 403, { error: 'invalid ticket' })
      }
      return json(res, 200, { url: `http://127.0.0.1:${port}/media/demo.wav`, quality, source: info.source })
    }
    if (path === '/api/lyric') {
      const source = url.searchParams.get('source') || ''
      const mid = url.searchParams.get('mid') || ''
      if (urgentBad(mid)) {
        status = 400
        return json(res, 400, { error: 'bad music id' })
      }
      const result = { ...lyric, source, mid }
      return json(res, 200, result)
    }
    if (path === '/media/demo.wav') {
      return serveWav(req, res)
    }
    status = 404
    return json(res, 404, { error: 'not found' })
  } catch (err) {
    status = 500
    return json(res, 500, { error: String(err && err.message ? err.message : err) })
  }
})

function urgentBad(mid) {
  return String(mid).toLowerCase() === 'bad'
}

server.listen(port, '127.0.0.1', () => {
  console.log(`READY ${port}`)
  console.log(`demo source URL base: http://127.0.0.1:${port}`)
  console.log(`test music info (kw): {"id":"kw_demo","name":"Melo 测试音频","singer":"Melo","source":"kw","interval":"00:20","meta":{"songId":"demo","albumName":"Melo Test","qualitys":[{"type":"128k","size":null},{"type":"320k","size":null},{"type":"flac","size":null}],"_qualitys":{"128k":{"size":null},"320k":{"size":null},"flac":{"size":null}}}}`)
})

process.on('SIGINT', () => {
  server.close(() => process.exit(0))
})
process.on('SIGTERM', () => {
  server.close(() => process.exit(0))
})
