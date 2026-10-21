/**
 * @name Melo 测试源
 * @description 本地联调用的 LX 自定义源（仅测试，不内置到应用）
 * @version 1.0.0
 * @author Melo
 * @homepage http://127.0.0.1:27331
 *
 * 用法：先用 Scripts/demo-server.mjs 启动本地测试服务，然后在 Melo 设置页导入本文件。
 * 它会通过 lx.request 与 lx.utils.crypto.md5 访问本地测试服务，验证 JS 运行时与桥接层。
 */

const lx = globalThis.lx || window.lx
const { EVENT_NAMES, request, on, send, utils } = lx
const BASE = 'http://127.0.0.1:27331'
const QUALITYS = ['128k', '320k', 'flac']

const md5 = s => utils.crypto.md5(String(s))

const requestJSON = (path, options = {}) => new Promise((resolve, reject) => {
  request(BASE + path, { method: 'get', timeout: 10000, ...options }, (err, resp, body) => {
    if (err) return reject(err)
    if (!body || typeof body !== 'object') return reject(new Error('invalid response'))
    if (body.error) return reject(new Error(body.error))
    resolve(body)
  })
})

const musicUrl = async ({ source, musicInfo, quality }) => {
  const mid = String(musicInfo.meta && musicInfo.meta.songId != null ? musicInfo.meta.songId : musicInfo.id)
  if (mid === 'bad') throw new Error('测试源：故意失败的歌曲')
  const ts = Date.now()
  // 两段请求 + md5 签名：验证 lx.request 多次调用、header/query、crypto 桥
  const sign = md5(`${source}|${mid}|${ts}`)
  const ticket = await requestJSON(`/api/song?source=${encodeURIComponent(source)}&mid=${encodeURIComponent(mid)}&ts=${ts}&sign=${sign}`, {
    headers: { 'X-Melo-Test': '1' },
  })
  if (!ticket.ticket) throw new Error('测试源：未拿到 ticket')
  const data = await requestJSON(`/api/play?ticket=${encodeURIComponent(ticket.ticket)}&quality=${encodeURIComponent(quality)}`)
  return data.url
}

const sources = {}
for (const key of ['kw', 'kg', 'tx', 'wy', 'mg']) {
  sources[key] = {
    name: `测试源-${key}`,
    type: 'music',
    actions: ['musicUrl'],
    qualitys: QUALITYS,
  }
}

on(EVENT_NAMES.request, ({ source, action, info }) => {
  switch (action) {
    case 'musicUrl':
      return musicUrl({ source, musicInfo: info.musicInfo, quality: info.type })
    default:
      return Promise.reject(new Error(`测试源不支持 action: ${action}`))
  }
})

send(EVENT_NAMES.inited, {
  status: true,
  openDevTools: false,
  sources,
})
