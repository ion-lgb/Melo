/**
 * @name Melo 失败测试源
 * @description 仅用于测试 Promise reject 路径，不打包进 App
 * @version 1.0.0
 */

const { EVENT_NAMES, on, send } = window.lx

on(EVENT_NAMES.request, () => Promise.reject(new Error('boom-melo')))

send(EVENT_NAMES.inited, {
  status: true,
  sources: {
    kw: { name: '失败源', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] }
  }
})
