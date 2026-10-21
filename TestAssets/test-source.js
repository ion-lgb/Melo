/**
 * @name MeloJSTests 测试源
 * @description 仅用于 MeloJSTests 的本地测试源，不打包进 App
 * @version 1.2.3
 * @author Melo Tests
 * @homepage http://127.0.0.1
 */

// __MELO_TEST_PORT__ 会被测试替换为本地 NWListener 的随机端口
const { EVENT_NAMES, request, on, send, utils } = window.lx

const HOST = 'http://127.0.0.1:__MELO_TEST_PORT__'
const SALT = ':melo-test'
const md5 = utils.crypto.md5

console.log('[test-source] loaded, host=' + HOST)

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

const rawRequest = (url, options = {}) => new Promise((resolve, reject) => {
  request(url, options, (err, resp) => {
    if (err) return reject(err)
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      return reject(new Error(`HTTP ${resp.statusCode}: ${resp.raw.toString('utf8')}`))
    }
    resolve(resp)
  })
})

const apis = {
  kw: {
    async musicUrl (musicInfo, quality) {
      await sleep(5)
      const meta = musicInfo.meta || {}
      const mid = String(musicInfo.songmid || meta.songId || musicInfo.id)
      const sign = md5(mid + SALT)
      const first = await rawRequest(`${HOST}/api/song?mid=${encodeURIComponent(mid)}&sign=${sign}`, {
        method: 'get',
        headers: { 'X-Melo-Test': '1', 'X-Quality': quality },
        timeout: 5000
      })
      const firstBody = JSON.parse(first.raw.toString('utf8'))
      await sleep(2)
      const second = await rawRequest(`${HOST}${firstBody.path}?token=${firstBody.token}`, { timeout: 5000 })
      const secondBody = JSON.parse(second.raw.toString('utf8'))
      const url = secondBody.url
      if (!url || !/^https?:/.test(url)) throw new Error('invalid music url')
      return url
    }
  }
}

on(EVENT_NAMES.request, ({ source, action, info }) => {
  if (action === 'musicUrl') return apis[source].musicUrl(info.musicInfo, info.type)
  return Promise.reject(new Error('unsupported action: ' + action))
})

send(EVENT_NAMES.updateAlert, { log: 'Melo 测试源更新日志', updateUrl: 'https://example.com/melo-update' })

send(EVENT_NAMES.inited, {
  status: true,
  openDevTools: false,
  sources: {
    kw: { name: 'Melo 测试源', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] },
    kg: { name: 'Melo 测试源 2', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] }
  }
})
