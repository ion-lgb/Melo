/**
 * @name Melo 非法 URL 结果测试源
 * @description 仅用于测试结果校验，不打包进 App
 * @version 1.0.0
 */

const { EVENT_NAMES, on, send } = window.lx

on(EVENT_NAMES.request, ({ action }) => {
  // 'http://' 能通过 preload 的 /^https?:/ 前缀校验，但不是合法 URL，用来触发 MeloJS 的结果校验
  if (action === 'musicUrl') return Promise.resolve('http://')
  return Promise.reject(new Error('unsupported action'))
})

send(EVENT_NAMES.inited, {
  status: true,
  sources: {
    kw: { name: '非法 URL 源', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] }
  }
})
