/**
 * @name Melo 非法协议测试源
 * @description 仅用于测试 lx.request 的 http(s) 限制，不打包进 App
 * @version 1.0.0
 */

const { EVENT_NAMES, request, on, send } = window.lx

on(EVENT_NAMES.request, ({ action }) => {
  if (action !== 'musicUrl') return Promise.reject(new Error('unsupported action'))
  return new Promise((resolve, reject) => {
    request('file:///etc/hosts', {}, (err) => {
      if (err) return reject(err)
      resolve('https://example.com/should-not-happen.mp3')
    })
  })
})

send(EVENT_NAMES.inited, {
  status: true,
  sources: {
    kw: { name: '非法协议源', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] }
  }
})
